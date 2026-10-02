#!/usr/bin/env node

import { createHash, randomUUID, X509Certificate } from "node:crypto";
import { execFile, execFileSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { createServer as createSecureServer } from "node:https";
import { closeSync, constants, existsSync, openSync } from "node:fs";
import { access, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST = "CobbleChromiumSDK.json";
const DEFAULT_TIMEOUT_MS = 30_000;
const LOCAL_FILE_CHECKS = [
  "localFileExactHTMLLoaded", "localFileChildrenWorkersAndDownloadsDenied",
  "genericSiblingFileNavigationDenied", "localFileExactTextLoaded",
  "localFileAdjacentHistoryUnavailable", "localFileNativeReloadRefused",
  "localFileSecureReopenReplacesCurrentEntry", "localFileUsesHeldAuthorizedInode",
  "localFileSymlinkLeafRejected", "localFileSymlinkParentRejected", "localFileFIFORejected",
  "localFileDeviceRejected", "localFileDirectoryRejected", "localFilePDFExtensionRejected",
  "localFilePDFMagicRejected", "httpRedirectStillAllowed", "httpRedirectToFileDenied",
  "localFileProvisionalCancellationPreservesDocument", "localFileCommittedErrorRevokesAuthorization",
  "localFileCanBeReauthorizedAfterCommittedError", "committedHTTPRevokesLocalFileHistory",
  "localFileSupersedeCompletesOnceWithFailure", "localFileCloseCompletesOnceAndReleasesPage",
];
const REPOST_CHECKS = [
  "postRepostMetadata", "postRepostSDKCancelExactlyOnce",
  "postRepostSDKCancelRetainsDocument", "postRepostSDKAcceptPreservesRequest",
  "postRepostOriginAcceptPreservesRequest", "rendererPostRepostAccepted",
  "rendererPostRepostPreservesRequest", "unhandledPostRepostDenied",
  "stalePostRepostCancelledOnce", "beforeUnloadCancelPreventsRepost",
  "beforeUnloadPrecedesRepost", "closedPostRepostCancelledOnce",
];
let interruptedSignal;
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => { interruptedSignal = signal; });
}

function fail(message) {
  throw new Error(message);
}

class FatalSmokeError extends Error {}

function failFatal(message) {
  throw new FatalSmokeError(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function isHash(value, length) {
  return typeof value === "string" && new RegExp(`^[0-9a-f]{${length}}$`).test(value);
}

function plistValue(path, key) {
  return execFileSync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", path], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

async function validateHarness(appPath) {
  assert(appPath.endsWith(".app"), "Harness path must be an app bundle");
  const contents = join(appPath, "Contents");
  const infoPath = join(contents, "Info.plist");
  const manifestPath = join(contents, "Resources", MANIFEST);
  const binaryPath = join(contents, "MacOS", "Chromium");
  await access(binaryPath, constants.X_OK);
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath], {
    stdio: ["ignore", "ignore", "pipe"],
  });

  const [embedded, expectedLock] = await Promise.all([
    readFile(manifestPath, "utf8").then(JSON.parse),
    readFile(join(ROOT, "chromium.lock.json"), "utf8").then(JSON.parse),
  ]);
  assert(embedded.schema === 1, "Unsupported SDK manifest schema");
  assert(embedded.variant === "sdk", "Harness does not contain the embedding SDK variant");
  assert(embedded.release_ready === false, "Harness SDK manifest must remain explicitly non-release-ready");
  assert(stableJSON(embedded.lock) === stableJSON(expectedLock),
    "Harness Chromium lock differs from this SDK checkout");
  assert(isHash(embedded.sdk_revision, 40), "Harness SDK revision is invalid");

  const payload = embedded.native_payload;
  assert(payload && typeof payload === "object", "Harness native payload is missing");
  for (const name of ["overlay", "patches"]) {
    assert(payload[name] && typeof payload[name] === "object" &&
      !Array.isArray(payload[name]) && Object.keys(payload[name]).length > 0,
    `Harness native ${name} manifest is invalid`);
    assert(Object.values(payload[name]).every((value) => isHash(value, 64)),
      `Harness native ${name} hashes are invalid`);
  }
  const payloadHash = createHash("sha256").update(stableJSON({
    overlay: payload.overlay,
    patches: payload.patches,
  })).digest("hex");
  assert(payload.sha256 === payloadHash, "Harness native payload fingerprint is invalid");
  const currentPayload = JSON.parse(execFileSync("python3", ["-c",
    "import json; from build import native_payload; print(json.dumps(native_payload()))"], {
    cwd: join(ROOT, "scripts"), encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
  }));
  assert(stableJSON(payload) === stableJSON(currentPayload),
    "Harness native payload differs from this SDK checkout");

  const version = plistValue(infoPath, "CFBundleShortVersionString");
  const bundleID = plistValue(infoPath, "CFBundleIdentifier");
  const productDirectory = plistValue(infoPath, "CrProductDirName");
  assert(version === embedded.lock.version, "Harness app version differs from its Chromium lock");
  assert(bundleID === "com.ignacio.cobble.chromium-harness", "Input is not an isolated Cobble harness app");
  assert(/^Cobble Chromium Harness\/[0-9a-f-]{36}$/i.test(productDirectory),
    "Harness does not have an isolated product data directory");
  return { binaryPath, bundleID, productDirectory, version, manifest: embedded };
}

function escapeHTML(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

export async function startFixture(token, downloadDirectory) {
  const requests = [];
  const networkDownloadName = `network-${token}.txt`;
  const blobDownloadName = `blob-${token}.txt`;
  const cancelledDownloadName = `cancel-${token}.txt`;
  const pausedDownloadName = `pause-resume-${token}.txt`;
  const pausedCancelledDownloadName = `pause-cancel-${token}.txt`;
  const unknownTotalDownloadName = `unknown-total-${token}.txt`;
  const existingDestinationDownloadName = `existing-destination-${token}.txt`;
  const danglingDestinationDownloadName = `dangling-destination-${token}.txt`;
  const interruptedDownloadName = `interrupt-resume-${token}.bin`;
  const interruptedCancelDownloadName = `interrupt-cancel-${token}.bin`;
  const interruptedReleaseDownloadName = `interrupt-release-${token}.bin`;
  const interruptedPOSTDownloadName = `interrupt-post-${token}.bin`;
  const networkDownload = Buffer.from(`Cobble Chromium network download ${token}\n`.repeat(16_384));
  const blobDownload = `Cobble Chromium blob download ${token}\n`;
  const pausedDownload = Buffer.from(`Cobble Chromium paused download ${token}\n`.repeat(32_768));
  const unknownTotalDownload = Buffer.from(`Cobble Chromium unknown total ${token}\n`.repeat(2_048));
  const interruptedDownload = Buffer.from(`Cobble Chromium interrupted ${token}\n`.repeat(48_000));
  const prefix = `/fixture/${token}`;
  const mainClientCertificateNames = [
    "select", "document", "cancel", "unhandled", "stale", "close", "reentrant",
  ];
  const emptyClientCertificateNames = ["missing", "relative", "directory"];
  const clientCertificateNames = [...mainClientCertificateNames, ...emptyClientCertificateNames];
  const clientCertificateStats = Object.fromEntries(clientCertificateNames.map((name) =>
    [name, { connections: 0, tlsErrors: 0, secureConnections: 0, requests: 0, peerSerials: [] }]));
  let getReloads = 0;
  let postReloads = 0;
  const reposts = new Map();
  const websiteDataCacheHits = new Map();
  let origin;
  let mixedOrigin;
  const handler = (request, response) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    requests.push({ method: request.method, path: `${url.pathname}${url.search}`,
      userAgent: request.headers["user-agent"] ?? "", range: request.headers.range ?? "" });
    const headers = {
      "Cache-Control": "private, max-age=60",
      "Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; form-action 'self'",
      "Content-Type": "text/html; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    };
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204, { "Cache-Control": "no-store" });
      response.end();
    } else if (url.pathname === `${prefix}/page-a`) {
      response.writeHead(200, headers);
      response.end(`<!doctype html><html data-run="${token}"><head><title>Cobble Smoke A</title>
        <link rel="icon" href="${prefix}/favicon.png">
        <style>body{font:18px system-ui;margin:32px}main{max-width:720px}</style></head><body>
        <main><h1 id="heading">Native Chromium fixture</h1>
        <a id="hover-target" href="${prefix}/hover-target">Hover fixture</a>
        <form id="fixture-form" action="${prefix}/result" method="get">
        <label>State <input id="query" name="q"></label>
        <button id="submit" type="submit">Render result</button></form></main></body></html>`);
    } else if (url.pathname === `${prefix}/client-certificate-document`) {
      response.writeHead(200, { ...headers,
        "Content-Security-Policy": `default-src 'self'; script-src 'unsafe-inline'; connect-src ${clientCertificateURLs.document}`,
      });
      response.end(`<!doctype html><title>Cobble Client Certificate document pending ${token}</title>` +
        `<main id="result">PENDING-${token}</main><script>` +
        `fetch(${JSON.stringify(clientCertificateURLs.document)}, {credentials:'include'})` +
        `.then(r=>r.text()).then(value=>{document.title='Cobble Client Certificate document ${token}';` +
        `document.documentElement.dataset.clientCertificate='document';` +
        `document.querySelector('#result').textContent=value})` +
        `.catch(()=>{document.title='Cobble Client Certificate document denied ${token}'})</script>`);
    } else if (url.pathname === `${prefix}/extension-target`) {
      response.writeHead(200, headers);
      response.end(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble Extension Baseline ${token}</title></head><body><p>Cobble cobble COBBLE</p></body></html>`);
    } else if ([`${prefix}/secure`, `${prefix}/secure-after-mixed`,
      `${prefix}/secure-recovery`, `${prefix}/mixed`]
      .includes(url.pathname)) {
      const isMixed = url.pathname === `${prefix}/mixed`;
      response.writeHead(200, isMixed ? {
        ...headers,
        "Content-Security-Policy": "default-src 'self'; img-src http://cobble-mixed.test:*; script-src http://cobble-mixed.test:*",
      } : headers);
      response.end(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble TLS ${isMixed ? "Mixed" : "Secure"} ${token}</title>
        </head><body>${isMixed
          ? `<img src="${mixedOrigin}${prefix}/mixed-pixel.png" alt="mixed fixture">
             <script src="${mixedOrigin}${prefix}/mixed.js"></script>` : "secure fixture"}</body></html>`);
    } else if (url.pathname === `${prefix}/mixed-pixel.png`) {
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "image/png" });
      response.end(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xx8WAAAAAElFTkSuQmCC", "base64"));
    } else if (url.pathname === `${prefix}/mixed.js`) {
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "text/javascript" });
      response.end("document.documentElement.dataset.mixedScript = 'loaded';");
    } else if (url.pathname === `${prefix}/media`) {
      response.writeHead(200, {
        ...headers,
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'",
      });
      response.end(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble Media Pending ${token}</title></head><body><script>
        navigator.mediaDevices.getUserMedia({audio: true, video: true}).then(stream => {
          window.cobbleMediaStream = stream;
          document.title = ${JSON.stringify(`Cobble Media Granted ${token}`)};
        }, () => { document.title = ${JSON.stringify(`Cobble Media Denied ${token}`)}; });
        </script></body></html>`);
    } else if (url.pathname === `${prefix}/blocking`) {
      response.writeHead(200, {
        ...headers,
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'",
      });
      response.end(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble Blocking Pending ${token}</title>
        <script src="${prefix}/blocked.js"></script></head><body>
        <img id="blocked-image" src="${prefix}/blocked.png"><script>
        addEventListener("load", () => { document.title = window.cobbleBlockedScriptLoaded &&
          document.querySelector("#blocked-image").naturalWidth > 0
          ? ${JSON.stringify(`Cobble Blocking Allowed ${token}`)}
          : ${JSON.stringify(`Cobble Blocking Blocked ${token}`)}; });
        </script></body></html>`);
    } else if (url.pathname === `${prefix}/blocked.js`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Type": "text/javascript; charset=utf-8" });
      response.end("window.cobbleBlockedScriptLoaded = true;");
    } else if (url.pathname === `${prefix}/blocked.png`) {
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "image/png" });
      response.end(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xx8WAAAAAElFTkSuQmCC", "base64"));
    } else if (url.pathname === `${prefix}/favicon.png`) {
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "image/png" });
      response.end(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAEKADAAQAAAABAAAAEAAAAAA0VXHyAAAAFUlEQVQ4EWNgGAWjITAaAqMhAAkBAAQQAAG+Y1MiAAAAAElFTkSuQmCC", "base64"));
    } else if (url.pathname === `${prefix}/js-dialog`) {
      const mode = url.searchParams.get("mode") ?? "confirm";
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><title>Cobble JS Pending ${token}</title><script>
        setTimeout(() => {
          const value = ${JSON.stringify(mode)} === "prompt"
            ? prompt("Cobble prompt ${token}", "fixture-default")
            : confirm("Cobble confirm ${token}");
          document.title = "Cobble JS Result " + String(value) + " ${token}";
        }, 50);
      </script>`);
    } else if (url.pathname === `${prefix}/file-chooser`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><title>Cobble File Pending ${token}</title>
        <input id="file" type="file" accept=".txt,text/plain"><script>
        document.querySelector("#file").addEventListener("change", event => document.title =
          "Cobble File Selected " + (event.target.files[0]?.name || "none") + " ${token}");
        </script>`);
    } else if (url.pathname === `${prefix}/file-folder`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><title>Cobble Folder Pending ${token}</title>
        <input id="file" type="file" webkitdirectory multiple><script>
        document.querySelector("#file").addEventListener("change", event => {
          const paths = [...event.target.files].map(file => file.webkitRelativePath).sort();
          document.title = "Cobble Folder Selected " + paths.length + " " +
            paths.join(",") + " ${token}";
        });
        </script>`);
    } else if (url.pathname === `${prefix}/file-frame-parent`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><title>Cobble File Frame ${token}</title>
        <iframe id="chooser" src="${prefix}/file-frame-child"></iframe>`);
    } else if (url.pathname === `${prefix}/file-frame-child`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><input id="file" type="file">`);
    } else if (url.pathname === `${prefix}/exclusive-access`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><title>Cobble Exclusive Preparing ${token}</title>
        <button id="exclusive">Request exclusive access</button><script>
        let keySeen = false;
        addEventListener("keydown", event => { if (event.code === "KeyW") keySeen = true; });
        const settle = promise => Promise.race([
          Promise.resolve(promise).then(() => "resolved", () => "rejected"),
          new Promise(resolve => setTimeout(() => resolve("timeout"), 3000)),
        ]);
        const pipCanvas = document.createElement("canvas");
        pipCanvas.width = 64; pipCanvas.height = 64;
        const pipContext = pipCanvas.getContext("2d");
        pipContext.fillStyle = "#09f"; pipContext.fillRect(0, 0, 64, 64);
        const pipVideo = document.createElement("video");
        pipVideo.muted = true; pipVideo.playsInline = true;
        pipVideo.srcObject = pipCanvas.captureStream(5);
        document.body.append(pipVideo);
        const pipReady = settle(pipVideo.play());
        pipReady.then(outcome => {
          document.body.dataset.pipVideoReady = String(outcome === "resolved" &&
            !pipVideo.paused && pipVideo.videoWidth > 0 && pipVideo.videoHeight > 0);
          document.title = "Cobble Exclusive Ready ${token}";
        });
        window.cobbleRunExclusive = async name => {
          let outcome = "unavailable";
          if (name === "fullscreen") {
            outcome = await settle(document.documentElement.requestFullscreen());
            document.body.dataset.fullscreenDenied =
              String(outcome === "rejected" && !document.fullscreenElement);
          } else if (name === "pointer") {
            outcome = await settle(document.body.requestPointerLock());
            document.body.dataset.pointerDenied =
              String(outcome === "rejected" && !document.pointerLockElement);
          } else if (name === "keyboard" && navigator.keyboard) {
            outcome = await settle(navigator.keyboard.lock(["KeyW"]));
            document.body.dataset.keyboardDenied = String(outcome === "rejected");
          }
          document.body.dataset[name + "Outcome"] = outcome;
          return outcome;
        };
        window.cobbleExclusiveFinish = () => {
          document.body.dataset.keyDelivered = String(keySeen);
          document.body.dataset.visibility = document.visibilityState;
          document.body.dataset.focused = String(document.hasFocus());
          document.body.dataset.viewport = String(window.innerWidth > 0 && window.innerHeight > 0);
          document.body.dataset.fullscreenEnabled = String(document.fullscreenEnabled);
          document.title = "Cobble Exclusive Denied ${token}";
        };
        window.cobbleRunCapability = async name => {
          let operation;
          document.body.dataset[name + "Activation"] =
            String(navigator.userActivation.isActive);
          try {
            if (name === "bluetooth" && navigator.bluetooth)
              operation = navigator.bluetooth.requestDevice({acceptAllDevices: true});
            else if (name === "usb" && navigator.usb)
              operation = navigator.usb.requestDevice({filters: []});
            else if (name === "serial" && navigator.serial)
              operation = navigator.serial.requestPort({filters: []});
            else if (name === "hid" && navigator.hid)
              operation = navigator.hid.requestDevice({filters: []});
            else if (name === "payment" && window.PaymentRequest) {
              const request = new PaymentRequest(
                [{supportedMethods: "https://cobble-payment.invalid/pay"}],
                {total: {label: "Fixture", amount: {currency: "USD", value: "1.00"}}});
              operation = request.show();
            } else if (name === "pip" && document.pictureInPictureEnabled) {
              const playOutcome = await pipReady;
              const ready = playOutcome === "resolved" && !pipVideo.paused &&
                pipVideo.videoWidth > 0 && pipVideo.videoHeight > 0;
              document.body.dataset.pipVideoReady = String(ready);
              operation = ready ? pipVideo.requestPictureInPicture().then(value => {
                  document.exitPictureInPicture().catch(() => {});
                  return value;
                }) : Promise.reject(new Error("fixture video did not start"));
            } else if (name === "documentPip" && window.documentPictureInPicture) {
              operation = window.documentPictureInPicture.requestWindow().then(value => {
                value.close();
                return value;
              });
            } else if (name === "displayMedia" && navigator.mediaDevices?.getDisplayMedia) {
              operation = navigator.mediaDevices.getDisplayMedia({
                video: true, audio: true, systemAudio: "include",
              }).then(value => {
                value.getTracks().forEach(track => track.stop());
                return value;
              });
            }
          } catch { operation = Promise.reject(); }
          const outcome = operation ? await Promise.race([
            Promise.resolve(operation).then(value =>
              Array.isArray(value) && value.length === 0 ? "empty" : "resolved",
              () => "rejected"),
            new Promise(resolve => setTimeout(() => resolve("timeout"), 3000)),
          ]) : "unavailable";
          document.body.dataset[name] = outcome;
          return outcome;
        };
        </script>`);
    } else if (url.pathname === `${prefix}/beforeunload`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><title>Cobble BeforeUnload Ready ${token}</title>
        <button style="position:fixed;inset:0">Activate</button><script>
        addEventListener("beforeunload", event => { event.preventDefault(); event.returnValue = ""; });
        </script>`);
    } else if (url.pathname === `${prefix}/http-auth`) {
      const credentials = Buffer.from(`cobble:${token}`).toString("base64");
      const authHeaders = request.headers.origin ? {
        "Access-Control-Allow-Origin": request.headers.origin,
        "Access-Control-Allow-Credentials": "true",
      } : {};
      if (request.headers.authorization !== `Basic ${credentials}`) {
        response.writeHead(401, { "Cache-Control": "no-store",
          ...authHeaders,
          "Content-Type": "text/html; charset=utf-8",
          "WWW-Authenticate": `Basic realm="Cobble Fixture ${token}"` });
        response.end("Authentication required");
      } else {
        response.writeHead(200, { ...headers, ...authHeaders,
          "Cache-Control": "no-store" });
        response.end(`<!doctype html><title>Cobble Auth Granted ${token}</title>`);
      }
    } else if (url.pathname === `${prefix}/auth-subresource`) {
      const port = request.socket.localPort;
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; connect-src http://cobble-auth-subresource.test:*" });
      response.end(`<!doctype html><title>Cobble Auth Subresource Pending ${token}</title><script>
        setTimeout(() => fetch("http://cobble-auth-subresource.test:${port}${prefix}/http-auth?subresource=1", {credentials: "include"})
          .then(() => document.title = "Cobble Auth Subresource Granted ${token}")
          .catch(() => document.title = "Cobble Auth Subresource Failed ${token}"), 50);
      </script>`);
    } else if (url.pathname === `${prefix}/external-protocol`) {
      const testCase = url.searchParams.get("case") ?? "main";
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; frame-src 'self'" });
      if (testCase === "iframe") {
        response.end(`<!doctype html><title>Cobble External Ready iframe ${token}</title>
          <iframe id="external-frame" src="${prefix}/external-protocol-child"></iframe>`);
      } else {
        response.end(`<!doctype html><title>Cobble External Ready ${testCase} ${token}</title>
          <a id="external" href="cobble-fixture:${testCase}-${token}">Open fixture protocol</a>
          ${testCase === "automatic" ? `<script>setTimeout(() => location.href = document.querySelector("#external").href, 50)</script>` : ""}`);
      }
    } else if (url.pathname === `${prefix}/external-protocol-child`) {
      response.writeHead(200, { ...headers, "Cache-Control": "no-store" });
      response.end(`<!doctype html><a id="external" href="cobble-fixture:iframe-${token}">Frame protocol</a>`);
    } else if (url.pathname === `${prefix}/dom`) {
      response.writeHead(200, {
        ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'",
      });
      response.end(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble DOM Pending ${token}</title></head><body><main id="live">initial</main><script>
        document.querySelector("#live").textContent = ${JSON.stringify(`mutated-${token}`)};
        document.title = ${JSON.stringify(`Cobble DOM Mutated ${token}`)};
        </script></body></html>`);
    } else if (url.pathname === `${prefix}/reload-get`) {
      getReloads++;
      response.writeHead(200, { ...headers, "Cache-Control": "no-store" });
      response.end(`<!doctype html><title>Cobble Reload GET ${getReloads} ${token}</title>`);
    } else if (url.pathname === `${prefix}/reload-post-start`) {
      response.writeHead(200, {
        ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; form-action 'self'",
      });
      response.end(`<!doctype html><title>Cobble POST Start ${token}</title>
        <form id="post" method="post" action="${prefix}/reload-post"><input name="token" value="${token}"></form>
        <script>document.querySelector("#post").requestSubmit();</script>`);
    } else if (url.pathname === `${prefix}/reload-post` && request.method === "POST") {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", chunk => { body += chunk; });
      request.on("end", () => {
        postReloads++;
        response.writeHead(200, { ...headers, "Cache-Control": "no-store" });
        response.end(`<!doctype html><title>Cobble Reload POST ${postReloads} ${token}</title>
          <output>${escapeHTML(body)}</output>`);
      });
    } else if (url.pathname === `${prefix}/repost-start`) {
      const name = url.searchParams.get("case") ?? "missing";
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; form-action 'self'" });
      response.end(`<!doctype html><title>Cobble Repost Start ${escapeHTML(name)} ${token}</title>
        <form id="repost" method="post" action="${prefix}/repost?case=${encodeURIComponent(name)}">
        <input name="token" value="${token}"><input name="case" value="${escapeHTML(name)}"></form>
        <script>document.querySelector('#repost').requestSubmit()</script>`);
    } else if (url.pathname === `${prefix}/repost-stats`) {
      const name = url.searchParams.get("case") ?? "missing";
      const stats = reposts.get(name) ?? { postCount: 0, nonPostCount: 0, bodyBase64: [] };
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "application/json" });
      response.end(JSON.stringify(stats));
    } else if (url.pathname === `${prefix}/repost`) {
      const name = url.searchParams.get("case") ?? "missing";
      const stats = reposts.get(name) ?? { postCount: 0, nonPostCount: 0, bodyBase64: [] };
      reposts.set(name, stats);
      if (request.method !== "POST") {
        stats.nonPostCount++;
        response.writeHead(405, { "Cache-Control": "no-store", "Content-Type": "text/plain" });
        response.end("POST required");
      } else {
        const chunks = [];
        request.on("data", chunk => chunks.push(Buffer.from(chunk)));
        request.on("end", () => {
          const body = Buffer.concat(chunks);
          stats.postCount++;
          stats.bodyBase64.push(body.toString("base64"));
          const rendererReload = ["renderer-accept", "unhandled"].includes(name) &&
            stats.postCount === 1;
          const beforeUnload = name === "beforeunload" && stats.postCount === 1;
          response.writeHead(200, { ...headers, "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
          response.end(`<!doctype html><html data-request-method="POST"
            data-request-body-base64="${body.toString("base64")}"><head>
            <title>Cobble Repost ${escapeHTML(name)} ${stats.postCount} ${token}</title></head><body>
            ${beforeUnload ? '<button id="enable-beforeunload">Enable beforeunload</button>' : ''}
            <script>
            ${rendererReload ? "document.documentElement.dataset.reloadAttempted = 'true'; setTimeout(() => location.reload(), 50);" : ""}
            ${beforeUnload ? "document.querySelector('#enable-beforeunload').addEventListener('click', () => { addEventListener('beforeunload', event => { event.preventDefault(); event.returnValue = ''; }); document.documentElement.dataset.beforeunloadActive = 'true'; });" : ""}
            </script></body></html>`);
        });
      }
    } else if (url.pathname === `${prefix}/delayed-title`) {
      response.writeHead(200, {
        ...headers,
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'",
      });
      response.write(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble Validation Pending</title></head><body>`);
      setTimeout(() => response.end(`<script>document.title =
        ${JSON.stringify(`Cobble Validation Settled ${token}`)};</script></body></html>`), 250);
    } else if (url.pathname === `${prefix}/streamed-history-title`) {
      response.writeHead(200, {
        ...headers,
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'",
      });
      response.write(`<!doctype html><html data-run="${token}"><head>
        <title>Cobble Validation Interim ${token}</title></head><body><script>
        history.pushState({}, "", "?phase=during");
        </script>`);
      setTimeout(() => response.end(`<script>
        document.title = ${JSON.stringify(`Cobble Validation Settled ${token}`)};
        addEventListener("load", () => setTimeout(() =>
          history.pushState({}, "", "?phase=after#settled"), 25));
        </script></body></html>`), 250);
    } else if (url.pathname === `${prefix}/website-data-worker.js`) {
      response.writeHead(200, { "Cache-Control": "no-store",
        "Content-Type": "text/javascript; charset=utf-8" });
      response.end("self.addEventListener('fetch', () => {});");
    } else if (url.pathname === `${prefix}/website-data-cache-payload`) {
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "text/plain" });
      response.end(`cache-storage-${token}-${url.searchParams.get("label") ?? ""}`);
    } else if (url.pathname === `${prefix}/website-data-cache-stats`) {
      response.writeHead(200, { "Cache-Control": "no-store", "Content-Type": "application/json" });
      response.end(JSON.stringify(Object.fromEntries(websiteDataCacheHits)));
    } else if (url.pathname === `${prefix}/website-data-setup`) {
      const label = url.searchParams.get("label") ?? "unknown";
      const navigation = url.searchParams.get("navigation") ?? "missing";
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Set-Cookie": `cobble_website_data_${label}=${token}; Path=/; SameSite=Lax`,
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; connect-src 'self'; worker-src 'self'" });
      response.end(`<!doctype html><title>Cobble Website Data Pending</title><script>
        (async () => {
          const label = ${JSON.stringify(label)};
          localStorage.setItem('cobble-website-data-' + label, ${JSON.stringify(token)});
          await new Promise((resolve, reject) => {
            const open = indexedDB.open('cobble-website-data-' + label, 1);
            open.onupgradeneeded = () => open.result.createObjectStore('values');
            open.onerror = () => reject(open.error);
            open.onsuccess = () => {
              const transaction = open.result.transaction('values', 'readwrite');
              transaction.objectStore('values').put(${JSON.stringify(token)}, 'token');
              transaction.oncomplete = () => { open.result.close(); resolve(); };
              transaction.onerror = () => reject(transaction.error);
            };
          });
          const cache = await caches.open('cobble-website-data-' + label);
          await cache.add(${JSON.stringify(`${prefix}/website-data-cache-payload`)} + '?label=' + encodeURIComponent(label));
          await navigator.serviceWorker.register(
            ${JSON.stringify(`${prefix}/website-data-worker.js`)} + '?label=' + encodeURIComponent(label),
            {scope: ${JSON.stringify(`${prefix}/website-data-scope-`)} + encodeURIComponent(label) + '/'});
          document.title = 'Cobble Website Data Ready ' + label + ' ${token} ${escapeHTML(navigation)}';
        })().catch(error => { document.title = 'Cobble Website Data Error ' + error.name; });
      </script>`);
    } else if (url.pathname === `${prefix}/website-data-read`) {
      const label = url.searchParams.get("label") ?? "unknown";
      const navigation = url.searchParams.get("navigation") ?? "missing";
      response.writeHead(200, { ...headers, "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'" });
      response.end(`<!doctype html><html><title>Cobble Website Data Pending</title><body><script>
        (async () => {
          const label = ${JSON.stringify(label)};
          const cookie = document.cookie.includes('cobble_website_data_' + label + '=${token}');
          const local = localStorage.getItem('cobble-website-data-' + label) === ${JSON.stringify(token)};
          const databaseName = 'cobble-website-data-' + label;
          const databaseExists = (await indexedDB.databases()).some(item => item.name === databaseName);
          const indexed = databaseExists && await new Promise(resolve => {
            const open = indexedDB.open(databaseName);
            open.onerror = () => resolve(false);
            open.onsuccess = () => {
              const get = open.result.transaction('values').objectStore('values').get('token');
              get.onsuccess = () => { const value = get.result === ${JSON.stringify(token)}; open.result.close(); resolve(value); };
              get.onerror = () => { open.result.close(); resolve(false); };
            };
          });
          const cacheName = 'cobble-website-data-' + label;
          const cached = await caches.has(cacheName) && !!(await (await caches.open(cacheName)).match(
            ${JSON.stringify(`${prefix}/website-data-cache-payload`)} + '?label=' + encodeURIComponent(label)));
          const registrations = await navigator.serviceWorker.getRegistrations();
          const worker = registrations.some(item => item.active?.scriptURL.includes('label=' + encodeURIComponent(label)) ||
            item.waiting?.scriptURL.includes('label=' + encodeURIComponent(label)) ||
            item.installing?.scriptURL.includes('label=' + encodeURIComponent(label)));
          for (const [name, value] of Object.entries({cookie, local, indexed, cached, worker}))
            document.documentElement.dataset[name] = value ? '1' : '0';
          document.title = 'Cobble Website Data State ' + [cookie, local, indexed, cached, worker].map(Boolean).map(Number).join('') + ' ' + label + ' ${token} ${escapeHTML(navigation)}';
        })().catch(error => { document.title = 'Cobble Website Data Error ' + error.name; });
      </script></body></html>`);
    } else if (url.pathname === `${prefix}/website-data-cache-load`) {
      const key = url.searchParams.get("key") ?? "unknown";
      websiteDataCacheHits.set(key, (websiteDataCacheHits.get(key) ?? 0) + 1);
      response.writeHead(200, { ...headers, "Cache-Control": "private, max-age=3600" });
      response.end(`<!doctype html><title>Cobble Disk Cache Loaded ${escapeHTML(key)} ${token} ${websiteDataCacheHits.get(key)}</title>`);
    } else if (url.pathname === `${prefix}/validation-write`) {
      response.writeHead(200, {
        ...headers,
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'",
        "Set-Cookie": `cobble_validation=${token}; Path=/`,
      });
      response.end(`<!doctype html><html data-run="${token}"><head>
        <title>Checking validation storage write</title></head><body><script>
        localStorage.setItem("cobble_validation", ${JSON.stringify(token)});
        const written = document.cookie.split("; ").some((item) =>
          item === ${JSON.stringify(`cobble_validation=${token}`)}) &&
          localStorage.getItem("cobble_validation") === ${JSON.stringify(token)};
        if (written) document.title = ${JSON.stringify(`Cobble Validation Written ${token}`)};
        </script></body></html>`);
    } else if (url.pathname === `${prefix}/validation-read`) {
      response.writeHead(200, {
        ...headers,
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'",
      });
      response.end(`<!doctype html><html data-run="${token}"><head><title>Checking validation storage</title>
        </head><body><script>
        const cookie = document.cookie.split("; ").find((item) => item.startsWith("cobble_validation="));
        const local = localStorage.getItem("cobble_validation");
        document.title = cookie === ${JSON.stringify(`cobble_validation=${token}`)} && local === ${JSON.stringify(token)}
          ? ${JSON.stringify(`Cobble Validation Present ${token}`)}
          : !cookie && local === null ? ${JSON.stringify(`Cobble Validation Empty ${token}`)}
          : ${JSON.stringify(`Cobble Validation Partial ${token}`)};
        </script></body></html>`);
    } else if (url.pathname === `${prefix}/result`) {
      const query = escapeHTML(url.searchParams.get("q") ?? "");
      response.writeHead(200, headers);
      response.end(`<!doctype html><html data-run="${token}"><head><title>Cobble Smoke Result</title>
        <style>body{font:18px system-ui;margin:32px}</style></head><body>
        <main><h1>Submitted</h1><output id="result">${query}</output></main></body></html>`);
    } else if (url.pathname === `${prefix}/page-b`) {
      response.writeHead(200, headers);
      response.end(`<!doctype html><html data-run="${token}"><head><title>Cobble Smoke B</title>
        <style>body{margin:32px}#render-card{box-sizing:border-box;width:360px;min-height:96px;
        padding:18px;color:rgb(24,48,72);background:rgb(238,244,250);font:20px system-ui}</style>
        <style>#graphics-canvas{display:block;width:96px;height:96px;margin-top:18px;image-rendering:pixelated}
        #graphics-status{margin-top:8px;font:14px system-ui}</style></head><body><main>
        <div id="render-card">Chromium rendered ${token}</div><canvas id="graphics-canvas" width="8" height="8"
        aria-label="WebGL2 pixel fixture"></canvas><output id="graphics-status" data-state="pending">Checking WebGL2</output>
        <script src="${prefix}/graphics.js"></script></main></body></html>`);
    } else if (url.pathname === `${prefix}/graphics.js`) {
      response.writeHead(200, { ...headers, "Content-Type": "text/javascript; charset=utf-8" });
      response.end(`(() => {
        const expectedPixel = [32, 128, 191, 255];
        const status = document.querySelector("#graphics-status");
        const result = { status: "pending" };
        window.cobbleGraphics = result;
        const samePixel = (pixel) => pixel.length === expectedPixel.length && pixel.every((value, index) => value === expectedPixel[index]);
        const runWorker = () => new Promise((resolveWorker) => {
          if (typeof Worker !== "function" || typeof OffscreenCanvas !== "function") {
            resolveWorker({ status: "unavailable", reason: "Worker or OffscreenCanvas is unavailable in this page" });
            return;
          }
          let worker;
          try { worker = new Worker("${prefix}/graphics-worker.js"); }
          catch (error) {
            resolveWorker({ status: "error", reason: error instanceof Error ? error.message : String(error) });
            return;
          }
          const finish = (value) => { clearTimeout(timeout); worker.terminate(); resolveWorker(value); };
          const timeout = setTimeout(() => finish({ status: "error", reason: "OffscreenCanvas worker timed out" }), 2_000);
          worker.onmessage = (event) => finish(event.data);
          worker.onerror = (event) => finish({ status: "error", reason: event.message || "OffscreenCanvas worker failed" });
          worker.postMessage({ expectedPixel });
        });
        (async () => {
          try {
            const canvas = document.querySelector("#graphics-canvas");
            const gl = canvas.getContext("webgl2", { preserveDrawingBuffer: true });
            if (!gl) throw new Error("WebGL2 context was unavailable");
            gl.clearColor(0.125, 0.5, 0.75, 1);
            gl.clear(gl.COLOR_BUFFER_BIT);
            const pixel = new Uint8Array(4);
            gl.readPixels(4, 4, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
            if (!samePixel(pixel)) throw new Error("WebGL2 readPixels returned " + pixel.join(","));
            const debug = gl.getExtension("WEBGL_debug_renderer_info");
            result.webgl2 = {
              pixel: Array.from(pixel),
              renderer: String(gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER)),
              rendererSource: debug ? "WEBGL_debug_renderer_info" : "GL_RENDERER",
              vendor: String(gl.getParameter(debug ? debug.UNMASKED_VENDOR_WEBGL : gl.VENDOR)),
              version: String(gl.getParameter(gl.VERSION)),
              maxTextureSize: gl.getParameter(gl.MAX_TEXTURE_SIZE),
              maxRenderbufferSize: gl.getParameter(gl.MAX_RENDERBUFFER_SIZE),
              antialias: gl.getContextAttributes()?.antialias === true,
            };
            result.offscreenCanvasWorker = await runWorker();
            if (result.offscreenCanvasWorker.status === "error") {
              throw new Error("OffscreenCanvas worker error: " + result.offscreenCanvasWorker.reason);
            }
            result.status = "passed";
            status.dataset.state = "passed";
            status.textContent = "WebGL2 pixel verified; OffscreenCanvas worker " + result.offscreenCanvasWorker.status;
          } catch (error) {
            result.status = "error";
            result.error = error instanceof Error ? error.message : String(error);
            status.dataset.state = "error";
            status.textContent = "WebGL2 error: " + result.error;
          }
        })();
      })();`);
    } else if (url.pathname === `${prefix}/graphics-worker.js`) {
      response.writeHead(200, { ...headers, "Content-Type": "text/javascript; charset=utf-8" });
      response.end(`self.onmessage = ({ data }) => {
        if (typeof OffscreenCanvas !== "function") {
          self.postMessage({ status: "unavailable", reason: "OffscreenCanvas is unavailable in this worker" });
          return;
        }
        try {
          const canvas = new OffscreenCanvas(2, 2);
          const gl = canvas.getContext("webgl2");
          if (!gl) {
            self.postMessage({ status: "unavailable", reason: "WebGL2 context is unavailable in this worker" });
            return;
          }
          gl.clearColor(0.125, 0.5, 0.75, 1);
          gl.clear(gl.COLOR_BUFFER_BIT);
          const pixel = new Uint8Array(4);
          gl.readPixels(1, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
          const matched = pixel.length === data.expectedPixel.length && pixel.every((value, index) => value === data.expectedPixel[index]);
          self.postMessage(matched ? { status: "passed", pixel: Array.from(pixel) } : { status: "error", reason: "Worker readPixels returned " + pixel.join(","), pixel: Array.from(pixel) });
        } catch (error) {
          self.postMessage({ status: "error", reason: error instanceof Error ? error.message : String(error) });
        }
      };`);
    } else if (request.method === "GET" && [interruptedDownloadName,
      interruptedCancelDownloadName, interruptedReleaseDownloadName].some(name =>
      url.pathname === `${prefix}/download/${name}`)) {
      const name = url.pathname.slice(`${prefix}/download/`.length);
      const match = /^bytes=(\d+)-$/.exec(request.headers.range ?? "");
      const start = match ? Number(match[1]) : 0;
      const remaining = interruptedDownload.subarray(start);
      response.writeHead(start ? 206 : 200, {
        "Accept-Ranges": "bytes", "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${name}"`,
        "Content-Length": remaining.length,
        ...(start ? { "Content-Range": `bytes ${start}-${interruptedDownload.length - 1}/${interruptedDownload.length}` } : {}),
        "Content-Type": "application/octet-stream", "ETag": `"${token}"`,
      });
      const resumeGeneration = downloadDirectory ? [2, 1].find(generation => existsSync(join(
        downloadDirectory, `.resume-requested-${generation}-${name}`))) ?? 0 : 2;
      const shouldInterrupt = name !== interruptedDownloadName || resumeGeneration < 2;
      if (shouldInterrupt) {
        response.write(remaining.subarray(0, Math.min(96 * 1024, remaining.length)));
        setTimeout(() => response.destroy(), 20);
      } else {
        response.end(remaining);
      }
    } else if (request.method === "POST" &&
      url.pathname === `${prefix}/download/${interruptedPOSTDownloadName}`) {
      response.writeHead(200, {
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${interruptedPOSTDownloadName}"`,
        "Content-Length": interruptedDownload.length,
        "Content-Type": "application/octet-stream",
      });
      response.write(interruptedDownload.subarray(0, 96 * 1024));
      setTimeout(() => response.destroy(), 20);
    } else if (url.pathname === `${prefix}/download/${networkDownloadName}`) {
      response.writeHead(200, {
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${networkDownloadName}"`,
        "Content-Length": networkDownload.length,
        "Content-Type": "text/plain; charset=utf-8",
      });
      let offset = 0;
      const timer = setInterval(() => {
        if (offset >= networkDownload.length) {
          clearInterval(timer);
          response.end();
          return;
        }
        const end = Math.min(offset + 64 * 1024, networkDownload.length);
        response.write(networkDownload.subarray(offset, end));
        offset = end;
      }, 10);
      response.once("close", () => clearInterval(timer));
    } else if (url.pathname === `${prefix}/local-http-redirect`) {
      response.writeHead(302, { "Cache-Control": "no-store", "Location": `${prefix}/page-a` });
      response.end();
    } else if (url.pathname === `${prefix}/local-file-redirect`) {
      const target = url.searchParams.get("target");
      response.writeHead(302, { "Cache-Control": "no-store", "Location": target || `${prefix}/page-a` });
      response.end();
    } else if (url.pathname === `${prefix}/local-no-content`) {
      response.writeHead(204, { "Cache-Control": "no-store" });
      response.end();
    } else if (url.pathname === `${prefix}/local-abort`) {
      request.socket.destroy();
    } else if (url.pathname.startsWith(`${prefix}/client-certificate/`)) {
      const name = url.pathname.slice(`${prefix}/client-certificate/`.length);
      if (!request.socket.authorized || !clientCertificateNames.includes(name)) {
        response.writeHead(403, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
        response.end("Client certificate required");
      } else {
        const peer = request.socket.getPeerCertificate();
        clientCertificateStats[name].requests += 1;
        clientCertificateStats[name].peerSerials.push((peer.serialNumber ?? "").replaceAll(":", "").toUpperCase());
        if (name === "document") {
          response.writeHead(200, { "Access-Control-Allow-Credentials": "true",
            "Access-Control-Allow-Origin": origin, "Cache-Control": "no-store",
            "Content-Type": "text/plain; charset=utf-8", "Vary": "Origin" });
          response.end(`AUTHENTICATED-${token}`);
        } else {
          response.writeHead(200, headers);
          response.end(`<!doctype html><title>Cobble Client Certificate ${name} ${token}</title>` +
            `<main data-client-certificate="${name}">AUTHENTICATED-${escapeHTML(token)}</main>`);
        }
      }
    } else if (url.pathname === `${prefix}/download/${pausedDownloadName}`) {
      response.writeHead(200, {
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${pausedDownloadName}"`,
        "Content-Length": pausedDownload.length,
        "Content-Type": "application/octet-stream",
      });
      let offset = 0;
      const timer = setInterval(() => {
        const end = Math.min(offset + 16 * 1024, pausedDownload.length);
        response.write(pausedDownload.subarray(offset, end));
        offset = end;
        if (offset === pausedDownload.length) { clearInterval(timer); response.end(); }
      }, 20);
      response.once("close", () => clearInterval(timer));
    } else if (url.pathname === `${prefix}/download/${unknownTotalDownloadName}`) {
      response.writeHead(200, {
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${unknownTotalDownloadName}"`,
        "Content-Type": "application/octet-stream",
      });
      let offset = 0;
      const timer = setInterval(() => {
        const end = Math.min(offset + 8 * 1024, unknownTotalDownload.length);
        response.write(unknownTotalDownload.subarray(offset, end));
        offset = end;
        if (offset === unknownTotalDownload.length) { clearInterval(timer); response.end(); }
      }, 10);
      response.once("close", () => clearInterval(timer));
    } else if ([cancelledDownloadName, existingDestinationDownloadName,
      pausedCancelledDownloadName, danglingDestinationDownloadName].some((name) =>
      url.pathname === `${prefix}/download/${name}`)) {
      const downloadName = url.pathname.slice(`${prefix}/download/`.length);
      response.writeHead(200, {
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="${downloadName}"`,
        "Content-Type": "application/octet-stream",
      });
      const chunk = Buffer.alloc(64 * 1024, 0x4f);
      const timer = setInterval(() => response.write(chunk), 10);
      response.once("close", () => clearInterval(timer));
    } else {
      response.writeHead(404, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
      response.end("Not found");
    }
  };
  const certificateDirectory = await mkdtemp(join(tmpdir(), "cobble-chromium-tls-"));
  const makeCertificate = async (name) => {
    const key = join(certificateDirectory, `${name}.key`);
    const cert = join(certificateDirectory, `${name}.crt`);
    await promisify(execFile)("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-days", "1", "-subj", "/CN=127.0.0.1",
      "-keyout", key, "-out", cert]);
    return { key: await readFile(key), cert: await readFile(cert) };
  };
  const makeTrustedChain = async () => {
    const intermediateKey = join(certificateDirectory, "intermediate.key");
    const intermediateCert = join(certificateDirectory, "intermediate.crt");
    const intermediateConfig = join(certificateDirectory, "intermediate.cnf");
    await writeFile(intermediateConfig, `[req]\nprompt=no\ndistinguished_name=dn\n` +
      `x509_extensions=v3_ca\n[dn]\nCN=Cobble Fixture Intermediate\n` +
      `[v3_ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n`);
    await promisify(execFile)("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
      "-nodes", "-days", "1", "-config", intermediateConfig,
      "-keyout", intermediateKey, "-out", intermediateCert]);
    const leafKey = join(certificateDirectory, "trusted.key");
    const leafCSR = join(certificateDirectory, "trusted.csr");
    const leafCert = join(certificateDirectory, "trusted.crt");
    const leafConfig = join(certificateDirectory, "trusted.cnf");
    await writeFile(leafConfig, `[req]\nprompt=no\ndistinguished_name=dn\nreq_extensions=req_ext\n` +
      `[dn]\nCN=Cobble Fixture Leaf\n[req_ext]\n` +
      `subjectAltName=IP:127.0.0.1,DNS:cobble-a.test,DNS:sub.cobble-a.test,DNS:cobble-b.test\n` +
      `basicConstraints=critical,CA:false\n` +
      `keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n`);
    await promisify(execFile)("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048",
      "-nodes", "-config", leafConfig, "-keyout", leafKey, "-out", leafCSR]);
    await promisify(execFile)("/usr/bin/openssl", ["x509", "-req", "-in", leafCSR,
      "-CA", intermediateCert, "-CAkey", intermediateKey, "-CAcreateserial", "-days", "1",
      "-extfile", leafConfig, "-extensions", "req_ext", "-out", leafCert]);
    const leaf = await readFile(leafCert);
    const intermediate = await readFile(intermediateCert);
    return { key: await readFile(leafKey), cert: Buffer.concat([leaf, intermediate]), leaf };
  };
  const makeClientIdentity = async () => {
    const caKey = join(certificateDirectory, "client-ca.key");
    const caCert = join(certificateDirectory, "client-ca.crt");
    const caConfig = join(certificateDirectory, "client-ca.cnf");
    await writeFile(caConfig, `[req]\nprompt=no\ndistinguished_name=dn\n` +
      `x509_extensions=v3_ca\n[dn]\nCN=Cobble Client Fixture CA\n` +
      `[v3_ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n`);
    await promisify(execFile)("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
      "-nodes", "-days", "1", "-config", caConfig, "-keyout", caKey, "-out", caCert]);
    const key = join(certificateDirectory, "client.key");
    const csr = join(certificateDirectory, "client.csr");
    const cert = join(certificateDirectory, "client.crt");
    const config = join(certificateDirectory, "client.cnf");
    await writeFile(config, `[req]\nprompt=no\ndistinguished_name=dn\nreq_extensions=req_ext\n` +
      `[dn]\nCN=Cobble Client Fixture Leaf\n[req_ext]\n` +
      `basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n` +
      `extendedKeyUsage=clientAuth\n`);
    await promisify(execFile)("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048",
      "-nodes", "-config", config, "-keyout", key, "-out", csr]);
    await promisify(execFile)("/usr/bin/openssl", ["x509", "-req", "-in", csr,
      "-CA", caCert, "-CAkey", caKey, "-CAcreateserial", "-days", "1",
      "-extfile", config, "-extensions", "req_ext", "-out", cert]);
    const p12 = join(certificateDirectory, "client.p12");
    const password = `cobble-${token}`;
    await promisify(execFile)("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key,
      "-in", cert, "-name", "Cobble Client Fixture", "-passout", `pass:${password}`, "-out", p12]);
    const keychain = join(certificateDirectory, "client.keychain-db");
    const keychainHome = join(certificateDirectory, "security-home");
    await mkdir(join(keychainHome, "Library", "Keychains"), { recursive: true });
    const isolatedEnvironment = {
      ...process.env, CFFIXED_USER_HOME: keychainHome,
    };
    try {
      const normalBefore = (await promisify(execFile)(
      "/usr/bin/security", ["list-keychains", "-d", "user"])).stdout;
    await promisify(execFile)("/usr/bin/security",
      ["create-keychain", "-p", password, keychain], { env: isolatedEnvironment });
    await promisify(execFile)("/usr/bin/security",
      ["unlock-keychain", "-p", password, keychain], { env: isolatedEnvironment });
    await promisify(execFile)("/usr/bin/security", ["import", p12, "-k", keychain,
      "-P", password, "-A"], { env: isolatedEnvironment });
    const canonicalKeychain = await realpath(keychain);
    const normalDuring = (await promisify(execFile)(
      "/usr/bin/security", ["list-keychains", "-d", "user"])).stdout;
    const isolatedDuring = (await promisify(execFile)(
      "/usr/bin/security", ["list-keychains", "-d", "user"],
      { env: isolatedEnvironment })).stdout;
    const containsOwned = value => value.includes(keychain) || value.includes(canonicalKeychain);
    assert(!containsOwned(normalBefore) && !containsOwned(normalDuring),
      "Temporary client keychain entered the user's search list");
    const { stdout } = await promisify(execFile)("/usr/bin/openssl", ["x509", "-in", cert,
      "-noout", "-serial"]);
      return {
        ca: await readFile(caCert), keychain, canonicalKeychain, keychainHome,
        serial: stdout.trim().replace(/^serial=/i, ""),
        searchListEvidence: {
          normalBeforeContainedOwnedKeychain: containsOwned(normalBefore),
          normalDuringContainedOwnedKeychain: containsOwned(normalDuring),
          isolatedDuringContainedOwnedKeychain: containsOwned(isolatedDuring),
        },
      };
    } catch (error) {
      if (existsSync(keychain)) {
        try { await promisify(execFile)("/usr/bin/security", ["delete-keychain", keychain],
          { env: isolatedEnvironment }); } catch { /* the original setup error is authoritative */ }
      }
      throw error;
    }
  };
  const [trustedIdentity, untrustedIdentity, clientIdentity] = await Promise.all([
    makeTrustedChain(), makeCertificate("untrusted"), makeClientIdentity(),
  ]);
  const server = createServer(handler);
  const secureServer = createSecureServer(trustedIdentity, handler);
  const invalidSecureServer = createSecureServer(untrustedIdentity, handler);
  const clientCertificateServers = clientCertificateNames.map((name) => createSecureServer({
    key: trustedIdentity.key, cert: trustedIdentity.cert, ca: clientIdentity.ca,
    requestCert: true, rejectUnauthorized: true,
  }, handler).on("connection", () => { clientCertificateStats[name].connections += 1; })
    .on("tlsClientError", () => { clientCertificateStats[name].tlsErrors += 1; })
    .on("secureConnection", () => { clientCertificateStats[name].secureConnections += 1; }));
  const listen = (candidate) => new Promise((resolveListen, reject) => {
    candidate.once("error", reject);
    candidate.listen(0, "127.0.0.1", resolveListen);
  });
  try {
    await Promise.all([listen(server), listen(secureServer), listen(invalidSecureServer),
      ...clientCertificateServers.map(listen)]);
  } catch (error) {
    for (const candidate of [server, secureServer, invalidSecureServer,
      ...clientCertificateServers]) candidate.close();
    const isolatedEnvironment = {
      ...process.env, CFFIXED_USER_HOME: clientIdentity.keychainHome,
    };
    if (existsSync(clientIdentity.keychain)) {
      try { await promisify(execFile)("/usr/bin/security",
        ["delete-keychain", clientIdentity.keychain], { env: isolatedEnvironment }); }
      catch { /* the listen error is authoritative */ }
    }
    await rm(certificateDirectory, { recursive: true, force: true });
    throw error;
  }
  const address = server.address();
  assert(address && typeof address === "object", "Fixture server has no TCP address");
  origin = `http://127.0.0.1:${address.port}`;
  mixedOrigin = `http://cobble-mixed.test:${address.port}`;
  const secureAddress = secureServer.address();
  const invalidSecureAddress = invalidSecureServer.address();
  assert(secureAddress && typeof secureAddress === "object" &&
    invalidSecureAddress && typeof invalidSecureAddress === "object", "TLS fixture servers have no TCP address");
  const secureOrigin = `https://127.0.0.1:${secureAddress.port}`;
  const websiteDataOriginA = `https://cobble-a.test:${secureAddress.port}`;
  const websiteDataSubdomainA = `https://sub.cobble-a.test:${secureAddress.port}`;
  const websiteDataOriginB = `https://cobble-b.test:${secureAddress.port}`;
  const invalidSecureOrigin = `https://127.0.0.1:${invalidSecureAddress.port}`;
  const clientCertificateURLs = Object.fromEntries(clientCertificateNames.map((name, index) => {
    const address = clientCertificateServers[index].address();
    assert(address && typeof address === "object", `Client-certificate ${name} server has no address`);
    return [name, `https://127.0.0.1:${address.port}${prefix}/client-certificate/${name}`];
  }));
  const spkiAllowlist = createHash("sha256").update(
    new X509Certificate(trustedIdentity.leaf).publicKey.export({ type: "spki", format: "der" })).digest("base64");
  return {
    server,
    servers: [server, secureServer, invalidSecureServer, ...clientCertificateServers],
    certificateDirectory,
    requests,
    token,
    origin,
    pageA: `${origin}/fixture/${token}/page-a`,
    resultPath: `/fixture/${token}/result`,
    pageB: `${origin}/fixture/${token}/page-b`,
    networkDownload,
    networkDownloadName,
    networkDownloadURL: `${origin}${prefix}/download/${networkDownloadName}`,
    blobDownload,
    blobDownloadName,
    cancelledDownloadName,
    cancelledDownloadURL: `${origin}${prefix}/download/${cancelledDownloadName}`,
    pausedDownload,
    pausedDownloadName,
    pausedDownloadURL: `${origin}${prefix}/download/${pausedDownloadName}`,
    pausedCancelledDownloadName,
    pausedCancelledDownloadURL: `${origin}${prefix}/download/${pausedCancelledDownloadName}`,
    unknownTotalDownload,
    unknownTotalDownloadName,
    unknownTotalDownloadURL: `${origin}${prefix}/download/${unknownTotalDownloadName}`,
    existingDestinationDownloadName,
    existingDestinationDownloadURL: `${origin}${prefix}/download/${existingDestinationDownloadName}`,
    danglingDestinationDownloadName,
    danglingDestinationDownloadURL: `${origin}${prefix}/download/${danglingDestinationDownloadName}`,
    interruptedDownload,
    interruptedDownloadName,
    interruptedDownloadURL: `${origin}${prefix}/download/${interruptedDownloadName}`,
    interruptedCancelDownloadName,
    interruptedCancelDownloadURL: `${origin}${prefix}/download/${interruptedCancelDownloadName}`,
    interruptedReleaseDownloadName,
    interruptedReleaseDownloadURL: `${origin}${prefix}/download/${interruptedReleaseDownloadName}`,
    interruptedPOSTDownloadName,
    interruptedPOSTDownloadURL: `${origin}${prefix}/download/${interruptedPOSTDownloadName}`,
    extensionTarget: `${origin}${prefix}/extension-target`,
    delayedTitle: `${origin}${prefix}/delayed-title`,
    streamedHistoryTitle: `${origin}${prefix}/streamed-history-title`,
    validationWrite: `${origin}${prefix}/validation-write`,
    validationRead: `${origin}${prefix}/validation-read`,
    websiteData: {
      aSetup: `${websiteDataOriginA}${prefix}/website-data-setup?label=a`,
      aRead: `${websiteDataOriginA}${prefix}/website-data-read?label=a`,
      subdomainSetup: `${websiteDataSubdomainA}${prefix}/website-data-setup?label=sub`,
      subdomainRead: `${websiteDataSubdomainA}${prefix}/website-data-read?label=sub`,
      bSetup: `${websiteDataOriginB}${prefix}/website-data-setup?label=b`,
      bRead: `${websiteDataOriginB}${prefix}/website-data-read?label=b`,
      ipSetup: `${origin}${prefix}/website-data-setup?label=ip`,
      ipRead: `${origin}${prefix}/website-data-read?label=ip`,
      aCache: `${websiteDataOriginA}${prefix}/website-data-cache-load?key=domain-a`,
      oldCache: `${websiteDataOriginA}${prefix}/website-data-cache-load?key=old`,
      newCache: `${websiteDataOriginA}${prefix}/website-data-cache-load?key=new`,
      bCache: `${websiteDataOriginB}${prefix}/website-data-cache-load?key=domain-b`,
      cacheStats: `${origin}${prefix}/website-data-cache-stats`,
      domainA: "cobble-a.test",
      domainB: "cobble-b.test",
      token,
    },
    securePage: `${secureOrigin}${prefix}/secure`,
    mixedPage: `${secureOrigin}${prefix}/mixed`,
    invalidSecurePage: `${invalidSecureOrigin}${prefix}/secure`,
    mediaPage: `${secureOrigin}${prefix}/media`,
    blockingPage: `${secureOrigin}${prefix}/blocking`,
    domPage: `${origin}${prefix}/dom`,
    reloadGET: `${origin}${prefix}/reload-get`,
    reloadPOSTStart: `${origin}${prefix}/reload-post-start`,
    reloadPOSTTarget: `${origin}${prefix}/reload-post`,
    hoverTarget: `${origin}${prefix}/hover-target`,
    externalProtocolShutdown: `${origin}${prefix}/external-protocol?case=shutdown`,
    spkiAllowlist,
    clientCertificate: {
      ...clientCertificateURLs, keychain: clientIdentity.keychain,
      canonicalKeychain: clientIdentity.canonicalKeychain,
      keychainHome: clientIdentity.keychainHome,
      keychainSearchListEvidence: clientIdentity.searchListEvidence,
      documentPage: `${origin}${prefix}/client-certificate-document`,
      subject: "Cobble Client Fixture Leaf", issuer: "Cobble Client Fixture CA",
      serial: clientIdentity.serial, stats: clientCertificateStats,
      mainNames: mainClientCertificateNames, emptyNames: emptyClientCertificateNames,
    },
  };
}

export async function closeFixture(fixture) {
  try {
    for (const server of fixture.servers ?? [fixture.server]) server.closeAllConnections();
    await Promise.all((fixture.servers ?? [fixture.server]).map((server) =>
      new Promise((resolveClose) => server.close(resolveClose))));
  } finally {
    try { await deleteFixtureClientKeychain(fixture); }
    finally {
      if (fixture.certificateDirectory) {
        await rm(fixture.certificateDirectory, { recursive: true, force: true });
      }
    }
  }
}

async function deleteFixtureClientKeychain(fixture) {
  const client = fixture?.clientCertificate;
  if (!client?.keychain || client.keychainDeleted) return;
  const isolatedEnvironment = {
    ...process.env, CFFIXED_USER_HOME: client.keychainHome,
  };
  if (existsSync(client.keychain)) {
    await promisify(execFile)("/usr/bin/security", ["delete-keychain", client.keychain],
      { env: isolatedEnvironment });
  }
  const normalAfter = (await promisify(execFile)(
    "/usr/bin/security", ["list-keychains", "-d", "user"])).stdout;
  assert(!normalAfter.includes(client.keychain) &&
    !normalAfter.includes(client.canonicalKeychain),
    "Owned client keychain remained in the user's search list after deletion");
  client.keychainSearchListEvidence.normalAfterDeleteContainedOwnedKeychain =
    normalAfter.includes(client.keychain) || normalAfter.includes(client.canonicalKeychain);
  client.keychainDeleted = true;
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function poll(label, timeoutMs, action) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    if (interruptedSignal) fail(`Interrupted by ${interruptedSignal}`);
    try {
      const value = await action();
      if (value !== undefined && value !== false && value !== null) return value;
    } catch (error) {
      if (error instanceof FatalSmokeError) throw error;
      lastError = error;
    }
    await delay(75);
  }
  fail(`${label} timed out${lastError ? `: ${lastError.message}` : ""}`);
}

async function fetchJSON(url, timeoutMs = 2_000) {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  assert(response.ok, `${url} returned HTTP ${response.status}`);
  return response.json();
}

class CDPConnection {
  constructor(url) {
    this.url = url;
    this.socket = undefined;
    this.nextID = 1;
    this.pending = new Map();
  }

  async connect(timeoutMs) {
    const socket = new WebSocket(this.url);
    this.socket = socket;
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (!message.id) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(
        `CDP ${pending.method} failed (${message.error.code}): ${message.error.message}`));
      else pending.resolve(message.result ?? {});
    });
    socket.addEventListener("close", () => this.rejectPending("CDP connection closed"));
    socket.addEventListener("error", () => this.rejectPending("CDP connection failed"));
    await new Promise((resolveOpen, reject) => {
      const timer = setTimeout(() => reject(new Error("CDP WebSocket connection timed out")), timeoutMs);
      socket.addEventListener("open", () => { clearTimeout(timer); resolveOpen(); }, { once: true });
      socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("CDP WebSocket connection failed")); }, { once: true });
    });
  }

  rejectPending(message) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
    }
    this.pending.clear();
  }

  send(method, params = {}, timeoutMs = 5_000) {
    assert(this.socket?.readyState === WebSocket.OPEN, "CDP WebSocket is not open");
    const id = this.nextID++;
    return new Promise((resolveCommand, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, { method, resolve: resolveCommand, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    this.socket?.close();
  }
}

async function evaluate(cdp, expression) {
  const response = await cdp.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (response.exceptionDetails) fail(`JavaScript evaluation failed: ${response.exceptionDetails.text}`);
  return response.result?.value;
}

async function waitForDocument(cdp, expression, label, timeoutMs) {
  return poll(label, timeoutMs, async () => {
    const ready = await evaluate(cdp,
      `document.readyState === "complete" && (${expression})`);
    return ready === true;
  });
}

function loopbackWebSocket(rawURL, expectedPort) {
  const url = new URL(rawURL);
  assert(url.protocol === "ws:", "DevTools endpoint is not an unencrypted loopback WebSocket");
  assert(["127.0.0.1", "localhost", "[::1]"].includes(url.hostname),
    "DevTools endpoint is not bound to a loopback hostname");
  assert(Number(url.port) === expectedPort, "DevTools endpoint reported an unexpected port");
  url.hostname = "127.0.0.1";
  return url.href;
}

async function waitForDevTools(profilePath, child, timeoutMs) {
  const portFile = join(profilePath, "DevToolsActivePort");
  const endpoint = await poll("DevToolsActivePort", timeoutMs, async () => {
    if (child.spawnError) failFatal(`Harness could not launch: ${child.spawnError.message}`);
    if (child.exitCode !== null || child.signalCode !== null) {
      failFatal(`Harness exited before DevTools started (${child.signalCode ?? `code ${child.exitCode}`})`);
    }
    const lines = (await readFile(portFile, "utf8")).trim().split(/\r?\n/);
    const port = Number(lines[0]);
    if (!Number.isInteger(port) || port < 1 || port > 65_535 || !lines[1]) return false;
    return { port, browserPath: lines[1] };
  });
  const baseURL = `http://127.0.0.1:${endpoint.port}`;
  const version = await poll("loopback DevTools HTTP endpoint", timeoutMs,
    () => fetchJSON(`${baseURL}/json/version`).catch(() => false));
  const browserWebSocket = loopbackWebSocket(version.webSocketDebuggerUrl, endpoint.port);
  assert(new URL(browserWebSocket).pathname === endpoint.browserPath,
    "DevToolsActivePort browser endpoint differs from /json/version");
  return { ...endpoint, baseURL, browserWebSocket, version };
}

async function terminate(child) {
  if (!child) return;
  try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill("SIGTERM"); }
  const waitForExit = (timeoutMs) => {
    if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
    return Promise.race([
      new Promise((resolveExit) => child.once("exit", () => resolveExit(true))),
      delay(timeoutMs).then(() => false),
    ]);
  };
  const exited = await waitForExit(5_000);
  if (!exited) {
    try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); }
    await waitForExit(5_000);
  }
  try { process.kill(-child.pid, "SIGKILL"); } catch { /* process group is gone */ }
}

function processTreeSample(rootPID) {
  const output = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,rss=,%cpu=,comm="], {
    encoding: "utf8", env: { ...process.env, LC_ALL: "C" },
    maxBuffer: 4 * 1024 * 1024,
  });
  const rows = output.split("\n").flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parentPID: Number(match[2]),
      rssKiB: Number(match[3]), cpuPercent: Number(match[4]), command: match[5] }] : [];
  });
  const ids = new Set([rootPID]);
  for (let changed = true; changed;) {
    changed = false;
    for (const row of rows) {
      if (ids.has(row.parentPID) && !ids.has(row.pid)) {
        ids.add(row.pid);
        changed = true;
      }
    }
  }
  const processes = rows.filter((row) => ids.has(row.pid));
  assert(processes.some((row) => row.pid === rootPID),
    "Harness process disappeared before the resource observation");
  return {
    timestamp: new Date().toISOString(),
    summedRSSKiB: processes.reduce((total, row) => total + row.rssKiB, 0),
    summedCPUPercent: processes.reduce((total, row) => total + row.cpuPercent, 0),
    processes,
  };
}

async function observeIdleProcessTree(rootPID) {
  await delay(250);
  const samples = [];
  for (let index = 0; index < 3; index++) {
    samples.push(processTreeSample(rootPID));
    if (index < 2) await delay(250);
  }
  return {
    sampleIntervalMs: 250,
    samples,
    caveat: "Raw summed RSS double-counts shared pages and is not physical footprint; ps CPU is a point observation; descendants can omit launchd-parented XPC services. Do not infer Chromium/WebKit savings from this smoke run.",
  };
}

async function observePhysicalFootprint(rootPID, artifactsPath) {
  const jsonPath = join(artifactsPath, "footprint.json");
  const logPath = join(artifactsPath, "footprint.log");
  try {
    await access("/usr/bin/footprint", constants.X_OK);
    const { stdout, stderr } = await promisify(execFile)("/usr/bin/footprint", [
      "--pid", String(rootPID), "--targetChildren", "--noCategories",
      "--format", "bytes", "--sample", "1", "--sample-duration", "3",
      "--json", jsonPath,
    ], { encoding: "utf8", timeout: 10_000, maxBuffer: 1024 * 1024 });
    await writeFile(logPath, `${stdout}\n${stderr}`);
    JSON.parse(await readFile(jsonPath, "utf8"));
    return {
      status: "recorded", jsonPath, logPath, requestedDurationMs: 3_000,
      caveat: "Scoped macOS footprint includes attributed child services and de-duplicates shared memory. Preserve the process list and any tool warnings; this short synthetic sample is not a comparative benchmark.",
    };
  } catch (error) {
    await writeFile(logPath, String(error.stderr ?? error.message ?? error).slice(-32_000));
    return { status: "unavailable", logPath,
      reason: "The macOS footprint diagnostic could not produce a sample; core rendering checks are independent." };
  }
}

// Inspect only the throwaway profiles created by this harness, after a clean
// exit. System SQLite may require write access to reconcile journal state; the
// queries below do not mutate browsing data or schema.
export async function checkHistoryStorage(profilePath) {
  const { stdout } = await promisify(execFile)("python3", ["-c", `
import json, pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
results = []
record_tables = ("urls", "visits", "downloads", "downloads_url_chains", "downloads_slices")
deleted_profiles = {"Cobble-harness-validation", "Cobble-harness-delete-failure"}
for name in ("Default", "Cobble-harness", "Cobble-harness-validation",
             "Cobble-harness-validation-other", "Cobble-harness-delete-failure"):
    profile = root / name
    if name in deleted_profiles:
        if profile.exists():
            raise ValueError("Deleted isolated harness profile still exists: " + name)
        results.append({"profile": name, "status": "absent", **dict.fromkeys(record_tables, 0)})
        continue
    if name.startswith("Cobble-") and not profile.is_dir():
        raise ValueError("Expected isolated harness profile was not created")
    if profile.is_symlink():
        raise ValueError("Harness profile must not be a symbolic link")
    database = profile / "History"
    if database.is_symlink():
        raise ValueError("Harness History database must not be a symbolic link")
    if not database.exists():
        results.append({"profile": name, "status": "absent", **dict.fromkeys(record_tables, 0)})
        continue
    with sqlite3.connect(database.as_uri() + "?mode=rw", uri=True) as connection:
        if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("Cannot validate a corrupt harness History database")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        counts = {table: connection.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
                  if table in tables else 0 for table in record_tables}
        if any(counts.values()):
            raise ValueError("Chromium saved hidden browsing history in " + name + ": " + str(counts))
        results.append({"profile": name, "status": "empty", **counts})
print(json.dumps({"profiles": results}))
`, profilePath], { encoding: "utf8", timeout: 10_000, maxBuffer: 64 * 1024 });
  return JSON.parse(stdout);
}

function parseArguments() {
  const values = process.argv.slice(2);
  let appPath;
  let artifactsPath;
  let timeoutMs = DEFAULT_TIMEOUT_MS;
  let skipExternalShutdown = false;
  let skipDevToolsFrontendProbe = false;
  let skipLocalFileValidation = false;
  let skipRepostValidation = false;
  let localFileDiagnostics = false;
  for (let index = 0; index < values.length; index++) {
    const value = values[index];
    if (value === "--artifacts") {
      artifactsPath = values[++index];
      assert(artifactsPath, "--artifacts requires a directory");
    } else if (value === "--timeout-ms") {
      const timeout = values[++index];
      assert(timeout, "--timeout-ms requires a value");
      timeoutMs = Number(timeout);
    } else if (value === "--skip-external-shutdown") skipExternalShutdown = true;
    else if (value === "--skip-devtools-frontend-probe") skipDevToolsFrontendProbe = true;
    else if (value === "--skip-local-file-validation") skipLocalFileValidation = true;
    else if (value === "--skip-repost-validation") skipRepostValidation = true;
    else if (value === "--cobble-local-file-diagnostics") localFileDiagnostics = true;
    else if (!appPath) appPath = value;
    else fail(`Unexpected argument: ${value}`);
  }
  assert(appPath, "Usage: node scripts/smoke.mjs <Harness.app> [--artifacts <directory>] [--timeout-ms <milliseconds>]");
  assert(Number.isInteger(timeoutMs) && timeoutMs >= 5_000 && timeoutMs <= 120_000,
    "--timeout-ms must be between 5000 and 120000");
  const stamp = new Date().toISOString().replaceAll(/[:.]/g, "-");
  return {
    appPath: resolve(appPath),
    artifactsPath: resolve(artifactsPath ?? join(ROOT, "artifacts", `smoke-${stamp}`)),
    timeoutMs,
    skipExternalShutdown,
    skipDevToolsFrontendProbe,
    skipLocalFileValidation,
    skipRepostValidation,
    localFileDiagnostics,
  };
}

async function main() {
  const startedAt = new Date().toISOString();
  const options = parseArguments();
  await mkdir(options.artifactsPath, { recursive: true });
  console.log(`Smoke artifacts: ${options.artifactsPath}`);
  assert(typeof fetch === "function" && typeof WebSocket === "function",
    "This smoke test requires a Node release with built-in fetch and WebSocket support");

  const profilePath = await import("node:fs/promises").then(({ mkdtemp }) =>
    mkdtemp(join(tmpdir(), "cobble-chromium-smoke-")));
  const downloadPath = join(profilePath, "Harness Downloads");
  const validationReportPath = join(options.artifactsPath, "native-validation.json");
  const popupReportPath = join(options.artifactsPath, "native-popups.json");
  const metadataReportPath = join(options.artifactsPath, "native-metadata.json");
  const promptCrashMarkerPath = join(options.artifactsPath, "prompt-crash-ready.json");
  const beforeUnloadMarkerPath = join(options.artifactsPath, "beforeunload-ready.json");
  const beforeUnloadActivatedPath = join(options.artifactsPath, "beforeunload-activated");
  const repostBeforeUnloadMarkerPath = join(options.artifactsPath, "repost-beforeunload-ready.json");
  const repostBeforeUnloadActivatedPath = join(options.artifactsPath, "repost-beforeunload-activated");
  const fileChooserMarkerPath = join(options.artifactsPath, "file-chooser-action.json");
  const exclusiveAccessMarkerPath = join(options.artifactsPath, "exclusive-access-action.json");
  const exclusiveAccessOutcomePath = join(options.artifactsPath, "exclusive-access-outcomes.json");
  const postReloadMarkerPath = join(options.artifactsPath, "post-reload-action.json");
  const postReloadActivatedPath = join(options.artifactsPath, "post-reload-activated");
  const externalProtocolMarkerPath = join(options.artifactsPath, "external-protocol-action.json");
  const externalProtocolActivatedPath = join(options.artifactsPath, "external-protocol-activated");
  const devToolsMarkerPath = join(options.artifactsPath, "devtools-action.json");
  const devToolsResultPath = join(options.artifactsPath, "devtools-result.json");
  const validationStagePath = join(options.artifactsPath, "native-validation.stage");
  await mkdir(downloadPath, { recursive: true });
  await rm(validationReportPath, { force: true });
  await rm(popupReportPath, { force: true });
  await rm(metadataReportPath, { force: true });
  await rm(promptCrashMarkerPath, { force: true });
  await rm(beforeUnloadMarkerPath, { force: true });
  await rm(beforeUnloadActivatedPath, { force: true });
  await rm(repostBeforeUnloadMarkerPath, { force: true });
  await rm(repostBeforeUnloadActivatedPath, { force: true });
  await rm(fileChooserMarkerPath, { force: true });
  await rm(exclusiveAccessMarkerPath, { force: true });
  await rm(exclusiveAccessOutcomePath, { force: true });
  await rm(postReloadMarkerPath, { force: true });
  await rm(postReloadActivatedPath, { force: true });
  await rm(externalProtocolMarkerPath, { force: true });
  await rm(externalProtocolActivatedPath, { force: true });
  await rm(devToolsMarkerPath, { force: true });
  await rm(devToolsResultPath, { force: true });
  await rm(validationStagePath, { force: true });
  let fixture;
  let child;
  let restartChild;
  let shutdownChild;
  let shutdownProfilePath;
  let devToolsShutdownChild;
  let devToolsShutdownProfilePath;
  const clientCertificateEmptyChildren = [];
  let cdp;
  let report;
  try {
    const harness = await validateHarness(options.appPath);
    fixture = await startFixture(randomUUID(), downloadPath);
    const stdoutPath = join(options.artifactsPath, "harness.stdout.log");
    const stderrPath = join(options.artifactsPath, "harness.stderr.log");
    const stdout = openSync(stdoutPath, "wx");
    const stderr = openSync(stderrPath, "wx");
    const launchStartedAtMs = Date.now();
    const launchArguments = [
      "--remote-debugging-address=127.0.0.1",
      "--remote-debugging-port=0",
      `--user-data-dir=${profilePath}`,
      "--no-first-run",
      // Invalid-extension regression errors must return through the API,
      // without an unattended test waiting on a Chromium warning dialog.
      "--noerrdialogs",
      "--no-default-browser-check",
      // Upstream test-only keychain keeps this disposable, loopback-only
      // workload away from the user's global Chromium Safe Storage item.
      "--use-mock-keychain",
      "--use-fake-device-for-media-stream",
      "--allow-running-insecure-content",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-sync",
      "--no-pings",
      "--enable-features=AllowWithholdingExtensionPermissionsOnInstall",
      `--ignore-certificate-errors-spki-list=${fixture.spkiAllowlist}`,
      "--host-resolver-rules=MAP cobble-mixed.test 127.0.0.1, MAP cobble-recovery.test 127.0.0.1, MAP cobble-auth.test 127.0.0.1, MAP cobble-auth-direct.test 127.0.0.1, MAP cobble-auth-cancel.test 127.0.0.1, MAP cobble-auth-subresource.test 127.0.0.1, MAP cobble-beforeunload.test 127.0.0.1, MAP cobble-crash.test 127.0.0.1, MAP cobble-a.test 127.0.0.1, MAP sub.cobble-a.test 127.0.0.1, MAP cobble-b.test 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost",
    ];
    if (options.localFileDiagnostics) launchArguments.push("--cobble-local-file-diagnostics");
    launchArguments.push(`--cobble-client-cert-test-keychain=${fixture.clientCertificate.keychain}`);
    child = spawn(harness.binaryPath, launchArguments, {
      detached: true,
      env: {
        ...process.env,
        COBBLE_CHROMIUM_HARNESS_URL: fixture.pageA,
        COBBLE_CHROMIUM_HARNESS_DOWNLOAD_DIRECTORY: downloadPath,
        COBBLE_CHROMIUM_VALIDATION_REPORT: validationReportPath,
        COBBLE_CHROMIUM_VALIDATION_SECURE_URL: fixture.securePage,
        COBBLE_CHROMIUM_VALIDATION_MIXED_URL: fixture.mixedPage,
        COBBLE_CHROMIUM_VALIDATION_INVALID_TLS_URL: fixture.invalidSecurePage,
        COBBLE_CHROMIUM_VALIDATION_MEDIA_URL: fixture.mediaPage,
        COBBLE_CHROMIUM_WEBSITE_DATA_URLS: JSON.stringify(fixture.websiteData),
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_SELECT_URL: fixture.clientCertificate.select,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_CANCEL_URL: fixture.clientCertificate.cancel,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_UNHANDLED_URL: fixture.clientCertificate.unhandled,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_STALE_URL: fixture.clientCertificate.stale,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_CLOSE_URL: fixture.clientCertificate.close,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_REENTRANT_URL: fixture.clientCertificate.reentrant,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_DOCUMENT_PAGE: fixture.clientCertificate.documentPage,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_DOCUMENT_RESOURCE: fixture.clientCertificate.document,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_SUBJECT: fixture.clientCertificate.subject,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_ISSUER: fixture.clientCertificate.issuer,
        COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_SERIAL: fixture.clientCertificate.serial,
        COBBLE_CHROMIUM_VALIDATION_INTERRUPTED_RELEASE_URL:
          fixture.interruptedReleaseDownloadURL,
        COBBLE_CHROMIUM_VALIDATION_USER_DATA_DIR: profilePath,
        COBBLE_CHROMIUM_VALIDATION_DOWNLOAD_DIRECTORY: downloadPath,
        COBBLE_CHROMIUM_POPUP_REPORT: popupReportPath,
        COBBLE_CHROMIUM_METADATA_REPORT: metadataReportPath,
        COBBLE_CHROMIUM_PROMPT_CRASH_MARKER: promptCrashMarkerPath,
        COBBLE_CHROMIUM_BEFOREUNLOAD_MARKER: beforeUnloadMarkerPath,
        COBBLE_CHROMIUM_BEFOREUNLOAD_ACTIVATED: beforeUnloadActivatedPath,
        COBBLE_CHROMIUM_REPOST_BEFOREUNLOAD_MARKER: repostBeforeUnloadMarkerPath,
        COBBLE_CHROMIUM_REPOST_BEFOREUNLOAD_ACTIVATED: repostBeforeUnloadActivatedPath,
        COBBLE_CHROMIUM_FILE_CHOOSER_MARKER: fileChooserMarkerPath,
        COBBLE_CHROMIUM_EXCLUSIVE_ACCESS_MARKER: exclusiveAccessMarkerPath,
        COBBLE_CHROMIUM_EXCLUSIVE_ACCESS_OUTCOME: exclusiveAccessOutcomePath,
        COBBLE_CHROMIUM_POST_RELOAD_MARKER: postReloadMarkerPath,
        COBBLE_CHROMIUM_POST_RELOAD_ACTIVATED: postReloadActivatedPath,
        COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_MARKER: externalProtocolMarkerPath,
        COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_ACTIVATED: externalProtocolActivatedPath,
        COBBLE_CHROMIUM_DEVTOOLS_MARKER: devToolsMarkerPath,
        COBBLE_CHROMIUM_DEVTOOLS_ACTION: devToolsResultPath,
        COBBLE_CHROMIUM_SKIP_DEVTOOLS_FRONTEND_PROBE:
          options.skipDevToolsFrontendProbe ? "1" : "0",
        COBBLE_CHROMIUM_SKIP_LOCAL_FILE_VALIDATION:
          options.skipLocalFileValidation ? "1" : "0",
        COBBLE_CHROMIUM_SKIP_REPOST_VALIDATION:
          options.skipRepostValidation ? "1" : "0",
        COBBLE_CHROMIUM_VALIDATION_STAGE: validationStagePath,
      },
      stdio: ["ignore", stdout, stderr],
    });
    child.spawnError = undefined;
    child.once("error", (error) => { child.spawnError = error; });
    closeSync(stdout);
    closeSync(stderr);
    assert(Number.isInteger(child.pid), "Harness launch did not return a process identifier");

    const devTools = await waitForDevTools(profilePath, child, options.timeoutMs);
    assert(typeof devTools.version.Browser === "string" &&
      devTools.version.Browser.includes(harness.version),
    "DevTools browser version differs from the SDK manifest");
    assert(typeof devTools.version["Protocol-Version"] === "string",
      "DevTools protocol version is missing");

    const target = await poll("unique loopback fixture page target", options.timeoutMs, async () => {
      const targets = await fetchJSON(`${devTools.baseURL}/json/list`);
      return targets.find((item) => item.type === "page" && item.url === fixture.pageA &&
        item.webSocketDebuggerUrl);
    });
    cdp = new CDPConnection(loopbackWebSocket(target.webSocketDebuggerUrl, devTools.port));
    await cdp.connect(options.timeoutMs);
    const beforeUnloadActivation = (async () => {
      const marker = await poll("beforeunload activation marker", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(beforeUnloadMarkerPath, "utf8")); }
        catch { return false; }
      });
      const activationTarget = await poll("beforeunload activation target", options.timeoutMs, async () =>
        (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
          item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
      const activationCDP = new CDPConnection(loopbackWebSocket(
        activationTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await activationCDP.connect(options.timeoutMs);
        for (const type of ["mousePressed", "mouseReleased"]) {
          await activationCDP.send("Input.dispatchMouseEvent", {
            type, x: 40, y: 40, button: "left", clickCount: 1,
          });
        }
        await writeFile(beforeUnloadActivatedPath, "activated\n", { flag: "wx" });
      } finally {
        activationCDP.close();
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const repostBeforeUnloadActivation = options.skipRepostValidation ?
      Promise.resolve({ passed: true, skipped: true }) : (async () => {
      const marker = await poll("repost beforeunload activation marker", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(repostBeforeUnloadMarkerPath, "utf8")); }
        catch { return false; }
      });
      const activationTarget = await poll("repost beforeunload activation target", options.timeoutMs,
        async () => (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
          item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
      const activationCDP = new CDPConnection(loopbackWebSocket(
        activationTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await activationCDP.connect(options.timeoutMs);
        const located = await activationCDP.send("Runtime.evaluate", {
          expression: `(() => { const rect = document.querySelector('#enable-beforeunload')?.getBoundingClientRect();
            return rect && {x: rect.x, y: rect.y, width: rect.width, height: rect.height}; })()`,
          returnByValue: true,
        });
        assert(!located.exceptionDetails && located.result?.value?.width > 0,
          "Repost beforeunload activation button was unavailable");
        const rect = located.result.value;
        const point = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        for (const type of ["mousePressed", "mouseReleased"]) {
          await activationCDP.send("Input.dispatchMouseEvent", {
            type, ...point, button: "left", clickCount: 1,
          });
        }
        await poll("sticky repost beforeunload activation", 5_000, async () => {
          const active = await activationCDP.send("Runtime.evaluate", {
            expression: "document.documentElement.dataset.beforeunloadActive === 'true'",
            returnByValue: true,
          });
          return active.result?.value === true;
        });
        await writeFile(repostBeforeUnloadActivatedPath, "activated\n", { flag: "wx" });
      } finally {
        activationCDP.close();
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const promptCrash = (async () => {
      const marker = await poll("prompt crash marker", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(promptCrashMarkerPath, "utf8")); }
        catch { return false; }
      });
      const crashTarget = await poll("prompt crash target", options.timeoutMs, async () =>
        (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
          item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
      const crashCDP = new CDPConnection(loopbackWebSocket(
        crashTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await crashCDP.connect(options.timeoutMs);
        try { await crashCDP.send("Page.crash", {}, 5_000); }
        catch { /* Renderer death normally closes CDP before the reply. */ }
      } finally {
        crashCDP.close();
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const fileChooserActions = (async () => {
      for (const sequence of [1, 2, 3, 4]) {
        const marker = await poll(`file chooser action ${sequence}`, options.timeoutMs, async () => {
          try {
            const value = JSON.parse(await readFile(fileChooserMarkerPath, "utf8"));
            return value.sequence === sequence && value;
          } catch { return false; }
        });
        const chooserTarget = await poll(`file chooser target ${sequence}`, options.timeoutMs,
          async () => (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
            item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
        const chooserCDP = new CDPConnection(loopbackWebSocket(
          chooserTarget.webSocketDebuggerUrl, devTools.port));
        try {
          await chooserCDP.connect(options.timeoutMs);
          const action = await chooserCDP.send("Runtime.evaluate", {
            expression: marker.removeFrame
              ? `(() => { const frame = document.querySelector("#chooser"); frame.contentDocument.querySelector("#file").click(); setTimeout(() => frame.remove(), 300); return true; })()`
              : `document.querySelector("#file").click(); true`,
            userGesture: true, returnByValue: true,
          });
          assert(!action.exceptionDetails, `File chooser action ${sequence} threw`);
        } finally {
          chooserCDP.close();
        }
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const exclusiveAccessAction = (async () => {
      const marker = await poll("exclusive access action", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(exclusiveAccessMarkerPath, "utf8")); }
        catch { return false; }
      });
      const exclusiveTarget = await poll("exclusive access target", options.timeoutMs,
        async () => (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
          item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
      const exclusiveCDP = new CDPConnection(loopbackWebSocket(
        exclusiveTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await exclusiveCDP.connect(options.timeoutMs);
        for (const request of ["fullscreen", "pointer", "keyboard"]) {
          const result = await exclusiveCDP.send("Runtime.evaluate", {
            expression: `window.cobbleRunExclusive(${JSON.stringify(request)})`,
            userGesture: true, awaitPromise: true, returnByValue: true,
          }, 5_000);
          assert(!result.exceptionDetails, `${request} request threw`);
        }
        const targetsBeforeContainment = (await fetchJSON(`${devTools.baseURL}/json/list`))
          .map(item => item.id).sort();
        const containment = {};
        for (const capability of ["pip", "documentPip", "displayMedia",
          "bluetooth", "usb", "serial", "hid", "payment"]) {
          const result = await exclusiveCDP.send("Runtime.evaluate", {
            expression: `window.cobbleRunCapability(${JSON.stringify(capability)})`,
            userGesture: true, awaitPromise: true, returnByValue: true,
          });
          assert(!result.exceptionDetails, `${capability} request threw`);
          containment[capability] = result.result?.value;
          await writeFile(exclusiveAccessOutcomePath,
            JSON.stringify({ containment, lastCapability: capability }), { flag: "w" });
        }
        await delay(250);
        const targetsAfterContainment = (await fetchJSON(`${devTools.baseURL}/json/list`))
          .map(item => item.id).sort();
        assert(stableJSON(targetsAfterContainment) === stableJSON(targetsBeforeContainment),
          `Exclusive capability escaped into a new target: ${JSON.stringify({
            targetsBeforeContainment, targetsAfterContainment, containment })}`);
        for (const type of ["keyDown", "keyUp"]) {
          await exclusiveCDP.send("Input.dispatchKeyEvent", {
            type, code: "KeyW", key: "w", windowsVirtualKeyCode: 87,
          });
        }
        const finish = await exclusiveCDP.send("Runtime.evaluate", {
          expression: "window.cobbleExclusiveFinish(); true", returnByValue: true,
        }, 2_000);
        assert(!finish.exceptionDetails && finish.result?.value === true,
          "Exclusive finish evaluation failed");
        await writeFile(exclusiveAccessOutcomePath, JSON.stringify({
          containment, lastCapability: "finish", targetsBeforeContainment,
          targetsAfterContainment,
        }), { flag: "w" });
      } finally {
        exclusiveCDP.close();
      }
      return true;
    })().then((passed) => ({ passed }), (error) => {
      console.error(`exclusive action rejected: ${error.stack ?? error}`);
      return { passed: false, error };
    });
    const postReloadAction = (async () => {
      const marker = await poll("renderer POST reload action", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(postReloadMarkerPath, "utf8")); }
        catch { return false; }
      });
      const reloadTarget = await poll("renderer POST reload target", options.timeoutMs,
        async () => (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
          item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
      const reloadCDP = new CDPConnection(loopbackWebSocket(
        reloadTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await reloadCDP.connect(options.timeoutMs);
        const action = await reloadCDP.send("Runtime.evaluate", {
          expression: "location.reload(); true", userGesture: true, returnByValue: true,
        });
        assert(!action.exceptionDetails, "Renderer POST reload action threw");
        await writeFile(postReloadActivatedPath, "1\n");
      } finally {
        reloadCDP.close();
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const externalProtocolActions = (async () => {
      for (const sequence of [1, 2, 3, 4, 5, 6]) {
        const marker = await poll(`external protocol action ${sequence}`, options.timeoutMs, async () => {
          try {
            const value = JSON.parse(await readFile(externalProtocolMarkerPath, "utf8"));
            return value.sequence === sequence && value;
          } catch { return false; }
        });
        const externalTarget = await poll(`external protocol target ${sequence}`, options.timeoutMs,
          async () => (await fetchJSON(`${devTools.baseURL}/json/list`)).find((item) =>
            item.type === "page" && item.url === marker.url && item.webSocketDebuggerUrl));
        const externalCDP = new CDPConnection(loopbackWebSocket(
          externalTarget.webSocketDebuggerUrl, devTools.port));
        try {
          await externalCDP.connect(options.timeoutMs);
          const action = await externalCDP.send("Runtime.evaluate", {
            expression: marker.frame
              ? `(() => { const frame = document.querySelector("#external-frame"); frame.contentDocument.querySelector("#external").click(); setTimeout(() => frame.remove(), 300); return true; })()`
              : `document.querySelector("#external").click(); true`,
            userGesture: true, returnByValue: true,
          });
          assert(!action.exceptionDetails, `External protocol action ${sequence} threw`);
          await writeFile(externalProtocolActivatedPath, `${sequence}\n`);
        } finally {
          externalCDP.close();
        }
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const devToolsActions = options.skipDevToolsFrontendProbe ?
      Promise.resolve({ passed: true, skipped: true }) : (async () => {
      for (const sequence of [1, 2]) {
        const marker = await poll(`DevTools action ${sequence}`, options.timeoutMs, async () => {
          try {
            const value = JSON.parse(await readFile(devToolsMarkerPath, "utf8"));
            return value.sequence === sequence && value;
          } catch { return false; }
        });
        const selectedFrontend = await poll(`active DevTools frontend ${sequence}`, 10_000, async () => {
          const browserTargets = await fetchJSON(`${devTools.baseURL}/json/list`);
          const candidates = browserTargets.filter((item) =>
            item.url?.startsWith("devtools://devtools/bundled/devtools_app.html") &&
              item.webSocketDebuggerUrl);
          const probes = [];
          for (const candidate of candidates) {
            const connection = new CDPConnection(loopbackWebSocket(
              candidate.webSocketDebuggerUrl, devTools.port));
            try {
              await connection.connect(1_000);
              await connection.send("Runtime.enable", {}, 750);
              const reply = await connection.send("Runtime.evaluate", {
                expression: "location.href", returnByValue: true,
              }, 750);
              probes.push({ id: candidate.id, responsive: true,
                value: reply.result?.value });
              return { target: candidate, connection, probes };
            } catch (error) {
              probes.push({ id: candidate.id, responsive: false,
                error: error instanceof Error ? error.message : String(error) });
              connection.close();
            }
          }
          await writeFile(devToolsResultPath, JSON.stringify({
            sequence, phase: "frontend-candidates", probes,
            browserTargets: browserTargets.map(item =>
              ({ id: item.id, type: item.type, url: item.url, title: item.title })),
          }));
          return false;
        });
        const frontend = selectedFrontend.target;
        const frontendCDP = selectedFrontend.connection;
        const sequenceResultPath = `${devToolsResultPath}.sequence-${sequence}.json`;
        await writeFile(devToolsResultPath, JSON.stringify({
          sequence, phase: "frontend-selected", targetID: frontend.id,
          frontendURL: frontend.url, probes: selectedFrontend.probes,
        }));
        const trace = [{ phase: "frontend-selected", targetID: frontend.id,
          frontendURL: frontend.url, probes: selectedFrontend.probes }];
        try {
          if (sequence === 1) {
            await writeFile(devToolsResultPath, JSON.stringify({ sequence, trace }));
            const record = async (phase, details = {}) => {
              trace.push({ phase, ...details });
              const value = JSON.stringify({ sequence, trace });
              await Promise.all([writeFile(devToolsResultPath, value),
                writeFile(sequenceResultPath, value)]);
            };
            const sendRecorded = async (phase, method, params = {}, timeout = 2_000) => {
              await record(`${phase}-before`, { method });
              try {
                const reply = await frontendCDP.send(method, params, timeout);
                await record(phase, { method, reply });
                return reply;
              } catch (error) {
                await record(`${phase}-error`, { method,
                  error: error instanceof Error ? error.message : String(error) });
                throw error;
              }
            };
            const inspectedExpression =
              `document.documentElement.dataset.run + ":" + location.href`;
            const inspectedValue = `${fixture.token}:${marker.inspectedURL}`;
            const escapeURL = JSON.stringify(marker.escapeURL);
            const deepQuerySource = `const deepQuery = (root, selector) => {
              const queue = [root];
              while (queue.length) {
                const current = queue.shift();
                const match = current.querySelector?.(selector);
                if (match) return match;
                for (const element of current.querySelectorAll?.('*') || []) {
                  if (element.shadowRoot) queue.push(element.shadowRoot);
                }
              }
              return null;
            };`;
            let tab;
            for (let attempt = 0; attempt < 100; attempt++) {
              const tabReply = await sendRecorded(`console-tab-lookup-${attempt}`,
                "Runtime.evaluate", { expression: `(() => { ${deepQuerySource}
                  const tab = deepQuery(document, '#tab-console') ||
                    deepQuery(document, '[aria-label^="Console"]');
                  const rect = tab?.getBoundingClientRect();
                  return {found: Boolean(tab), selected: tab?.getAttribute('aria-selected'),
                    rect: rect && {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
                    frontendURL: location.href, visibility: document.visibilityState,
                    focused: document.hasFocus()};
                })()`, returnByValue: true });
              assert(!tabReply.exceptionDetails, "DevTools Console tab lookup threw");
              if (tabReply.result?.value?.found && tabReply.result.value.rect?.width > 0 &&
                  tabReply.result.value.rect?.height > 0) {
                tab = tabReply.result.value;
                break;
              }
              await delay(50);
            }
            assert(tab?.found && tab.rect?.width > 0 && tab.rect?.height > 0,
              "DevTools Console tab was absent or had no input bounds");
            const tabPoint = { x: tab.rect.x + tab.rect.width / 2,
              y: tab.rect.y + tab.rect.height / 2 };
            await sendRecorded("console-tab-move", "Input.dispatchMouseEvent",
              { type: "mouseMoved", ...tabPoint, button: "none" });
            await sendRecorded("console-tab-press", "Input.dispatchMouseEvent",
              { type: "mousePressed", ...tabPoint, button: "left", clickCount: 1 });
            await sendRecorded("console-tab-release", "Input.dispatchMouseEvent",
              { type: "mouseReleased", ...tabPoint, button: "left", clickCount: 1 });

            let prompt;
            for (let attempt = 0; attempt < 100; attempt++) {
              const reply = await sendRecorded(`console-prompt-lookup-${attempt}`,
                "Runtime.evaluate", { expression: `(() => { ${deepQuerySource}
                  const prompt = deepQuery(document, '#console-prompt');
                  const editor = prompt && deepQuery(prompt, '[contenteditable="true"]');
                  const rect = editor?.getBoundingClientRect();
                  return {ready: Boolean(editor && rect?.width && rect?.height),
                    promptFound: Boolean(prompt), editorFound: Boolean(editor),
                    rect: rect && {x: rect.x, y: rect.y, width: rect.width, height: rect.height}};
                })()`, returnByValue: true });
              assert(!reply.exceptionDetails, "DevTools Console prompt lookup threw");
              if (reply.result?.value?.ready) { prompt = reply.result.value; break; }
              await delay(50);
            }
            assert(prompt, "DevTools Console prompt did not become input-ready");
            const promptPoint = { x: prompt.rect.x + Math.min(24, prompt.rect.width / 2),
              y: prompt.rect.y + prompt.rect.height / 2 };
            await sendRecorded("console-prompt-press", "Input.dispatchMouseEvent",
              { type: "mousePressed", ...promptPoint, button: "left", clickCount: 1 });
            await sendRecorded("console-prompt-release", "Input.dispatchMouseEvent",
              { type: "mouseReleased", ...promptPoint, button: "left", clickCount: 1 });
            await sendRecorded("console-insert-text", "Input.insertText", { text: inspectedExpression });
            await sendRecorded("console-enter-down", "Input.dispatchKeyEvent", {
              type: "rawKeyDown", key: "Enter", code: "Enter",
              windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 36,
            });
            await sendRecorded("console-enter-up", "Input.dispatchKeyEvent", {
              type: "keyUp", key: "Enter", code: "Enter",
              windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 36,
            });
            let renderedResult;
            for (let attempt = 0; attempt < 100; attempt++) {
              const reply = await sendRecorded(`console-result-lookup-${attempt}`,
                "Runtime.evaluate", { expression: `(() => { ${deepQuerySource}
                  return deepQuery(document, '#console-messages')?.innerText || '';
                })()`, returnByValue: true });
              assert(!reply.exceptionDetails, "DevTools Console result lookup threw");
              if (reply.result?.value?.includes(inspectedValue)) {
                renderedResult = reply.result.value;
                break;
              }
              await delay(50);
            }
            assert(renderedResult?.includes(inspectedValue),
              "DevTools Console did not render the exact inspected-page result");
            const result = await sendRecorded("frontend-host-actions", "Runtime.evaluate", {
              expression: `(async () => {
                const Host = await import('./core/host/host.js');
                const inspectorHost = Host.InspectorFrontendHost.InspectorFrontendHostInstance;
                if (typeof inspectorHost?.setIsDocked !== 'function' ||
                    typeof inspectorHost?.openInNewTab !== 'function') {
                  throw new Error('Bundled InspectorFrontendHost actions unavailable');
                }
                const dockOutcome = await Promise.race([
                  new Promise(resolve => inspectorHost.setIsDocked(true,
                    () => resolve('callback'))),
                  new Promise(resolve => setTimeout(() => resolve('timeout'), 2000)),
                ]);
                inspectorHost.openInNewTab(${escapeURL});
                return {
                  ready: true, inspectedURL: ${JSON.stringify(marker.inspectedURL)},
                  value: ${JSON.stringify(inspectedValue)},
                  frontendURL: location.href, visibility: ${JSON.stringify(tab.visibility)},
                  focused: ${JSON.stringify(tab.focused)},
                  dockOutcome,
                };
              })()`, awaitPromise: true, returnByValue: true,
            }, 10_000);
            assert(!result.exceptionDetails, "DevTools frontend inspection threw");
            await delay(500);
            const escapeDenied = !(await fetchJSON(`${devTools.baseURL}/json/list`))
              .some(item => item.url === marker.escapeURL);
            trace.push({ phase: "frontend-actions-result", targetID: frontend.id, escapeDenied,
              renderedResult, ...result.result?.value });
            const finalFrontendResult = JSON.stringify({
              sequence, targetID: frontend.id, escapeDenied, renderedResult,
              ...result.result?.value, trace,
            });
            await Promise.all([writeFile(devToolsResultPath, finalFrontendResult),
              writeFile(sequenceResultPath, finalFrontendResult)]);
          } else {
            try { await frontendCDP.send("Page.crash", {}, 5_000); }
            catch { /* Frontend renderer death normally closes CDP first. */ }
            const crashResult = JSON.stringify({ sequence, crashed: true });
            await Promise.all([writeFile(devToolsResultPath, crashResult),
              writeFile(sequenceResultPath, crashResult)]);
          }
        } catch (error) {
          const failureResult = JSON.stringify({
            sequence, phase: "frontend-action-error", targetID: frontend.id,
            error: error instanceof Error ? error.message : String(error),
            stack: error instanceof Error ? error.stack : undefined,
            trace,
          });
          await Promise.all([writeFile(devToolsResultPath, failureResult),
            writeFile(sequenceResultPath, failureResult)]);
          throw error;
        } finally {
          frontendCDP.close();
        }
      }
      return true;
    })().then((passed) => ({ passed }), (error) => ({ passed: false, error }));
    const nativeValidation = await poll("native extension and website-data validation", options.timeoutMs,
      async () => {
        try { return JSON.parse(await readFile(validationReportPath, "utf8")); }
        catch { return false; }
      });
    assert(nativeValidation.status === "passed",
      `Native validation failed: ${nativeValidation.error ?? JSON.stringify(nativeValidation)}`);
    const clientCertificateRequests = fixture.requests.filter((request) =>
      request.path.startsWith(`/fixture/${fixture.token}/client-certificate/`));
    const clientCertificateStats = fixture.clientCertificate.stats;
    assert(fixture.clientCertificate.mainNames.every((name) =>
      clientCertificateStats[name].secureConnections + clientCertificateStats[name].tlsErrors > 0),
    `A client-certificate TLS challenge was not attempted: ${JSON.stringify(clientCertificateStats)}`);
    assert(clientCertificateRequests.length === 2 &&
      clientCertificateRequests.some((request) => request.path ===
        `/fixture/${fixture.token}/client-certificate/select`) &&
      clientCertificateRequests.some((request) => request.path ===
        `/fixture/${fixture.token}/client-certificate/document`),
    `Client-certificate server saw unexpected authenticated requests: ${JSON.stringify(clientCertificateRequests)}`);
    assert(clientCertificateStats.select.requests === 1 && clientCertificateStats.document.requests === 1 &&
      clientCertificateStats.select.peerSerials.length === 1 &&
      clientCertificateStats.select.peerSerials[0] === fixture.clientCertificate.serial.toUpperCase() &&
      clientCertificateStats.document.peerSerials[0] === fixture.clientCertificate.serial.toUpperCase() &&
      ["cancel", "unhandled", "stale", "close", "reentrant"].every((name) =>
        clientCertificateStats[name].requests === 0),
    `Client-certificate peer identity or negative-case isolation failed: ${JSON.stringify(clientCertificateStats)}`);
    const skippedChecks = options.skipDevToolsFrontendProbe ? [
      "devToolsFrontendReadyAndInspectsExactTarget", "devToolsDockingDenied",
      "devToolsNewTabEscapeDenied", "devToolsFrontendCrashClosesOnce",
      "devToolsReopensAfterFrontendCrash",
    ] : [];
    if (options.skipLocalFileValidation) skippedChecks.push(...LOCAL_FILE_CHECKS);
    if (options.skipRepostValidation) skippedChecks.push(...REPOST_CHECKS);
    if (skippedChecks.length) {
      nativeValidation.skippedChecks = skippedChecks;
      await writeFile(validationReportPath, JSON.stringify(nativeValidation));
    }
    const promptCrashResult = await promptCrash;
    assert(promptCrashResult.passed,
      `Prompt crash fixture failed: ${promptCrashResult.error?.message ?? "unknown error"}`);
    const beforeUnloadResult = await beforeUnloadActivation;
    assert(beforeUnloadResult.passed,
      `BeforeUnload activation fixture failed: ${beforeUnloadResult.error?.message ?? "unknown error"}`);
    const repostBeforeUnloadResult = await repostBeforeUnloadActivation;
    assert(repostBeforeUnloadResult.passed,
      `Repost beforeUnload activation fixture failed: ${repostBeforeUnloadResult.error?.message ?? "unknown error"}`);
    const fileChooserResult = await fileChooserActions;
    assert(fileChooserResult.passed,
      `File chooser activation fixture failed: ${fileChooserResult.error?.message ?? "unknown error"}`);
    const exclusiveAccessResult = await exclusiveAccessAction;
    assert(exclusiveAccessResult.passed,
      `Exclusive access fixture failed: ${exclusiveAccessResult.error?.message ?? "unknown error"}`);
    const postReloadResult = await postReloadAction;
    assert(postReloadResult.passed,
      `Renderer POST reload fixture failed: ${postReloadResult.error?.message ?? "unknown error"}`);
    const externalProtocolResult = await externalProtocolActions;
    assert(externalProtocolResult.passed,
      `External protocol activation fixture failed: ${externalProtocolResult.error?.message ?? "unknown error"}`);
    const devToolsResult = await devToolsActions;
    assert(devToolsResult.passed,
      `DevTools fixture failed: ${devToolsResult.error?.message ?? "unknown error"}`);
    for (const check of ["runtimeVersionAvailable", "emptyPrivateWindowKeyRejected",
      "documentReadyAndProgress", "navigationFailureMetadata", "navigationFailureClearsOnRecovery",
      "historyUsesStableEntryIdentity", "staleHistoryEntryRejected",
      "findCaseInsensitiveCountsAllMatches", "findCaseSensitiveCountsExactMatches",
      "findInitialTextAvailable", "findEmptyClearsResults",
      "rendererTerminationReasonAvailable", "nulProfileKeyRejected", "nulPrivateWindowKeyRejected",
      "nulExtensionIdentifierRejected", "closedPageActionRejected", "extensionListed",
      "tabOutputMuteReported", "tabOutputUnmuteReported",
      "withheldBeforeGrant", "undeclaredGrantRejected", "declaredGrantInjected",
      "revocationRemovedInjection", "websiteDataListed", "websiteDataRemoved",
      "navigationCallbackUsesSettledTitle",
      "sameDocumentNavigationCallbacksPreserveOrder",
      "httpConnectionReported", "secureConnectionReported", "mixedConnectionReported",
      "invalidTLSReported", "connectionRecoveredAfterError",
      "httpConnectionDetails", "secureConnectionDetails", "mixedConnectionDetails",
      "secureCertificateChain", "invalidTLSConnectionDetails",
      "devToolsUnknownHostRejected", "devToolsImmediateCloseAccepted",
      "devToolsFrontendAttached", "devToolsImmediateCloseRebindsNewHost",
      "devToolsDuplicateRejected", "devToolsFrontendReadyAndInspectsExactTarget",
      "devToolsDockingDenied", "devToolsNewTabEscapeDenied",
      "devToolsSurvivesTargetNavigationAndMove", "devToolsExplicitCloseAccepted",
      "devToolsExplicitCloseExactlyOnce", "devToolsCloseLeavesInspectedPageAlive",
      "devToolsFrontendCrashClosesOnce", "devToolsReopensAfterFrontendCrash",
      "devToolsHostWindowCloseExactlyOnce",
      "devToolsTargetCloseDuringOpenRejected", "devToolsTargetCrashClosesOnce",
      "devToolsPageCloseClosesOnce", "devToolsContextCloseClosesOnce",
      "devToolsProfileDeletableAfterClose",
      "devToolsCloseCallbackCanReleaseSession",
      "devToolsPrivateContextClosesWithoutRetention",
      "nativeSnapshotPNG", "nativeSnapshotResize", "nativeSnapshotNavigation",
      "nativeSnapshotTaskCancellationSafe", "closedSnapshotRejected",
      "closedPrintRejected",
      "closedConnectionDetailsRejected", "crashedConnectionDetailsUnavailable",
      "unhandledMediaDenied", "combinedMediaRequestMetadata", "mediaAllowExactlyOnce",
      "mediaCaptureStateReported", "mediaCaptureStopped",
      "mediaPromptMoveRejected", "mediaMoveAfterResolution",
      "mediaPromptDevToolsRejected",
      "navigatedMediaRequestCancelled", "closedMediaRequestCancelled",
      "reentrantMediaCloseCancelledOnce",
      "unhandledJavaScriptDialogDenied", "javaScriptPromptMetadata",
      "javaScriptPromptExactlyOnce", "javaScriptDialogNavigationCancelledOnce",
      "javaScriptPromptMoveRejected", "javaScriptMoveAfterResolution",
      "javaScriptPromptDevToolsRejected",
      "crossOriginBeforeUnloadMetadata", "crossOriginBeforeUnloadAccepted",
      "freshPageHTTPAuthMetadata", "freshPageHTTPAuthSubmit",
      "httpAuthPromptMoveRejected", "httpAuthMoveAfterResolution",
      "httpAuthPromptDevToolsRejected",
      "httpAuthMetadata", "httpAuthSubmitExactlyOnce",
      "subresourceHTTPAuthMetadata", "subresourceHTTPAuthSubmit",
      "httpAuthNavigationCancelledOnce", "fileChooserMetadata",
      "fileChooserSelectExactlyOnce", "removedFrameFileChooserCancelledOnce",
      "rendererCrashFileChooserCancelledOnce",
      "fileChooserPromptMoveRejected", "fileChooserMoveAfterResolution",
      "fileChooserPromptDevToolsRejected",
      "folderUploadEnumeratesNestedRelativePaths",
      "fullscreenDenied", "pointerLockDenied", "keyboardLockDeniedWithoutKeyCapture",
      "deviceAndPaymentRequestsSettleDenied", "exclusivePageVisible",
      "pictureInPictureDeniedNoWindow", "documentPictureInPictureDeniedNoWindow",
      "displayMediaDeniedNoPicker",
      "unhandledExternalProtocolDenied", "externalProtocolMetadata",
      "externalProtocolAllowExactlyOnce", "externalProtocolDenyExactlyOnce",
      "externalProtocolNavigationCancelledOnce", "iframeExternalProtocolNotPublished",
      "gesturelessExternalProtocolNotPublished", "externalProtocolCloseCancelledOnce",
      "externalProtocolPromptMoveRejected", "externalProtocolMoveAfterResolution",
      "externalProtocolPromptDevToolsRejected",
      "getReloadAccepted", "initialPOSTBodyDelivered", "postReloadDefaultDenied",
      "postReloadPreservedBodyAndHitCount", "rendererPOSTReloadDenied",
      ...REPOST_CHECKS,
      ...LOCAL_FILE_CHECKS,
      "currentDOMIncludesLiveMutation", "nativeMHTMLArchive",
      "sameDocumentNavigationPreservesDOMRequest", "navigationCancelsStaleArchive",
      "closeCancelsOutstandingDOM",
      "nativeRulesBlockScriptAndImage", "nativeRulesDisableAllowsRequests",
      "nativeRulesReenableBlocksRequests", "nativeRulesExactOriginExceptionAllowsRequests",
      "hostWindowGroupingMatchesExtensions", "groupSurvivesSiblingClose",
      "nativeTabActivationReported", "hostWindowMoveMatchesExtensions",
      "hostWindowMoveRoundTripPreservesPageState",
      "privateIsolatedFromNormal", "privateWindowsIsolated",
      "privateKeyReopensEmpty", "normalProfilesIsolated",
      "normalSurvivesPrivateClosure",
      "contextSurvivesLastPageClosed", "profileReopenedAfterContextClosed",
      "activeProfileDeletionRejected", "profilePhysicallyAbsentAtCallback",
      "absentProfileDeletionIsIdempotent",
      "interruptedDownloadReleaseRejectsStaleResume",
      "interruptedDownloadReleaseUnblocksProfileDeletion",
      "profileFilesystemFailureReported",
      "profileFilesystemFailureRetryCompleted"]) {
      if (!skippedChecks.includes(check)) {
        assert(nativeValidation.checks?.[check] === true,
          `Native validation omitted or failed ${check}`);
      }
    }
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await waitForDocument(cdp,
      `location.href === ${JSON.stringify(fixture.pageA)} &&
       document.documentElement.dataset.run === ${JSON.stringify(fixture.token)} &&
       document.querySelector("#heading")?.textContent === "Native Chromium fixture"`,
    "initial fixture DOM", options.timeoutMs);
    const launchToSmokeReadyMs = Date.now() - launchStartedAtMs;
    const faviconMetadata = await poll("native favicon metadata", options.timeoutMs, async () => {
      try {
        const value = JSON.parse(await readFile(metadataReportPath, "utf8"));
        return value.url === fixture.pageA && value.faviconPNG === true &&
          value.faviconBytes > 0 && value.faviconBytes <= 1_000_000 && value;
      } catch { return false; }
    });
    const hoverPoint = await evaluate(cdp, `(() => {
      const bounds = document.querySelector("#hover-target").getBoundingClientRect();
      return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
    })()`);
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseMoved", x: hoverPoint.x, y: hoverPoint.y, button: "none",
    });
    const hoveredMetadata = await poll("native hovered-link metadata", options.timeoutMs, async () => {
      try {
        const value = JSON.parse(await readFile(metadataReportPath, "utf8"));
        return value.url === fixture.pageA && value.hoveredLink === fixture.hoverTarget && value;
      } catch { return false; }
    });

    // Exercise both upstream attachment paths. A CDP target alone is not proof
    // that the embedding client received and presented the popup.
    const popupChecks = [];
    for (const features of ["popup,width=600,height=400", "popup,width=600,height=400,noopener"]) {
      const popupURL = `${fixture.pageA}?popup=${randomUUID()}`;
      const opened = await cdp.send("Runtime.evaluate", {
        expression: `window.open(${JSON.stringify(popupURL)}, "_blank", ${JSON.stringify(features)}); true`,
        userGesture: true, returnByValue: true,
      });
      assert(!opened.exceptionDetails, "Popup request threw a JavaScript exception");
      const expectedEvents = popupChecks.length * 2 + 1;
      const events = await poll("native popup adoption", options.timeoutMs, async () => {
        const records = JSON.parse(await readFile(popupReportPath, "utf8"));
        return records.length >= expectedEvents && records;
      });
      const adoption = events[expectedEvents - 1];
      assert(events.length === expectedEvents && adoption.event === "opened" &&
        adoption.nativeViewAttached === true && adoption.separateNativeWindow === true &&
        adoption.visible === true && adoption.hostID !== adoption.openerHostID &&
        adoption.policyBeforeCreation === true,
      `Popup was not attached to its own native window: ${JSON.stringify(adoption)}`);
      const popupTarget = await poll("adopted popup document", options.timeoutMs, async () => {
        const targets = await fetchJSON(`${devTools.baseURL}/json/list`);
        return targets.find(item => item.type === "page" && item.url === popupURL && item.webSocketDebuggerUrl);
      });
      const popupCDP = new CDPConnection(loopbackWebSocket(popupTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await popupCDP.connect(options.timeoutMs);
        await waitForDocument(popupCDP,
          `location.href === ${JSON.stringify(popupURL)} && document.documentElement.dataset.run === ${JSON.stringify(fixture.token)}`,
          "adopted popup rendering", options.timeoutMs);
        const hasOpener = await evaluate(popupCDP, "window.opener !== null");
        assert(hasOpener === !features.includes("noopener"), "Popup opener relationship changed during adoption");
        try { await popupCDP.send("Runtime.evaluate", { expression: "window.close()" }, 2_000); }
        catch { /* Closing the page may close CDP before it can reply. */ }
        const closed = await poll("native popup teardown", options.timeoutMs, async () => {
          const records = JSON.parse(await readFile(popupReportPath, "utf8"));
          return records.length > expectedEvents && records;
        });
        const retirement = closed[expectedEvents];
        assert(closed.length === expectedEvents + 1 && retirement.event === "closed" &&
          retirement.hostID === adoption.hostID && retirement.pageClosed === true,
        "Popup native window closed without retiring its Chromium page");
        await poll("popup target removal", options.timeoutMs, async () =>
          !(await fetchJSON(`${devTools.baseURL}/json/list`)).some(item => item.id === popupTarget.id));
        popupChecks.push({ features, hasOpener, nativeViewAttached: true, nativeWindowClosed: true });
      } finally {
        popupCDP.close();
      }
    }

    const popupGestureChecks = [];
    for (const gesture of [
      {name: "commandClick", button: "left", modifiers: 4, disposition: 4},
      {name: "commandShiftClick", button: "left", modifiers: 12, disposition: 3},
      {name: "middleClick", button: "middle", modifiers: 0, disposition: 4},
      {name: "shiftMiddleClick", button: "middle", modifiers: 8, disposition: 3},
      {name: "commandClickTargetBlank", button: "left", modifiers: 4, disposition: 4, target: "_blank"},
    ]) {
      const popupURL = `${fixture.pageA}?gesture=${gesture.name}`;
      const eventCount = JSON.parse(await readFile(popupReportPath, "utf8")).length;
      const point = await evaluate(cdp, `(() => {
        document.querySelector('#disposition-link')?.remove();
        const link = document.createElement('a'); link.id = 'disposition-link';
        link.href = ${JSON.stringify(popupURL)}; link.target = ${JSON.stringify(gesture.target ?? "")};
        link.textContent = 'Open disposition fixture';
        link.style = 'position:fixed;top:10px;left:10px;z-index:99999;background:white;padding:10px';
        document.body.append(link);
        const rect = link.getBoundingClientRect();
        return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
      })()`);
      await cdp.send("Page.bringToFront");
      for (const type of ["mousePressed", "mouseReleased"]) {
        await cdp.send("Input.dispatchMouseEvent", {
          type, ...point, button: gesture.button, modifiers: gesture.modifiers, clickCount: 1,
        });
      }
      const adoption = await poll(`${gesture.name} native callback`, options.timeoutMs, async () => {
        const records = JSON.parse(await readFile(popupReportPath, "utf8"));
        return records.length === eventCount + 1 && records.at(-1);
      });
      assert(adoption.event === "opened" && adoption.disposition === gesture.disposition,
        `${gesture.name} lost opening intent: ${JSON.stringify(adoption)}`);
      assert(await evaluate(cdp, "location.href") === fixture.pageA,
        `${gesture.name} navigated the opener`);
      const popupTarget = await poll(`${gesture.name} child load`, options.timeoutMs, async () =>
        (await fetchJSON(`${devTools.baseURL}/json/list`)).find(item => item.url === popupURL));
      const popupCDP = new CDPConnection(loopbackWebSocket(popupTarget.webSocketDebuggerUrl, devTools.port));
      try {
        await popupCDP.connect(options.timeoutMs);
        try { await popupCDP.send("Page.close", {}, 2_000); } catch { /* Target may close before replying. */ }
        await poll(`${gesture.name} child close`, options.timeoutMs, async () => {
          const records = JSON.parse(await readFile(popupReportPath, "utf8"));
          return records.length === eventCount + 2 && records.at(-1)?.event === "closed";
        });
      } finally { popupCDP.close(); }
      popupGestureChecks.push({name: gesture.name, disposition: adoption.disposition});
    }

    const blockedPopupURL = `${fixture.pageA}?popupPolicy=block`;
    const popupEventsBeforeBlock = JSON.parse(await readFile(popupReportPath, "utf8")).length;
    await cdp.send("Runtime.evaluate", {
      expression: `window.open(${JSON.stringify(blockedPopupURL)}, "_blank", "popup,width=600,height=400"); true`,
      userGesture: true, returnByValue: true,
    });
    const blockedPopup = await poll("native popup policy rejection", options.timeoutMs, async () => {
      const records = JSON.parse(await readFile(popupReportPath, "utf8"));
      return records.length === popupEventsBeforeBlock + 1 && records.at(-1)?.event === "blocked" && records.at(-1);
    });
    assert(blockedPopup.targetURL === blockedPopupURL && blockedPopup.userGesture === true,
      `Popup policy lost request metadata: ${JSON.stringify(blockedPopup)}`);
    await delay(250);
    assert(!(await fetchJSON(`${devTools.baseURL}/json/list`)).some(item => item.url === blockedPopupURL),
      "Rejected popup created a page target");

    const permission = await evaluate(cdp, `new Promise((resolve) => {
      if (!navigator.geolocation) {
        resolve({ status: "missing" });
        return;
      }
      navigator.geolocation.getCurrentPosition(
        () => resolve({ status: "granted", secureContext: isSecureContext }),
        (error) => resolve({ status: "denied", code: error.code,
          secureContext: isSecureContext }),
        { maximumAge: 0, timeout: 2_000 });
    })`);
    assert(permission?.status === "denied" && permission.code === 1 &&
      permission.secureContext === true,
    `SDK permission fixture was not denied: ${JSON.stringify(permission)}`);

    const formValue = `Cobble state ${randomUUID()}`;
    const submittedValue = await evaluate(cdp, `(() => {
      const input = document.querySelector("#query");
      input.focus();
      input.value = ${JSON.stringify(formValue)};
      input.dispatchEvent(new Event("input", { bubbles: true }));
      document.querySelector("#fixture-form").requestSubmit();
      return input.value;
    })()`);
    assert(submittedValue === formValue, "Chromium did not retain the synthetic form value before submit");
    await waitForDocument(cdp,
      `location.pathname === ${JSON.stringify(fixture.resultPath)} &&
       new URLSearchParams(location.search).get("q") === ${JSON.stringify(formValue)} &&
       document.querySelector("#result")?.textContent === ${JSON.stringify(formValue)}`,
    "form navigation and rendered result", options.timeoutMs);

    let history = await cdp.send("Page.getNavigationHistory");
    const pageAIndex = history.entries.findIndex((entry) => entry.url === fixture.pageA);
    const resultIndex = history.entries.findIndex((entry) => {
      const url = new URL(entry.url);
      return url.origin === fixture.origin && url.pathname === fixture.resultPath &&
        url.searchParams.get("q") === formValue;
    });
    assert(pageAIndex >= 0 && resultIndex >= 0 && history.currentIndex === resultIndex,
      "Chromium navigation history is missing the form transition");
    const pageAEntry = history.entries[pageAIndex];
    const resultEntry = history.entries[resultIndex];
    await cdp.send("Page.navigateToHistoryEntry", { entryId: pageAEntry.id });
    await waitForDocument(cdp,
      `location.href === ${JSON.stringify(fixture.pageA)} &&
       document.querySelector("#query")?.value === ${JSON.stringify(formValue)}`,
    "history back with restored form state", options.timeoutMs);
    await cdp.send("Page.navigateToHistoryEntry", { entryId: resultEntry.id });
    await waitForDocument(cdp,
      `location.pathname === ${JSON.stringify(fixture.resultPath)} &&
       document.querySelector("#result")?.textContent === ${JSON.stringify(formValue)}`,
    "history forward", options.timeoutMs);

    const navigation = await cdp.send("Page.navigate", { url: fixture.pageB });
    assert(!navigation.errorText, `Page.navigate failed: ${navigation.errorText}`);
    await waitForDocument(cdp,
      `location.href === ${JSON.stringify(fixture.pageB)} &&
       document.documentElement.dataset.run === ${JSON.stringify(fixture.token)}`,
    "second fixture navigation", options.timeoutMs);
    const clearedMetadata = await poll("cross-navigation metadata clearing", options.timeoutMs, async () => {
      try {
        const value = JSON.parse(await readFile(metadataReportPath, "utf8"));
        return value.url === fixture.pageB && value.faviconBytes === 0 &&
          value.hoveredLink === null && value;
      } catch { return false; }
    });
    const render = await evaluate(cdp, `(() => {
      const card = document.querySelector("#render-card");
      const bounds = card.getBoundingClientRect();
      return { text: card.textContent, color: getComputedStyle(card).color,
        width: bounds.width, height: bounds.height };
    })()`);
    assert(render.text === `Chromium rendered ${fixture.token}`,
      "Rendered fixture text is incorrect");
    assert(render.color === "rgb(24, 48, 72)" && render.width >= 350 && render.height >= 90,
      "Chromium layout or computed style result is incorrect");

    const graphics = await poll("WebGL2 fixture output", options.timeoutMs, async () => {
      const state = await evaluate(cdp, `({ graphics: window.cobbleGraphics,
        status: document.querySelector("#graphics-status")?.dataset.state })`);
      if (state.graphics?.status === "error") {
        failFatal(`WebGL2 fixture error: ${state.graphics.error ?? "no error detail"}`);
      }
      return state.graphics?.status === "passed" && state.status === "passed" ? state.graphics : false;
    });
    assert(Array.isArray(graphics?.webgl2?.pixel) &&
      graphics.webgl2.pixel.join(",") === "32,128,191,255",
    "WebGL2 readPixels did not produce the fixture color");
    assert(typeof graphics.webgl2.renderer === "string" && graphics.webgl2.renderer.length > 0 &&
      ["WEBGL_debug_renderer_info", "GL_RENDERER"].includes(graphics.webgl2.rendererSource),
    "WebGL2 renderer capability report is incomplete");
    assert(["passed", "unavailable"].includes(graphics.offscreenCanvasWorker?.status),
      "OffscreenCanvas worker capability report is invalid");
    const canvasBounds = await evaluate(cdp, `(() => {
      const bounds = document.querySelector("#graphics-canvas").getBoundingClientRect();
      return { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height };
    })()`);
    assert([canvasBounds.x, canvasBounds.y, canvasBounds.width, canvasBounds.height]
      .every(Number.isFinite) && canvasBounds.width >= 96 && canvasBounds.height >= 96,
    "WebGL2 canvas is not visible in the fixture viewport");
    const canvasScreenshot = await cdp.send("Page.captureScreenshot", {
      format: "png", fromSurface: true, captureBeyondViewport: false,
      clip: { ...canvasBounds, scale: 1 },
    }, options.timeoutMs);
    const canvasImage = Buffer.from(canvasScreenshot.data, "base64");
    assert(canvasImage.length > 100 && canvasImage.subarray(0, 8).equals(
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
    "CDP WebGL2 canvas capture is not a PNG");
    const canvasScreenshotPath = join(options.artifactsPath, "chromium-webgl2-canvas.png");
    await writeFile(canvasScreenshotPath, canvasImage);

    const clickDownload = async (url, filename) => {
      await cdp.send("Page.bringToFront");
      const center = await evaluate(cdp, `(() => {
      const link = document.createElement("a");
      link.href = ${JSON.stringify(url)};
      link.download = ${JSON.stringify(filename)};
      link.id = "cobble-smoke-download";
      link.textContent = "Download";
      link.style = "display:block;position:fixed;left:8px;top:8px;width:120px;height:40px;z-index:2147483647";
      window.cobbleSmokeDownloadClick = null;
      link.addEventListener("click", event => { window.cobbleSmokeDownloadClick = { trusted: event.isTrusted }; });
      document.body.append(link);
      const bounds = link.getBoundingClientRect();
      return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2, width: innerWidth, height: innerHeight };
    })()`);
      assert(center.x < center.width && center.y < center.height,
        `Download link lies outside the native viewport: ${JSON.stringify(center)}`);
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mouseMoved", x: center.x, y: center.y, button: "none",
      }, options.timeoutMs);
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mousePressed", x: center.x, y: center.y, button: "left", clickCount: 1,
      }, options.timeoutMs);
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mouseReleased", x: center.x, y: center.y, button: "left", clickCount: 1,
      }, options.timeoutMs);
      const click = await evaluate(cdp, `({ click: window.cobbleSmokeDownloadClick, visibility: document.visibilityState, focused: document.hasFocus() })`);
      assert(click.click?.trusted, `Download click was not delivered: ${JSON.stringify(click)}`);
      await evaluate(cdp, `document.querySelector("#cobble-smoke-download")?.remove()`);
    };
    await clickDownload(fixture.networkDownloadURL, fixture.networkDownloadName);
    const networkDownloadPath = join(downloadPath, fixture.networkDownloadName);
    await poll("network download completion", options.timeoutMs, async () => {
      try {
        const contents = await readFile(networkDownloadPath);
        return contents.equals(fixture.networkDownload);
      } catch { return false; }
    });
    await access(join(downloadPath, `.progress-${fixture.networkDownloadName}`));
    await access(join(downloadPath, `.nested-terminal-cancel-${fixture.networkDownloadName}`));

    const blobURL = await evaluate(cdp, `(() => {
      const blob = new Blob([${JSON.stringify(fixture.blobDownload)}], { type: "text/plain" });
      return URL.createObjectURL(blob);
    })()`);
    await clickDownload(blobURL, fixture.blobDownloadName);
    const blobDownloadPath = join(downloadPath, fixture.blobDownloadName);
    await poll("blob download completion", options.timeoutMs, async () => {
      try { return await readFile(blobDownloadPath, "utf8") === fixture.blobDownload; }
      catch { return false; }
    });
    await evaluate(cdp, `URL.revokeObjectURL(${JSON.stringify(blobURL)})`);

    await clickDownload(fixture.cancelledDownloadURL, fixture.cancelledDownloadName);
    await poll("download cancellation callback", options.timeoutMs, async () => {
      try {
        await access(join(downloadPath, `.cancelled-${fixture.cancelledDownloadName}`));
        return true;
      } catch { return false; }
    });
    let cancelledFileExists = true;
    try { await access(join(downloadPath, fixture.cancelledDownloadName)); }
    catch { cancelledFileExists = false; }
    assert(!cancelledFileExists, "Cancelled download published a destination file");

    await clickDownload(fixture.pausedDownloadURL, fixture.pausedDownloadName);
    for (const state of ["paused", "resumed"]) {
      await poll(`download ${state} state`, options.timeoutMs, async () => {
        try { await access(join(downloadPath, `.${state}-${fixture.pausedDownloadName}`)); return true; }
        catch { return false; }
      });
    }
    const pausedDownloadPath = join(downloadPath, fixture.pausedDownloadName);
    await poll("resumed download completion", options.timeoutMs, async () => {
      try { return (await readFile(pausedDownloadPath)).equals(fixture.pausedDownload); }
      catch { return false; }
    });
    await poll("released download controls rejection", options.timeoutMs, async () => {
      try {
        await access(join(downloadPath, `.released-controls-rejected-${fixture.pausedDownloadName}`));
        return true;
      } catch { return false; }
    });

    await clickDownload(fixture.pausedCancelledDownloadURL, fixture.pausedCancelledDownloadName);
    await poll("paused download cancellation", options.timeoutMs, async () => {
      try {
        await Promise.all(["paused", "cancelled", "released-controls-rejected"].map(state =>
          access(join(downloadPath, `.${state}-${fixture.pausedCancelledDownloadName}`))));
        return true;
      } catch { return false; }
    });
    let pausedCancelledExists = true;
    try { await access(join(downloadPath, fixture.pausedCancelledDownloadName)); }
    catch { pausedCancelledExists = false; }
    assert(!pausedCancelledExists, "Cancelled paused download published a destination file");

    await clickDownload(fixture.unknownTotalDownloadURL, fixture.unknownTotalDownloadName);
    const unknownTotalPath = join(downloadPath, fixture.unknownTotalDownloadName);
    await poll("unknown-total download completion", options.timeoutMs, async () => {
      try { return (await readFile(unknownTotalPath)).equals(fixture.unknownTotalDownload); }
      catch { return false; }
    });
    const unknownProgress = await readFile(
      join(downloadPath, `.progress-${fixture.unknownTotalDownloadName}`), "utf8");
    assert(unknownProgress === `${fixture.unknownTotalDownload.length}/0`,
      `Chunked download did not report an unknown total: ${unknownProgress}`);

    await clickDownload(fixture.interruptedDownloadURL, fixture.interruptedDownloadName);
    const interruptedDownloadPath = join(downloadPath, fixture.interruptedDownloadName);
    await poll("interrupted GET resume completion", options.timeoutMs, async () => {
      try { return (await readFile(interruptedDownloadPath)).equals(fixture.interruptedDownload); }
      catch { return false; }
    });
    const completedMetadata = JSON.parse(await readFile(join(downloadPath,
      `.metadata-complete-${fixture.interruptedDownloadName}.json`), "utf8"));
    // Chromium may refine the generic response type using macOS's .bin mapping.
    const binaryMimeTypes = ["application/octet-stream", "application/macbinary"];
    assert(completedMetadata.originalURL === fixture.interruptedDownloadURL &&
      completedMetadata.currentURL === fixture.interruptedDownloadURL &&
      binaryMimeTypes.includes(completedMetadata.mimeType) &&
      completedMetadata.receivedBytes === fixture.interruptedDownload.length &&
      completedMetadata.totalBytes === fixture.interruptedDownload.length &&
      completedMetadata.interruptionReason === null,
    `Completed download metadata was incorrect: ${JSON.stringify(completedMetadata)}; expected URL=${fixture.interruptedDownloadURL}, bytes=${fixture.interruptedDownload.length}`);
    for (const episode of [1, 2]) {
      const metadata = JSON.parse(await readFile(join(downloadPath,
        `.metadata-interruption-${episode}-${fixture.interruptedDownloadName}.json`), "utf8"));
      assert(metadata.originalURL === fixture.interruptedDownloadURL &&
        metadata.currentURL === fixture.interruptedDownloadURL &&
        binaryMimeTypes.includes(metadata.mimeType) &&
        Number.isInteger(metadata.interruptionReason) && metadata.interruptionReason > 0,
      `Missing interrupted download metadata for episode ${episode}`);
      await access(join(downloadPath, `.interrupted-${episode}-${fixture.interruptedDownloadName}`));
      await access(join(downloadPath, `.retry-${episode}-${fixture.interruptedDownloadName}`));
    }
    const interruptedGETs = fixture.requests.filter(request =>
      request.method === "GET" && request.path ===
        new URL(fixture.interruptedDownloadURL).pathname);
    assert(interruptedGETs.length >= 3 && interruptedGETs.slice(1).every(request =>
      request.range === "" || /^bytes=\d+-$/.test(request.range)),
    `Interrupted GET retry shape was unsafe: ${JSON.stringify(interruptedGETs)}`);

    await clickDownload(fixture.interruptedCancelDownloadURL,
      fixture.interruptedCancelDownloadName);
    await poll("interrupted GET cancellation", options.timeoutMs, async () => {
      try {
        await access(join(downloadPath,
          `.interrupted-1-${fixture.interruptedCancelDownloadName}`));
        await access(join(downloadPath, `.cancelled-${fixture.interruptedCancelDownloadName}`));
        return true;
      } catch { return false; }
    });
    let interruptedCancelledExists = true;
    try { await access(join(downloadPath, fixture.interruptedCancelDownloadName)); }
    catch { interruptedCancelledExists = false; }
    assert(!interruptedCancelledExists, "Cancelled interrupted GET published a destination file");

    const postCenter = await evaluate(cdp, `(() => {
      const form = document.createElement('form');
      form.method = 'POST'; form.action = ${JSON.stringify(fixture.interruptedPOSTDownloadURL)};
      const button = document.createElement('button');
      button.textContent = 'POST download';
      button.style = 'display:block;position:fixed;left:8px;top:8px;width:140px;height:40px;z-index:2147483647';
      form.append(button); document.body.append(form);
      const bounds = button.getBoundingClientRect();
      return {x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2};
    })()`);
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mousePressed", x: postCenter.x, y: postCenter.y, button: "left", clickCount: 1,
    });
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseReleased", x: postCenter.x, y: postCenter.y, button: "left", clickCount: 1,
    });
    await poll("interrupted POST terminal failure", options.timeoutMs, async () => {
      try {
        await access(join(downloadPath, `.failed-${fixture.interruptedPOSTDownloadName}`));
        return true;
      } catch { return false; }
    });
    const interruptedPOSTs = fixture.requests.filter(request =>
      request.path === new URL(fixture.interruptedPOSTDownloadURL).pathname);
    assert(interruptedPOSTs.length === 1 && interruptedPOSTs[0].method === "POST",
      `Interrupted POST was replayed: ${JSON.stringify(interruptedPOSTs)}`);

    await clickDownload(fixture.existingDestinationDownloadURL,
      fixture.existingDestinationDownloadName);
    await poll("existing destination rejection", options.timeoutMs, async () => {
      try {
        await access(join(downloadPath, `.rejected-${fixture.existingDestinationDownloadName}`));
        return true;
      } catch { return false; }
    });
    await clickDownload(fixture.danglingDestinationDownloadURL,
      fixture.danglingDestinationDownloadName);
    await poll("dangling destination rejection", options.timeoutMs, async () => {
      try {
        await access(join(downloadPath, `.rejected-${fixture.danglingDestinationDownloadName}`));
        return true;
      } catch { return false; }
    });

    history = await cdp.send("Page.getNavigationHistory");
    assert(history.entries[history.currentIndex]?.url === fixture.pageB,
      "Chromium history did not commit the second page");
    const processObservation = await observeIdleProcessTree(child.pid);
    const physicalFootprint = await observePhysicalFootprint(child.pid, options.artifactsPath);
    const screenshot = await cdp.send("Page.captureScreenshot", {
      format: "png", fromSurface: true, captureBeyondViewport: false,
    }, options.timeoutMs);
    const image = Buffer.from(screenshot.data, "base64");
    assert(image.length > 1_000 && image.subarray(0, 8).equals(
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
    "CDP screenshot is not a rendered PNG");
    const screenshotPath = join(options.artifactsPath, "chromium-fixture.png");
    await writeFile(screenshotPath, image);

    assert(fixture.requests.some((request) => request.path.startsWith(`/fixture/${fixture.token}/`)),
      "The loopback fixture server received no page requests");

    // Wait for Chromium to flush and close its stores before evaluating the
    // history policy. Forced cleanup cannot count as successful shutdown.
    try { await cdp.send("Browser.close", {}, 2_000); } catch { /* the socket may close before replying */ }
    cdp.close();
    cdp = undefined;
    await poll("orderly harness shutdown", options.timeoutMs,
      async () => child.exitCode !== null || child.signalCode !== null);
    assert(child.exitCode === 0 && child.signalCode === null,
      `Harness did not exit cleanly (${child.signalCode ?? `code ${child.exitCode}`})`);
    const emptyClientCertificateValidations = {};
    const restrictedStoreValues = {
      missing: join(fixture.certificateDirectory, "missing.keychain-db"),
      relative: "relative.keychain-db",
      directory: fixture.certificateDirectory,
    };
    for (const caseName of fixture.clientCertificate.emptyNames) {
      const emptyProfilePath = await import("node:fs/promises").then(({ mkdtemp }) =>
        mkdtemp(join(tmpdir(), `cobble-client-certificate-${caseName}-`)));
      const emptyReportPath = join(options.artifactsPath,
        `client-certificate-empty-${caseName}.json`);
      const emptyStdout = openSync(join(options.artifactsPath,
        `client-certificate-empty-${caseName}.stdout.log`), "wx");
      const emptyStderr = openSync(join(options.artifactsPath,
        `client-certificate-empty-${caseName}.stderr.log`), "wx");
      const emptyChild = spawn(harness.binaryPath, [
        `--user-data-dir=${emptyProfilePath}`, "--no-first-run", "--noerrdialogs",
        "--no-default-browser-check", "--use-mock-keychain", "--disable-background-networking",
        "--disable-sync", "--no-pings", `--ignore-certificate-errors-spki-list=${fixture.spkiAllowlist}`,
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
        `--cobble-client-cert-test-keychain=${restrictedStoreValues[caseName]}`,
      ], {
        detached: true,
        env: {
          ...process.env,
          COBBLE_CHROMIUM_HARNESS_URL: fixture.pageA,
          COBBLE_CHROMIUM_CLIENT_CERT_EMPTY_REPORT: emptyReportPath,
          COBBLE_CHROMIUM_CLIENT_CERT_EMPTY_CASE: caseName,
          COBBLE_CHROMIUM_CLIENT_CERT_EMPTY_URL: fixture.clientCertificate[caseName],
        },
        stdio: ["ignore", emptyStdout, emptyStderr],
      });
      closeSync(emptyStdout); closeSync(emptyStderr);
      clientCertificateEmptyChildren.push({ child: emptyChild, profilePath: emptyProfilePath });
      const validation = await poll(`restricted ${caseName} client-certificate store`,
        options.timeoutMs, async () => {
          try { return JSON.parse(await readFile(emptyReportPath, "utf8")); }
          catch { return false; }
        });
      const checkName = `${caseName}ClientCertificateStoreYieldsNoChoices`;
      assert(validation.status === "passed" && validation.checks?.[checkName] === true,
        `Restricted ${caseName} client-certificate store failed: ${JSON.stringify(validation)}`);
      await poll(`restricted ${caseName} client-certificate harness shutdown`, options.timeoutMs,
        async () => emptyChild.exitCode !== null || emptyChild.signalCode !== null);
      assert(emptyChild.exitCode === 0 && emptyChild.signalCode === null,
        `Restricted ${caseName} client-certificate harness did not exit cleanly`);
      assert(clientCertificateStats[caseName].secureConnections +
        clientCertificateStats[caseName].tlsErrors > 0 &&
        clientCertificateStats[caseName].requests === 0,
      `Restricted ${caseName} store did not attempt and deny the TLS challenge: ${JSON.stringify(clientCertificateStats[caseName])}`);
      emptyClientCertificateValidations[caseName] = validation;
      await rm(emptyProfilePath, { recursive: true, force: true });
    }
    const restartReportPath = join(options.artifactsPath, "profile-restart-validation.json");
    const restartStdout = openSync(join(options.artifactsPath, "profile-restart.stdout.log"), "wx");
    const restartStderr = openSync(join(options.artifactsPath, "profile-restart.stderr.log"), "wx");
    restartChild = spawn(harness.binaryPath, [
      `--user-data-dir=${profilePath}`,
      "--no-first-run", "--noerrdialogs", "--no-default-browser-check",
      "--use-mock-keychain", "--disable-background-networking", "--disable-sync", "--no-pings",
    ], {
      detached: true,
      env: {
        ...process.env,
        COBBLE_CHROMIUM_HARNESS_URL: fixture.pageA,
        COBBLE_CHROMIUM_PROFILE_RESTART_REPORT: restartReportPath,
        COBBLE_CHROMIUM_VALIDATION_USER_DATA_DIR: profilePath,
      },
      stdio: ["ignore", restartStdout, restartStderr],
    });
    closeSync(restartStdout);
    closeSync(restartStderr);
    const profileRestartValidation = await poll(
      "profile deletion restart validation", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(restartReportPath, "utf8")); }
        catch { return false; }
      });
    assert(profileRestartValidation.status === "passed" &&
      Object.values(profileRestartValidation.checks ?? {}).every(Boolean),
    `Profile deletion restart validation failed: ${JSON.stringify(profileRestartValidation)}`);
    await poll("profile restart harness shutdown", options.timeoutMs,
      async () => restartChild.exitCode !== null || restartChild.signalCode !== null);
    assert(restartChild.exitCode === 0 && restartChild.signalCode === null,
      `Profile restart harness did not exit cleanly (${restartChild.signalCode ??
        `code ${restartChild.exitCode}`})`);
    let externalShutdownValidation = { status: "skipped", checks: {} };
    if (!options.skipExternalShutdown) {
    shutdownProfilePath = await import("node:fs/promises").then(({ mkdtemp }) =>
      mkdtemp(join(tmpdir(), "cobble-chromium-shutdown-")));
    const shutdownReportPath = join(options.artifactsPath, "external-shutdown-validation.json");
    const shutdownMarkerPath = join(options.artifactsPath, "external-shutdown-action.json");
    const shutdownActivatedPath = join(options.artifactsPath, "external-shutdown-activated");
    const shutdownStdout = openSync(join(options.artifactsPath, "external-shutdown.stdout.log"), "wx");
    const shutdownStderr = openSync(join(options.artifactsPath, "external-shutdown.stderr.log"), "wx");
    shutdownChild = spawn(harness.binaryPath, [
      "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
      "--cobble-shutdown-diagnostics",
      `--user-data-dir=${shutdownProfilePath}`, "--no-first-run", "--noerrdialogs",
      "--no-default-browser-check", "--use-mock-keychain", "--disable-background-networking",
      "--disable-sync", "--no-pings", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
    ], {
      detached: true,
      env: {
        ...process.env,
        COBBLE_CHROMIUM_HARNESS_URL: fixture.pageA,
        COBBLE_CHROMIUM_EXTERNAL_SHUTDOWN_REPORT: shutdownReportPath,
        COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_MARKER: shutdownMarkerPath,
        COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_ACTIVATED: shutdownActivatedPath,
      },
      stdio: ["ignore", shutdownStdout, shutdownStderr],
    });
    closeSync(shutdownStdout); closeSync(shutdownStderr);
    const shutdownDevTools = await waitForDevTools(shutdownProfilePath, shutdownChild, options.timeoutMs);
    const shutdownMarker = await poll("shutdown external protocol marker", options.timeoutMs,
      async () => { try { return JSON.parse(await readFile(shutdownMarkerPath, "utf8")); }
        catch { return false; } });
    const shutdownTarget = await poll("shutdown external protocol target", options.timeoutMs,
      async () => (await fetchJSON(`${shutdownDevTools.baseURL}/json/list`)).find((item) =>
        item.type === "page" && item.url === shutdownMarker.url && item.webSocketDebuggerUrl));
    const shutdownCDP = new CDPConnection(loopbackWebSocket(
      shutdownTarget.webSocketDebuggerUrl, shutdownDevTools.port));
    await shutdownCDP.connect(options.timeoutMs);
    await shutdownCDP.send("Runtime.evaluate", {
      expression: `document.querySelector("#external").click(); true`,
      userGesture: true, returnByValue: true,
    });
    shutdownCDP.close();
    await writeFile(shutdownActivatedPath, "1\n");
    externalShutdownValidation = await poll(
      "external protocol shutdown cancellation", options.timeoutMs,
      async () => { try { return JSON.parse(await readFile(shutdownReportPath, "utf8")); }
        catch { return false; } });
    assert(externalShutdownValidation.status === "passed" &&
      externalShutdownValidation.checks?.shutdownExternalProtocolCancelledOnce === true,
    `External shutdown validation failed: ${JSON.stringify(externalShutdownValidation)}`);
    const shutdownDiagnostics = await poll("native shutdown state release", options.timeoutMs,
      async () => {
        const value = await readFile(join(options.artifactsPath,
          "external-shutdown.stderr.log"), "utf8");
        return /one-second-after-request[^\n]*browsers=0 pages=0 contexts=0[^\n]*KeepAlives=\[REMOTE_DEBUGGING \(1\)\]/.test(value) && value;
      });
    externalShutdownValidation.checks.shutdownNativeStateReleased = Boolean(shutdownDiagnostics);
    const shutdownBrowserCDP = new CDPConnection(shutdownDevTools.browserWebSocket);
    await shutdownBrowserCDP.connect(options.timeoutMs);
    try { await shutdownBrowserCDP.send("Browser.close", {}, 2_000); }
    catch { /* the test-only debugging server may close before replying */ }
    shutdownBrowserCDP.close();
    await poll("external shutdown harness exit", options.timeoutMs,
      async () => shutdownChild.exitCode !== null || shutdownChild.signalCode !== null);
    assert(shutdownChild.exitCode === 0 && shutdownChild.signalCode === null,
      `External shutdown harness did not exit cleanly (${shutdownChild.signalCode ??
        `code ${shutdownChild.exitCode}`})`);
    }
    devToolsShutdownProfilePath = await import("node:fs/promises").then(({ mkdtemp }) =>
      mkdtemp(join(tmpdir(), "cobble-chromium-devtools-shutdown-")));
    const devToolsShutdownReportPath = join(
      options.artifactsPath, "devtools-shutdown-validation.json");
    const devToolsShutdownStdout = openSync(
      join(options.artifactsPath, "devtools-shutdown.stdout.log"), "wx");
    const devToolsShutdownStderr = openSync(
      join(options.artifactsPath, "devtools-shutdown.stderr.log"), "wx");
    devToolsShutdownChild = spawn(harness.binaryPath, [
      `--user-data-dir=${devToolsShutdownProfilePath}`, "--no-first-run", "--noerrdialogs",
      "--no-default-browser-check", "--use-mock-keychain", "--disable-background-networking",
      "--disable-sync", "--no-pings", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
    ], {
      detached: true,
      env: {
        ...process.env,
        COBBLE_CHROMIUM_HARNESS_URL: fixture.pageA,
        COBBLE_CHROMIUM_DEVTOOLS_SHUTDOWN_REPORT: devToolsShutdownReportPath,
      },
      stdio: ["ignore", devToolsShutdownStdout, devToolsShutdownStderr],
    });
    closeSync(devToolsShutdownStdout); closeSync(devToolsShutdownStderr);
    const devToolsShutdownValidation = await poll(
      "DevTools runtime shutdown validation", options.timeoutMs, async () => {
        try { return JSON.parse(await readFile(devToolsShutdownReportPath, "utf8")); }
        catch { return false; }
      });
    assert(devToolsShutdownValidation.status === "passed" &&
      devToolsShutdownValidation.checks?.runtimeQuitClosesDevToolsOnce === true,
    `DevTools runtime shutdown validation failed: ${JSON.stringify(devToolsShutdownValidation)}`);
    await poll("DevTools shutdown harness exit", options.timeoutMs,
      async () => devToolsShutdownChild.exitCode !== null ||
        devToolsShutdownChild.signalCode !== null);
    assert(devToolsShutdownChild.exitCode === 0 && devToolsShutdownChild.signalCode === null,
      `DevTools shutdown harness did not exit cleanly (${devToolsShutdownChild.signalCode ??
        `code ${devToolsShutdownChild.exitCode}`})`);
    const durableHistory = await checkHistoryStorage(profilePath);
    await deleteFixtureClientKeychain(fixture);
    report = {
      status: "passed",
      startedAt,
      finishedAt: new Date().toISOString(),
      harness: {
        app: options.appPath,
        bundleID: harness.bundleID,
        chromiumVersion: harness.version,
        productDirectory: harness.productDirectory,
        sdkRevision: harness.manifest.sdk_revision,
      },
      devTools: {
        address: "127.0.0.1",
        port: devTools.port,
        browser: devTools.version.Browser,
        protocolVersion: devTools.version["Protocol-Version"],
        targetID: target.id,
      },
      checks: {
        navigation: true,
        initialDOM: true,
        nativePopups: popupChecks,
        popupGestures: popupGestureChecks,
        blockedPopup,
        pageMetadata: { faviconMetadata, hoveredMetadata, clearedMetadata },
        permissionPromptDenied: permission,
        formSubmission: true,
        historyFormRestoration: true,
        computedStyle: render,
        webgl2: graphics,
        webgl2CanvasScreenshot: canvasScreenshotPath,
        downloads: {
          networkBytes: fixture.networkDownload.length,
          networkProgress: true,
          blobBytes: Buffer.byteLength(fixture.blobDownload),
          cancellationQuiesced: true,
          pauseResumeExactBytes: fixture.pausedDownload.length,
          cancelWhilePausedQuiesced: true,
          releasedControlsRejected: true,
          unknownTotalExactBytes: fixture.unknownTotalDownload.length,
          interruptedGETExactBytes: fixture.interruptedDownload.length,
          interruptedGETFailureEpisodes: 2,
          interruptedGETRequestCount: interruptedGETs.length,
          cancelWhileInterruptedQuiesced: true,
          interruptedPOSTRequestSequence: interruptedPOSTs.map(request => request.method),
          existingDestinationRejected: true,
          danglingDestinationRejected: true,
        },
        nativeValidation,
        clientCertificateAuthenticatedRequests: clientCertificateRequests.map((request) => request.path),
        clientCertificateTLS: clientCertificateStats,
        clientCertificateEmptyStoreValidations: emptyClientCertificateValidations,
        clientCertificateKeychainSearchListIsolation:
          fixture.clientCertificate.keychainSearchListEvidence,
        skippedChecks,
        profileRestartValidation,
        externalShutdownValidation,
        devToolsShutdownValidation,
        screenshot: screenshotPath,
        orderlyShutdown: true,
        durableHistory,
      },
      performanceObservation: {
        launchToSmokeReadyMs,
        timingScope: "Includes native validation and CDP initialization; not a cold-start or first-paint measurement.",
        idleProcessTree: processObservation,
        physicalFootprint,
      },
      scope: "CDP engine smoke plus SDK download callbacks; native focus, accessibility, and IME remain separate gates",
      fixtureRequests: fixture.requests,
    };
    console.log(`PASS: Chromium ${harness.version} navigation, DOM, form, rendering, WebGL2, downloads, clean shutdown, and empty History tables`);
  } catch (error) {
    report = {
      status: "failed",
      startedAt,
      finishedAt: new Date().toISOString(),
      error: error instanceof Error ? { message: error.message, stack: error.stack } : { message: String(error) },
      fixtureRequests: fixture?.requests ?? [],
    };
    throw error;
  } finally {
    if (report) {
      try {
        await writeFile(join(options.artifactsPath, "result.json"),
          `${JSON.stringify(report, null, 2)}\n`);
      } catch (error) {
        console.error(`Could not preserve smoke result: ${error.message}`);
      }
    }
    if (cdp) {
      try { await cdp.send("Browser.close", {}, 2_000); } catch { /* teardown continues */ }
      try { cdp.close(); } catch { /* teardown continues */ }
    }
    try { await terminate(child); } catch (error) {
      console.error(`Could not terminate every harness process: ${error.message}`);
    }
    try { await terminate(restartChild); } catch (error) {
      console.error(`Could not terminate profile restart harness: ${error.message}`);
    }
    try { await terminate(shutdownChild); } catch (error) {
      console.error(`Could not terminate external shutdown harness: ${error.message}`);
    }
    try { await terminate(devToolsShutdownChild); } catch (error) {
      console.error(`Could not terminate DevTools shutdown harness: ${error.message}`);
    }
    for (const entry of clientCertificateEmptyChildren) {
      try { await terminate(entry.child); } catch (error) {
        console.error(`Could not terminate restricted client-certificate harness: ${error.message}`);
      }
      try { await rm(entry.profilePath, { recursive: true, force: true }); } catch (error) {
        console.error(`Could not remove restricted client-certificate profile: ${error.message}`);
      }
    }
    if (fixture) {
      try {
        await closeFixture(fixture);
      } catch (error) {
        console.error(`Could not close fixture server: ${error.message}`);
      }
    }
    try { await rm(profilePath, { recursive: true, force: true }); } catch (error) {
      console.error(`Could not remove isolated Chromium profile: ${error.message}`);
    }
    if (shutdownProfilePath) {
      try { await rm(shutdownProfilePath, { recursive: true, force: true }); }
      catch (error) { console.error(`Could not remove shutdown profile: ${error.message}`); }
    }
    if (devToolsShutdownProfilePath) {
      try { await rm(devToolsShutdownProfilePath, { recursive: true, force: true }); }
      catch (error) { console.error(`Could not remove DevTools shutdown profile: ${error.message}`); }
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}
