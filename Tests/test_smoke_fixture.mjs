import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInNewContext } from "node:vm";

const { startFixture, closeFixture, checkHistoryStorage } = await import("../scripts/smoke.mjs");

// Check the generated fixture's acceptance logic; this does not simulate an engine.
const harnessSource = await readFile(new URL(
  "../Sources/ChromiumHarness/ChromiumHarnessValidation.swift", import.meta.url), "utf8");
const topologyScript = harnessSource.match(/let topologyScript = """\n([\s\S]*?)\n\s*"""/)?.[1];
assert.ok(topologyScript, "Native topology fixture script must exist");
const topologyTab = (slot, windowId, active) => ({
  url: `chrome-extension://fixture/topology.html?token=test&slot=${slot}`, windowId, active,
});
async function topologyResult(phase, tabs) {
  const document = { title: "pending" };
  const windows = [...new Set(tabs.map(tab => tab.windowId))].map(id => ({
    id, tabs: tabs.filter(tab => tab.windowId === id),
  }));
  await runInNewContext(topologyScript, {
    URL, document, location: { href: `chrome-extension://fixture/topology.html?token=test&phase=${phase}` },
    chrome: { windows: { getAll: async () => windows } }, setTimeout() {},
  });
  return document.title;
}
const initialTabs = [topologyTab("a", 1, false), topologyTab("b", 1, true), topologyTab("c", 2, true)];
assert.equal(await topologyResult("initial", initialTabs), "Cobble topology initial passed");
assert.equal(await topologyResult("activated", initialTabs), "pending");
assert.equal(await topologyResult("activated", [topologyTab("a", 1, true), topologyTab("b", 1, false), initialTabs[2]]),
  "Cobble topology activated passed");
assert.equal(await topologyResult("after-close", initialTabs), "pending");
assert.equal(await topologyResult("after-close", initialTabs.slice(1)), "Cobble topology after-close passed");
assert.equal(await topologyResult("initial", [...initialTabs, initialTabs[0]]), "pending");
assert.equal(await topologyResult("initial", [topologyTab("a", 3, false), ...initialTabs.slice(1)]), "pending");
console.log("PASS: topology fixture rejects stale close state, wrong activation, duplicate tabs and separate groups");

const fixture = await startFixture("fixture-test-token");

try {
  const page = await fetch(fixture.pageB);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get("content-security-policy"),
    "default-src 'self'; style-src 'unsafe-inline'; form-action 'self'");
  const pageSource = await page.text();
  assert.match(pageSource, /<script src="\/fixture\/fixture-test-token\/graphics\.js"><\/script>/);
  const pageASource = await (await fetch(fixture.pageA)).text();
  assert.match(pageASource, /rel="icon"/);
  assert.match(pageASource, /id="hover-target"/);
  const favicon = Buffer.from(await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/favicon.png`)).arrayBuffer());
  assert.equal(favicon.readUInt32BE(16), 16);
  assert.equal(favicon.readUInt32BE(20), 16);
  const dialogSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/js-dialog?mode=prompt`)).text();
  assert.match(dialogSource, /prompt\("Cobble prompt/);
  const chooserSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/file-chooser`)).text();
  assert.match(chooserSource, /type="file" accept="\.txt,text\/plain"/);
  const folderSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/file-folder`)).text();
  assert.match(folderSource, /webkitdirectory multiple/);
  assert.match(folderSource, /webkitRelativePath/);
  const exclusiveSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/exclusive-access`)).text();
  assert.match(exclusiveSource, /requestFullscreen/);
  assert.match(exclusiveSource, /requestPointerLock/);
  assert.match(exclusiveSource, /navigator\.keyboard\.lock/);
  assert.match(exclusiveSource, /navigator\.bluetooth\.requestDevice/);
  assert.match(exclusiveSource, /new PaymentRequest/);
  assert.match(exclusiveSource, /requestPictureInPicture/);
  assert.match(exclusiveSource, /documentPictureInPicture\.requestWindow/);
  assert.match(exclusiveSource, /getDisplayMedia/);
  const frameSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/file-frame-parent`)).text();
  assert.match(frameSource, /file-frame-child/);
  const beforeUnloadSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/beforeunload`)).text();
  assert.match(beforeUnloadSource, /addEventListener\("beforeunload"/);
  const auth = await fetch(`${fixture.origin}/fixture/${fixture.token}/http-auth`);
  assert.equal(auth.status, 401);
  assert.equal(auth.headers.get("www-authenticate"), `Basic realm="Cobble Fixture ${fixture.token}"`);
  const secure = await fetch(fixture.securePage, { dispatcher: undefined }).catch(() => null);
  assert.equal(secure, null, "The generated TLS identity must not be globally trusted");
  assert.match(fixture.spkiAllowlist, /^[A-Za-z0-9+/]{43}=$/);
  assert.notEqual(new URL(fixture.securePage).port, new URL(fixture.invalidSecurePage).port);
  assert.ok(fixture.mediaPage.startsWith(new URL(fixture.securePage).origin));
  assert.equal((await stat(fixture.clientCertificate.keychain)).isFile(), true);
  assert.equal(fixture.clientCertificate.keychainSearchListEvidence
    .normalBeforeContainedOwnedKeychain, false);
  assert.equal(fixture.clientCertificate.keychainSearchListEvidence
    .normalDuringContainedOwnedKeychain, false);
  assert.equal(typeof fixture.clientCertificate.keychainSearchListEvidence
    .isolatedDuringContainedOwnedKeychain, "boolean");
  assert.deepEqual(fixture.clientCertificate.mainNames,
    ["select", "document", "cancel", "unhandled", "stale", "close", "reentrant"]);
  assert.deepEqual(fixture.clientCertificate.emptyNames, ["missing", "relative", "directory"]);
  assert.equal(new Set([...fixture.clientCertificate.mainNames,
    ...fixture.clientCertificate.emptyNames].map((name) =>
      new URL(fixture.clientCertificate[name]).origin)).size, 10);
  const clientCertificateDocument = await (await fetch(
    fixture.clientCertificate.documentPage)).text();
  assert.match(clientCertificateDocument, new RegExp(
    fixture.clientCertificate.document.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(clientCertificateDocument, /dataset\.clientCertificate='document'/);
  const blockingSource = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/blocking`)).text();
  assert.match(blockingSource, /blocked\.js/);
  assert.match(blockingSource, /blocked\.png/);
  assert.match(await (await fetch(fixture.domPage)).text(), /mutated-fixture-test-token/);
  assert.match(await (await fetch(fixture.reloadGET)).text(), /Cobble Reload GET 1/);
  assert.match(await (await fetch(fixture.reloadGET)).text(), /Cobble Reload GET 2/);
  assert.match(await (await fetch(fixture.reloadPOSTStart)).text(), /method="post"/);
  assert.match(await (await fetch(fixture.reloadPOSTTarget, {
    method: "POST", body: "token=fixture-test-token",
  })).text(), /Cobble Reload POST 1/);
  const repostStart = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/repost-start?case=route-test`)).text();
  assert.match(repostStart, /method="post"/);
  assert.match(repostStart, /name="case" value="route-test"/);
  const repostBody = `token=${fixture.token}&case=route-test`;
  const repostResponse = await fetch(
    `${fixture.origin}/fixture/${fixture.token}/repost?case=route-test`, {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: repostBody,
    });
  const repostHTML = await repostResponse.text();
  assert.match(repostHTML, /Cobble Repost route-test 1 fixture-test-token/);
  assert.match(repostHTML, new RegExp(`data-request-body-base64="${Buffer.from(repostBody).toString("base64")}"`));
  assert.deepEqual(await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/repost-stats?case=route-test`)).json(), {
      postCount: 1, nonPostCount: 0, bodyBase64: [Buffer.from(repostBody).toString("base64")],
    });
  const rendererRepost = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/repost?case=renderer-accept`, {
      method: "POST", body: `token=${fixture.token}&case=renderer-accept`,
    })).text();
  assert.match(rendererRepost, /dataset\.reloadAttempted/);
  const beforeUnloadRepost = await (await fetch(
    `${fixture.origin}/fixture/${fixture.token}/repost?case=beforeunload`, {
      method: "POST", body: `token=${fixture.token}&case=beforeunload`,
    })).text();
  assert.match(beforeUnloadRepost, /enable-beforeunload/);
  assert.match(beforeUnloadRepost, /addEventListener\('beforeunload'/);
  const httpRedirect = await fetch(
    `${fixture.origin}/fixture/${fixture.token}/local-http-redirect`, { redirect: "manual" });
  assert.equal(httpRedirect.status, 302);
  assert.equal(httpRedirect.headers.get("location"), `/fixture/${fixture.token}/page-a`);
  const localTarget = "file:///tmp/cobble%20fixture.html";
  const fileRedirect = await fetch(
    `${fixture.origin}/fixture/${fixture.token}/local-file-redirect?target=${encodeURIComponent(localTarget)}`,
    { redirect: "manual" });
  assert.equal(fileRedirect.status, 302);
  assert.equal(fileRedirect.headers.get("location"), localTarget);
  await assert.rejects(fetch(`${fixture.origin}/fixture/${fixture.token}/local-abort`));
  const unknownTotal = await fetch(fixture.unknownTotalDownloadURL);
  assert.equal(unknownTotal.headers.get("content-length"), null);
  assert.deepEqual(Buffer.from(await unknownTotal.arrayBuffer()), fixture.unknownTotalDownload);

  const graphicsURL = `${fixture.origin}/fixture/${fixture.token}/graphics.js`;
  const workerURL = `${fixture.origin}/fixture/${fixture.token}/graphics-worker.js`;
  const [graphicsResponse, workerResponse] = await Promise.all([fetch(graphicsURL), fetch(workerURL)]);
  for (const response of [graphicsResponse, workerResponse]) {
    assert.match(response.headers.get("content-type") ?? "", /^text\/javascript; charset=utf-8$/);
    assert.equal(response.headers.get("content-security-policy"),
      "default-src 'self'; style-src 'unsafe-inline'; form-action 'self'");
  }
  const [graphicsSource, workerSource] = await Promise.all([graphicsResponse.text(), workerResponse.text()]);
  new Function(graphicsSource);
  new Function(workerSource);
  const network = await fetch(fixture.networkDownloadURL);
  assert.equal(network.headers.get("content-disposition"),
    `attachment; filename="${fixture.networkDownloadName}"`);
  assert.deepEqual(Buffer.from(await network.arrayBuffer()), fixture.networkDownload);
  for (const [url, name] of [
    [fixture.existingDestinationDownloadURL, fixture.existingDestinationDownloadName],
    [fixture.danglingDestinationDownloadURL, fixture.danglingDestinationDownloadName],
  ]) {
    const probe = await fetch(url);
    assert.equal(probe.headers.get("content-disposition"), `attachment; filename="${name}"`);
    assert.equal(probe.headers.get("content-type"), "application/octet-stream");
    const reader = probe.body.getReader();
    const first = await reader.read();
    assert(first.value.length > 0 && first.value.every((byte) => byte === 0x4f));
    await reader.cancel();
  }
  const [extensionTarget, delayedTitle, streamedHistoryTitle, validationWrite, validationRead] = await Promise.all([
    fetch(fixture.extensionTarget), fetch(fixture.delayedTitle),
    fetch(fixture.streamedHistoryTitle), fetch(fixture.validationWrite), fetch(fixture.validationRead),
  ]);
  assert.match(await extensionTarget.text(), /Cobble Extension Baseline fixture-test-token/);
  assert.match(await delayedTitle.text(), /Cobble Validation Settled fixture-test-token/);
  const streamedHistoryHTML = await streamedHistoryTitle.text();
  assert.match(streamedHistoryHTML, /history\.pushState\(\{\}, "", "\?phase=during"\)/);
  assert.match(streamedHistoryHTML, /history\.pushState\(\{\}, "", "\?phase=after#settled"\)/);
  const writeHTML = await validationWrite.text();
  const readHTML = await validationRead.text();
  const storageResult = (html, cookie, value, writable = true) => {
    const document = { cookie, title: "pending" };
    const localStorage = {
      getItem: () => value,
      setItem: (_key, next) => { if (writable) value = next; },
    };
    const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
    assert.ok(script, "Storage fixture script must exist");
    runInNewContext(script, { document, localStorage });
    return document.title;
  };
  const cookie = `cobble_validation=${fixture.token}`;
  assert.equal(storageResult(writeHTML, cookie, null), `Cobble Validation Written ${fixture.token}`);
  assert.equal(storageResult(writeHTML, "", null), "pending");
  assert.equal(storageResult(writeHTML, cookie, null, false), "pending");
  assert.equal(storageResult(readHTML, cookie, fixture.token), `Cobble Validation Present ${fixture.token}`);
  assert.equal(storageResult(readHTML, "", null), `Cobble Validation Empty ${fixture.token}`);
  assert.equal(storageResult(readHTML, cookie, null), `Cobble Validation Partial ${fixture.token}`);
  assert.equal(storageResult(readHTML, "", fixture.token), `Cobble Validation Partial ${fixture.token}`);
  assert.equal(storageResult(readHTML, cookie, "another profile"), `Cobble Validation Partial ${fixture.token}`);
  assert.equal(new URL(fixture.websiteData.aSetup).hostname, "cobble-a.test");
  assert.equal(new URL(fixture.websiteData.subdomainSetup).hostname, "sub.cobble-a.test");
  assert.equal(new URL(fixture.websiteData.bSetup).hostname, "cobble-b.test");
  assert.equal(new URL(fixture.websiteData.ipSetup).hostname, "127.0.0.1");
  assert.equal(fixture.websiteData.domainA, "cobble-a.test");
  const localFixtureURL = (value) => {
    const url = new URL(value);
    return new URL(`${url.pathname}${url.search}`, fixture.origin);
  };
  const [websiteSetup, websiteRead, diskCache] = await Promise.all([
    fetch(localFixtureURL(fixture.websiteData.aSetup)),
    fetch(localFixtureURL(fixture.websiteData.aRead)),
    fetch(localFixtureURL(fixture.websiteData.oldCache)),
  ]);
  assert.match(await websiteSetup.text(), /indexedDB\.open\('cobble-website-data-'/);
  const websiteReadHTML = await websiteRead.text();
  assert.match(websiteReadHTML, /indexedDB\.databases\(\)/);
  assert.match(websiteReadHTML, /caches\.has\(cacheName\)/);
  assert.match(await diskCache.text(), /Cobble Disk Cache Loaded old fixture-test-token 1/);
  assert.equal((await (await fetch(fixture.websiteData.cacheStats)).json()).old, 1);
  const unrelated = await fetch(`${fixture.origin}/fixture/another-token/graphics.js`);
  assert.equal(unrelated.status, 404);
  console.log("PASS: tokenized smoke fixture routes, CSP, MIME, and served script syntax");
} finally {
  await closeFixture(fixture);
}
assert.equal(fixture.clientCertificate.keychainDeleted, true);
assert.equal(fixture.clientCertificate.keychainSearchListEvidence
  .normalAfterDeleteContainedOwnedKeychain, false);

const profile = await mkdtemp(join(tmpdir(), "cobble-smoke-history-test-"));
try {
  await assert.rejects(checkHistoryStorage(profile), /Expected isolated harness profile/);
  const harnessProfile = join(profile, "Cobble-harness");
  const validationProfile = join(profile, "Cobble-harness-validation");
  const otherValidationProfile = join(profile, "Cobble-harness-validation-other");
  await mkdir(harnessProfile);
  await mkdir(otherValidationProfile);
  const absent = await checkHistoryStorage(profile);
  assert.ok(absent.profiles.every((item) => item.status === "absent"));
  await mkdir(validationProfile);
  await assert.rejects(checkHistoryStorage(profile), /Deleted isolated harness profile still exists/);
  await rm(validationProfile, { recursive: true });
  const database = join(harnessProfile, "History");
  const sql = (statement) => execFileSync("python3", ["-c",
    "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.close()",
    database, statement]);
  sql("CREATE TABLE urls (url TEXT); CREATE TABLE visits (url INTEGER);");
  const empty = await checkHistoryStorage(profile);
  assert.equal(empty.profiles.find((item) => item.profile === "Cobble-harness").status, "empty");
  sql("INSERT INTO urls VALUES ('http://127.0.0.1/fixture/test'); INSERT INTO visits VALUES (1);");
  await assert.rejects(checkHistoryStorage(profile), /Chromium saved hidden browsing history/);
  sql("DELETE FROM urls; DELETE FROM visits;");
  for (const table of ["downloads", "downloads_url_chains", "downloads_slices"]) {
    sql(`CREATE TABLE ${table} (id INTEGER); INSERT INTO ${table} VALUES (1);`);
    await assert.rejects(checkHistoryStorage(profile), /Chromium saved hidden browsing history/,
      `Persisted ${table} records must fail even when navigation history is empty`);
    sql(`DELETE FROM ${table};`);
  }
  assert.equal((await checkHistoryStorage(profile)).profiles
    .find((item) => item.profile === "Cobble-harness").status, "empty");
  await rm(database);
  await symlink(join(profile, "outside"), database);
  await assert.rejects(checkHistoryStorage(profile), /must not be a symbolic link/);
  console.log("PASS: fresh-profile history inspection rejects persisted visits, downloads, and unsafe paths");
} finally {
  await rm(profile, { recursive: true, force: true });
}
