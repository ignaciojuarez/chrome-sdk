#!/usr/bin/env python3
"""Run the Chromium identity fixture against one matched SDK/runtime build."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit


class Fixture(BaseHTTPRequestHandler):
    events = []
    lock = threading.Lock()

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.serve()

    def do_POST(self):
        self.serve()

    def serve(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/events":
            with self.lock:
                body = json.dumps(self.events).encode()
            self.reply(200, "application/json", body)
            return
        query = parse_qs(parsed.query)
        size = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(size).decode() if size else ""
        event = {"path": self.path, "method": self.command, "body": data,
                 "ua": self.headers.get("User-Agent", "")}
        with self.lock:
            event["id"] = len(self.events) + 1
            self.events.append(event)
        case = query.get("case", [""])[0]
        next_mode = query.get("next", ["default"])[0]
        if parsed.path == "/redirect":
            code = int(query.get("code", ["302"])[0])
            target_case = ("post307-result" if code == 307 else
                           "post308-result" if code == 308 else
                           case + "-result" if case.startswith("mobile-to-") else
                           "redirect-result")
            target = "/page?" + urlencode({"mode": next_mode, "case": target_case})
            if query.get("cross", [""])[0] == "1":
                target = f"http://localhost:{self.server.server_port}" + target
            self.send_response(code)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if parsed.path != "/page":
            self.reply(404, "text/plain", b"missing")
            return
        echoed = {
            "path": parsed.path, "requestURL": self.path, "requestID": event["id"],
            "method": self.command, "body": data,
            "httpUA": self.headers.get("User-Agent", ""),
            "httpPlatform": self.headers.get("Sec-CH-UA-Platform"),
            "httpMobile": self.headers.get("Sec-CH-UA-Mobile"),
            "httpPlatformVersion": self.headers.get("Sec-CH-UA-Platform-Version"),
            "httpModel": self.headers.get("Sec-CH-UA-Model"),
            "httpFullVersionList": self.headers.get("Sec-CH-UA-Full-Version-List"),
        }
        action = query.get("action", [""])[0]
        if action in ("link", "script"):
            target = "/page?" + urlencode({"mode": next_mode, "case": action + "-result"})
        elif action == "form":
            target = "/page?" + urlencode({"mode": next_mode, "case": "form-result"})
        elif action == "iframe":
            target = "/page?" + urlencode({"mode": next_mode, "case": "frame-child"})
        elif action == "popup":
            target = "/page?" + urlencode({"mode": next_mode, "case": "popup-result"})
        elif action == "blank-popup":
            target = "about:blank"
        elif action in ("redirect", "post307", "post308"):
            code = "307" if action == "post307" else "308" if action == "post308" else "302"
            target = "/redirect?" + urlencode(
                {"mode": "default", "next": next_mode, "case": case, "code": code})
        else:
            target = ""
        js = """
let actionDone = false;
let iframeLoaded = false;
let popupUA = null;
let pageShown = false;
let pageShowCount = 0;
let latePageShowCount = 0;
let pageShowUA = null;
let pageShowPlatform = null;
async function publishIdentity() {
  const u = navigator.userAgentData;
  let high = null;
  if (u) {
    try { high = await u.getHighEntropyValues(['platform', 'platformVersion', 'model']); }
    catch (_) {}
  }
  const result = {...ECHO, jsUA: navigator.userAgent, jsHref: location.href,
    jsPlatform: u?.platform ?? null, jsMobile: u?.mobile ?? null,
    jsHighPlatform: high?.platform ?? null,
    jsHighPlatformVersion: high?.platformVersion ?? null,
    jsHighModel: high?.model ?? null, width: innerWidth,
    touchPoints: navigator.maxTouchPoints, iframeLoaded, popupUA,
    pageShowCount, latePageShowCount, pageShowUA, pageShowPlatform};
  document.title = 'CobbleIdentity:' + btoa(JSON.stringify(result));
  if ((location.search.includes('case=popup-result') ||
       location.search.includes('case=blank-reset')) && window.opener) {
    window.opener.postMessage({kind: 'identity-popup', ua: navigator.userAgent}, '*');
  }
  if (actionDone) return;
  actionDone = true;
  setTimeout(() => {
    const target = TARGET;
    switch (ACTION) {
      case 'link': {
        const a = document.createElement('a'); a.href = target; document.body.append(a);
        a.click(); break;
      }
      case 'script': location.href = target; break;
      case 'iframe': {
        const frame = document.createElement('iframe'); frame.src = target;
        frame.addEventListener('load', () => {
          iframeLoaded = true; publishIdentity();
        });
        document.body.append(frame); break;
      }
      case 'popup': window.open(target, '_blank'); break;
      case 'blank-popup': {
        const child = window.open('about:blank', '_blank');
        if (child) setTimeout(() => {
          child.document.title = 'CobbleBlank:' + btoa(JSON.stringify({
            ua: child.navigator.userAgent,
            platform: child.navigator.userAgentData?.platform ?? null,
            href: child.location.href
          }));
        }, 100);
        break;
      }
      case 'form':
      case 'post307':
      case 'post308': {
        const form = document.createElement('form'); form.method = 'post'; form.action = target;
        const field = document.createElement('input'); field.name = 'identity';
        field.value = 'body-preserved'; form.append(field); document.body.append(form);
        form.submit(); break;
      }
      case 'redirect': location.href = target; break;
    }
  }, 180);
}
addEventListener('message', event => {
  if (event.origin === location.origin && event.data?.kind === 'identity-popup') {
    popupUA = event.data.ua; publishIdentity();
  }
});
addEventListener('pageshow', () => {
  pageShown = true;
  ++pageShowCount;
  pageShowUA = navigator.userAgent;
  pageShowPlatform = navigator.userAgentData?.platform ?? null;
  publishIdentity();
  setTimeout(() => { latePageShowCount = pageShowCount; publishIdentity(); }, 600);
});
addEventListener('resize', () => { if (pageShown) publishIdentity(); });
""".replace("ECHO", json.dumps(echoed)).replace(
            "TARGET", json.dumps(target)).replace("ACTION", json.dumps(action))
        body = ("<!doctype html><meta charset=utf-8><title>Loading identity</title>"
                "<body><script>" + js + "</script></body>").encode()
        self.reply(200, "text/html; charset=utf-8", body)

    def reply(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-CH", "Sec-CH-UA-Platform-Version, Sec-CH-UA-Model, Sec-CH-UA-Full-Version-List")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chromium_app", type=Path)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    report = artifacts / "identity-report.json"
    report.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="cobble-identity-") as work:
        work = Path(work)
        bundle = work / "Chromium Identity Harness.app"
        subprocess.run([sys.executable, str(Path(__file__).with_name("assemble_harness.py")),
                        str(args.chromium_app), "--output", str(bundle)], check=True)
        environment = dict(__import__("os").environ)
        environment.update({
            "COBBLE_CHROMIUM_IDENTITY_REPORT": str(report),
            "COBBLE_CHROMIUM_HARNESS_URL": f"http://127.0.0.1:{server.server_port}/page?mode=default&case=base",
        })
        binary = bundle / "Contents" / "MacOS" / "Chromium"
        arguments = [str(binary), f"--user-data-dir={work / 'profile'}",
                     "--use-mock-keychain", "--no-first-run",
                     "--no-default-browser-check", "--disable-background-networking",
                     "--disable-component-update", "--disable-sync", "--no-pings",
                     "--disable-popup-blocking"]
        with (artifacts / "harness.stdout.log").open("w") as stdout, (
                artifacts / "harness.stderr.log").open("w") as stderr:
            child = subprocess.Popen(arguments, env=environment, stdout=stdout, stderr=stderr)
            deadline = time.monotonic() + 180
            try:
                while time.monotonic() < deadline and not report.exists():
                    if child.poll() is not None:
                        raise RuntimeError(f"Harness exited before report: {child.returncode}")
                    time.sleep(.2)
                if not report.exists():
                    raise TimeoutError("Identity report timed out")
                result = json.loads(report.read_text())
                if result.get("status") != "passed" or not all(
                        result.get("checks", {}).values()):
                    raise RuntimeError(f"Identity fixture failed: {result}")
                try:
                    code = child.wait(timeout=12)
                except subprocess.TimeoutExpired as error:
                    raise TimeoutError("Harness wrote a pass report but did not quit") from error
                if code != 0:
                    raise RuntimeError(f"Harness exited {code} after pass report")
                print(json.dumps(result, indent=2))
            finally:
                with Fixture.lock:
                    (artifacts / "http-events.json").write_text(
                        json.dumps(Fixture.events, indent=2))
                try:
                    child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                server.shutdown()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError,
            RuntimeError, TimeoutError) as error:
        sys.exit(str(error))
