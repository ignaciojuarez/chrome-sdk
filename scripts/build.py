#!/usr/bin/env python3
"""Pinned full-Chromium build. Uses only the Python standard library.

Run each stage independently so expensive checkouts/builds can be resumed.
The upstream stage produces stock Chromium; it is not an SDK release.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import shutil
import subprocess
import sys
import time
import urllib.request

from apply_chromium import (apply, build_lock, validate_checkout,
                            validate_installed_files, validate_patch_series)

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://chromium.googlesource.com/chromium/src.git"
DEPOT = "https://chromium.googlesource.com/chromium/tools/depot_tools.git"
SDK_MANIFEST = "CobbleChromiumSDK.json"
BUILD_RECEIPT = "CobbleChromiumBuild.json"


def file_sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def native_payload(root=ROOT):
    overlay_root = root / "chromium" / "overlay"
    patch_root = root / "chromium" / "patches"
    overlay_paths = sorted(overlay_root.rglob("*"))
    patch_paths = sorted(patch_root.glob("*.patch"))
    if any(path.is_symlink() for path in [*overlay_paths, *patch_paths]):
        raise ValueError("Native Chromium payload may not contain symlinks")
    overlay = {str(path.relative_to(overlay_root)): file_sha256(path)
               for path in overlay_paths if path.is_file()}
    patches = {path.name: file_sha256(path) for path in patch_paths}
    if not overlay or not patches:
        raise ValueError("Native Chromium overlay or patches are missing")
    files = {"overlay": overlay, "patches": patches}
    canonical = json.dumps(files, sort_keys=True,
                           separators=(",", ":")).encode()
    return {**files, "sha256": hashlib.sha256(canonical).hexdigest()}


def sdk_revision(root=ROOT):
    revision = run(["git", "rev-parse", "HEAD"], cwd=root,
                   capture=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid SDK git revision")
    return revision


def validate_sdk_source(source, payload):
    stamp_path = source / ".cobble-chromium-sdk.json"
    if not stamp_path.is_file():
        raise ValueError("SDK source stamp is missing")
    stamp = json.loads(stamp_path.read_text())
    if (stamp.get("patches") != payload["patches"] or
            stamp.get("overlay") != payload["overlay"]):
        raise ValueError("Built Chromium source has a stale native payload")


def required_sdk_exports(root=ROOT):
    loader = (root / "Sources/CCobbleChromium/CCSLoader.c").read_text()
    required = {"_" + symbol for symbol in re.findall(
        r'RESOLVE\([^,]+, "(CCS[A-Za-z0-9_]+)"\)', loader)}
    if not required:
        raise ValueError("The SDK loader declares no required exports")
    return required


def validate_sdk_exports(source, root=ROOT):
    exported = set(
        (source / "chrome/app/framework.exports").read_text().splitlines())
    missing = sorted(required_sdk_exports(root) - exported)
    if missing:
        raise ValueError(
            "Chromium framework export list is missing: " + ", ".join(missing))


def json_without_comments(content):
    result = []
    in_string = False
    escaped = False
    index = 0
    while index < len(content):
        character = content[index]
        if in_string:
            result.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
            result.append(character)
        elif character == "/" and content[index:index + 2] == "//":
            newline = content.find("\n", index)
            if newline < 0:
                break
            result.append("\n")
            index = newline
        else:
            result.append(character)
        index += 1
    return "".join(result)


def validate_sdk_history_policy(source):
    path = source / "chrome/common/extensions/api/_api_features.json"
    if not path.is_file():
        raise ValueError("Chromium extension API features are missing")
    features = json.loads(json_without_comments(path.read_text()))
    platforms = features.get("history", {}).get("platforms")
    if set(platforms or []) != {"chromeos", "linux", "win"}:
        raise ValueError("SDK source still exposes Chromium history on macOS")


def read_lock(path=ROOT / "chromium.lock.json"):
    lock = json.loads(path.read_text())
    if lock.get("schema") != 1 or lock.get("source") != SOURCE:
        raise ValueError("Unsupported lock schema or source")
    if lock.get("channel") != "stable" or lock.get("platform") != "mac":
        raise ValueError("Only macOS stable builds are supported")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", lock.get("version", "")):
        raise ValueError("Invalid Chromium version")
    for key in ("revision", "depot_tools_revision"):
        if not re.fullmatch(r"[0-9a-f]{40}", lock.get(key, "")):
            raise ValueError(f"Invalid {key}")
    return lock


def run(args, cwd=None, env=None, capture=False):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def verify_tag(lock):
    # Gitiles resolves the exact official tag without downloading Git's enormous
    # ref advertisement. Keep verification bounded before a costly checkout.
    url = SOURCE.removesuffix(".git") + "/+/refs/tags/" + lock["version"] + "?format=JSON"
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(1_000_001)
    if len(data) > 1_000_000 or not data.startswith(b")]}'\n"):
        raise ValueError("Invalid official Chromium tag response")
    if json.loads(data[5:]).get("commit") != lock["revision"]:
        raise ValueError("Official Chromium tag does not match the locked commit")


def checkout(path, url, revision, ref=None):
    if not path.exists():
        run(["git", "init", path])
        run(["git", "remote", "add", "origin", url], cwd=path)
    actual = run(["git", "remote", "get-url", "origin"], cwd=path, capture=True).strip()
    if actual != url:
        raise ValueError(f"Refusing checkout with unexpected remote: {path}")
    if run(["git", "status", "--porcelain"], cwd=path, capture=True).strip():
        raise ValueError(f"Refusing to overwrite a dirty checkout: {path}")
    present = subprocess.run(["git", "cat-file", "-e", revision + "^{commit}"],
                             cwd=path, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL).returncode == 0
    if not present:
        run(["git", "fetch", "--depth", "1", "origin", ref or revision], cwd=path)
    run(["git", "checkout", "--detach", revision], cwd=path)
    head = run(["git", "rev-parse", "HEAD"], cwd=path, capture=True).strip()
    if head != revision:
        raise ValueError("Checkout revision mismatch")


def build_environment(work):
    env = os.environ.copy()
    env["PATH"] = str(work / "depot_tools") + os.pathsep + env["PATH"]
    env["DEPOT_TOOLS_UPDATE"] = "0"
    env["DEPOT_TOOLS_BOOTSTRAP_PYTHON3"] = "1"
    # Keep vpython's managed dependencies; do not inherit tooling bypasses.
    env.pop("VPYTHON_BYPASS", None)
    return env


def bootstrap_depot_tools(work, env):
    depot_tools = work / "depot_tools"
    run([depot_tools / "ensure_bootstrap"], cwd=depot_tools, env=env)
    pointer = depot_tools / "python3_bin_reldir.txt"
    if not pointer.is_file():
        raise ValueError("depot_tools bootstrap did not install its Python pointer")
    python = depot_tools / pointer.read_text().strip() / "python3"
    if not python.is_file():
        raise ValueError("depot_tools bootstrap Python is missing")


def preflight(work, minimum_gib):
    if platform.system() != "Darwin":
        raise ValueError("Build the macOS runtime on a Mac with Xcode")
    work.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(work).free / (1024 ** 3)
    print(f"Available disk: {free:.1f} GiB; required headroom: {minimum_gib} GiB")
    run(["xcodebuild", "-version"])
    run(["sysctl", "hw.memsize", "hw.ncpu"])
    if free < minimum_gib:
        raise ValueError("Insufficient free space. Use a dedicated build volume; no user data is deleted.")


def prepare(work, lock, replace_sdk=False, previous_sdk=None):
    verify_tag(lock)
    checkout(work / "depot_tools", DEPOT, lock["depot_tools_revision"])
    env = build_environment(work)
    bootstrap_depot_tools(work, env)
    solutions = [{"name": "src", "url": SOURCE, "managed": False,
                  "custom_deps": {}, "custom_vars": {"checkout_pgo_profiles": True}}]
    config = "solutions = " + repr(solutions) + "\ntarget_os = []\n"
    config_path = work / ".gclient"
    if config_path.exists() and config_path.read_text() != config:
        raise ValueError("Existing .gclient differs; use a new build directory")
    config_path.write_text(config)
    if (work / "src" / ".cobble-chromium-sdk.json").exists():
        # Verify our exact installed patch/overlay bytes before reusing an SDK
        # checkpoint. Never reset a patched source tree behind the caller.
        apply(work / "src", sdk_root=ROOT, replace=replace_sdk,
              previous_sdk=previous_sdk)
        if not (work / ".gclient_entries").is_file():
            raise ValueError("Patched checkpoint lacks dependency records; use a fresh checkout")
    else:
        checkout(work / "src", SOURCE, lock["revision"], "refs/tags/" + lock["version"])
        run(["gclient", "sync", "--nohooks", "--no-history", "-j", "4",
             "--revision", "src@" + lock["revision"]], cwd=work, env=env)
    run(["gclient", "runhooks"], cwd=work, env=env)


def build_directory(work):
    # The first upstream CI run used this name. Keep its existing object paths
    # when adding the overlay so GN can reuse the expensive common objects.
    previous = work / "src" / "out" / "Upstream"
    return previous if (previous / "args.gn").exists() else work / "src" / "out" / "Cobble"


def sdk_build_inputs(work):
    lock = read_lock()
    validate_checkout(work / "src", lock["revision"])
    payload = native_payload()
    validate_sdk_source(work / "src", payload)
    validate_installed_files(work / "src", payload["overlay"])
    validate_patch_series(work / "src", sorted((ROOT / "chromium/patches").glob("*.patch")),
                          compare_worktree=True)
    validate_sdk_exports(work / "src")
    validate_sdk_history_policy(work / "src")
    return {"lock": lock, "native_payload": payload,
            "args_sha256": file_sha256(build_directory(work) / "args.gn")}


def sdk_binary_hashes(work, lock):
    app = build_directory(work) / "Chromium.app"
    paths = ["Contents/MacOS/Chromium",
             "Contents/Frameworks/Chromium Framework.framework/Versions/"
             + lock["version"] + "/Chromium Framework"]
    return {path: file_sha256(app / path) for path in paths}


def record_sdk_build(work, expected_inputs):
    """Record a successful full build or its validated packaging transition."""
    if sdk_build_inputs(work) != expected_inputs:
        raise ValueError("SDK inputs changed during compilation; rebuild before packaging")
    receipt = {"schema": 1, "inputs": expected_inputs,
               "binaries": sdk_binary_hashes(work, expected_inputs["lock"])}
    path = build_directory(work) / BUILD_RECEIPT
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def validate_sdk_build(work):
    path = build_directory(work) / BUILD_RECEIPT
    if not path.is_file():
        raise ValueError("No successful SDK build receipt; compile before packaging")
    receipt = json.loads(path.read_text())
    inputs = sdk_build_inputs(work)
    if (receipt.get("schema") != 1 or receipt.get("inputs") != inputs or
            receipt.get("binaries") != sdk_binary_hashes(work, inputs["lock"])):
        raise ValueError("SDK build receipt is stale; compile before packaging")
    return receipt


def refresh_packaged_build_receipt(work, validated_receipt):
    # Signing the outer app changes the launcher's embedded signature. This
    # transition requires a receipt validated before packaging; it cannot
    # establish the initial successful-build evidence.
    receipt = json.loads((build_directory(work) / BUILD_RECEIPT).read_text())
    if receipt != validated_receipt:
        raise ValueError("SDK build receipt changed during packaging")
    record_sdk_build(work, validated_receipt["inputs"])


def configure(work, variant):
    source = work / "src"
    if variant == "upstream" and (source / ".cobble-chromium-sdk.json").exists():
        raise ValueError("A patched SDK checkout cannot produce an upstream baseline")
    if variant == "sdk":
        patch_script = ROOT / "scripts" / "apply_chromium.py"
        if not patch_script.is_file():
            raise ValueError("SDK overlay has not been implemented; use upstream for build-host validation")
        apply(source, sdk_root=ROOT)
        validate_sdk_source(source, native_payload())
        validate_sdk_exports(source)
        validate_sdk_history_policy(source)
    output = build_directory(work)
    output.mkdir(parents=True, exist_ok=True)
    args = '\n'.join([
        'is_debug = false', 'is_component_build = false', 'is_official_build = true',
        'symbol_level = 0', 'blink_symbol_level = 0', 'v8_symbol_level = 0',
        'target_cpu = "arm64"', 'is_chrome_branded = false',
        # Xcode 27's SDK adds arm64e.x1 TAPI targets that Chromium 153's LLD 24
        # cannot parse. Apple's linker supports that SDK and remains incremental.
        'use_lld = false', 'use_thin_lto = false',
        'use_remoteexec = false', 'use_siso = false',
    ]) + '\n'
    (output / "args.gn").write_text(args)
    run(["gn", "gen", output], cwd=source, env=build_environment(work))


def probe_targets(listing, root=ROOT):
    sources = root / "chromium/overlay/chrome/browser/ui/cobble"
    expected = {path.stem + ".o" for path in sources.iterdir()
                if path.suffix in {".mm", ".cc", ".c"}}
    targets = [line.split(":", 1)[0] for line in listing.splitlines()
               if Path(line.split(":", 1)[0]).name in expected]
    found = {Path(target).name for target in targets}
    if not expected or found != expected or len(targets) != len(expected):
        raise ValueError("Native SDK object targets are missing or ambiguous: "
                         + ", ".join(sorted(expected - found)))
    return sorted(targets)


def compile_chrome(work, variant, jobs, minutes, probe=False):
    source = work / "src"
    output = build_directory(work)
    expected_inputs = sdk_build_inputs(work) if variant == "sdk" else None
    if expected_inputs and not probe:
        (output / BUILD_RECEIPT).unlink(missing_ok=True)
    targets = ["chrome"]
    if probe:
        # Target inspection does not regenerate Ninja's graph. New overlay
        # sources must reach the graph before discovering their object targets.
        run(["ninja", "-C", output, "build.ninja"],
            cwd=source, env=build_environment(work))
        listing = run(["ninja", "-C", output, "-t", "targets", "all"],
                      cwd=source, env=build_environment(work), capture=True)
        targets = probe_targets(listing)
    command = ["autoninja", "-C", str(output)]
    if probe:
        command.extend(["-k", "0"])
    command.extend([*targets, "-j", str(jobs)])
    print("+", " ".join(command), flush=True)
    process = subprocess.Popen(command, cwd=source, env=build_environment(work), start_new_session=True)
    try:
        deadline = time.monotonic() + minutes * 60
        while True:
            try:
                status = process.wait(timeout=min(30, max(0, deadline - time.monotonic())))
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    raise
                if shutil.disk_usage(work).free < 8 * 1024 ** 3:
                    raise ValueError("Build stopped at the 8 GiB disk floor; preserve and resume the checkpoint")
    except (subprocess.TimeoutExpired, ValueError, KeyboardInterrupt) as error:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if not isinstance(error, subprocess.TimeoutExpired):
            raise
        raise ValueError("Build time slice ended. Resume the saved source/object checkpoint; no artifact is release-ready.")
    if status:
        raise subprocess.CalledProcessError(status, command)
    if expected_inputs:
        if probe:
            if sdk_build_inputs(work) != expected_inputs:
                raise ValueError("SDK inputs changed during the native probe")
        else:
            record_sdk_build(work, expected_inputs)


def package(work, variant, lock, artifacts=None):
    output = build_directory(work)
    app = output / "Chromium.app"
    executable = app / "Contents" / "MacOS" / "Chromium"
    if not executable.is_file():
        raise ValueError("No built Chromium executable exists")
    embedded = None
    artifacts = Path(artifacts) if artifacts is not None else ROOT / "artifacts"
    name = f"{'cobble-sdk' if variant == 'sdk' else 'upstream-probe'}-{lock['version']}-arm64"
    if variant == "sdk":
        validated_receipt = validate_sdk_build(work)
        payload = native_payload()
        validate_sdk_source(work / "src", payload)
        validate_sdk_history_policy(work / "src")
        embedded = {"schema": 1, "lock": lock, "variant": variant,
                    "native_payload": payload,
                    "sdk_revision": sdk_revision(),
                    "release_ready": False}
        name += f"-{embedded['sdk_revision'][:12]}-{payload['sha256'][:12]}"
    archive = artifacts / (name + ".zip")
    metadata_path = artifacts / (name + ".json")
    if archive.exists() or archive.is_symlink() or metadata_path.exists() or metadata_path.is_symlink():
        raise ValueError("Packaged output already exists; choose a new --artifacts directory")
    artifacts.mkdir(parents=True, exist_ok=True)
    if embedded:
        resources = app / "Contents" / "Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / SDK_MANIFEST).write_text(
            json.dumps(embedded, indent=2, sort_keys=True) + "\n")
        for source, name in (
            (ROOT / "LICENSE", "CobbleChromiumSDK-LICENSE.txt"),
            (ROOT / "chromium/THIRD_PARTY_NOTICES.md", "CobbleChromiumSDK-NOTICES.md"),
            (work / "src/LICENSE", "Chromium-LICENSE.txt"),
        ):
            shutil.copyfile(source, resources / name)
        framework = app / "Contents/Frameworks/Chromium Framework.framework"
        helpers = framework / "Versions" / lock["version"] / "Helpers"
        # Locally built bundles carry linker signatures, not bundle resource
        # seals. Seal nested helper bundles before their containing framework.
        for bundle in [*sorted(helpers.glob("*.app")), framework, app]:
            run(["codesign", "--force", "--sign", "-",
                 "--preserve-metadata=entitlements,flags,runtime", bundle])
        run(["codesign", "--verify", "--deep", "--strict", app])
        refresh_packaged_build_receipt(work, validated_receipt)
    # Reserve the destination exclusively before invoking ditto, including
    # across different build work directories packaging into the same folder.
    with archive.open("xb"):
        pass
    try:
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
    except BaseException:
        archive.unlink(missing_ok=True)
        raise
    metadata = {"lock": lock, "variant": variant, "archive": archive.name,
                "sha256": file_sha256(archive), "release_ready": False,
                "validation": "Built artifact only. Native harness, signing and behavior gates pending."}
    if embedded:
        metadata.update(native_payload=embedded["native_payload"],
                        sdk_revision=embedded["sdk_revision"])
    with metadata_path.open("x") as stream:
        stream.write(json.dumps(metadata, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["verify", "preflight", "prepare", "configure", "probe", "compile", "package"])
    parser.add_argument("--work", type=Path, default=ROOT / "upstream")
    parser.add_argument("--variant", choices=["upstream", "sdk"], default="upstream")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--compile-minutes", type=int, default=260)
    parser.add_argument("--minimum-free-gib", type=int, default=100)
    parser.add_argument("--replace-sdk", action="store_true")
    parser.add_argument("--previous-sdk", type=Path)
    parser.add_argument("--artifacts", type=Path,
                        help="new output directory for immutable packaged archives")
    args = parser.parse_args()
    if args.artifacts is not None and args.stage != "package":
        parser.error("--artifacts is only valid for package")
    if args.stage == "probe" and args.variant != "sdk":
        parser.error("probe requires --variant sdk")
    lock = read_lock()
    work = args.work.resolve()
    if args.jobs < 1 or args.minimum_free_gib < 1 or args.compile_minutes < 1:
        parser.error("Resource limits must be positive")
    if args.stage == "verify":
        verify_tag(lock)
        return
    work.mkdir(parents=True, exist_ok=True)
    # Cooperating stage invocations share one lock; a second stage must not
    # modify source, GN files or receipts underneath a running compiler.
    with build_lock(work):
        if args.stage == "preflight": preflight(work, args.minimum_free_gib)
        elif args.stage == "prepare": prepare(work, lock, args.replace_sdk, args.previous_sdk)
        elif args.stage == "configure": configure(work, args.variant)
        elif args.stage == "probe": compile_chrome(work, args.variant, args.jobs, args.compile_minutes, probe=True)
        elif args.stage == "compile": compile_chrome(work, args.variant, args.jobs, args.compile_minutes)
        elif args.stage == "package": package(work, args.variant, lock, args.artifacts)



if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
