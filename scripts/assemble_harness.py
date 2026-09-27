#!/usr/bin/env python3
"""Assemble an isolated native harness from a built SDK Chromium.app.

This is a local ad-hoc-signed test bundle, not a distributable signed release.
The input must contain the exact pinned framework and SDK exports.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid

from build import (ROOT, SDK_MANIFEST, native_payload, read_lock,
                   required_sdk_exports, run)


def validate_embedded_manifest(source, lock, expected_payload=None):
    manifest_path = source / "Contents" / "Resources" / SDK_MANIFEST
    if not manifest_path.is_file():
        raise ValueError("Input app has no embedded SDK provenance manifest")
    embedded = json.loads(manifest_path.read_text())
    expected_payload = expected_payload or native_payload()
    if (embedded.get("schema") != 1 or embedded.get("lock") != lock or
            embedded.get("variant") != "sdk" or
            not re.fullmatch(r"[0-9a-f]{40}",
                             embedded.get("sdk_revision", "")) or
            embedded.get("native_payload") != expected_payload):
        raise ValueError("Input app native payload differs from this SDK checkout")
    return embedded


def assemble(source, output):
    lock = read_lock()
    source = source.resolve()
    output = output.resolve()
    if output.exists():
        raise ValueError("Output already exists; choose a new harness path")
    info_path = source / "Contents" / "Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleShortVersionString") != lock["version"]:
        raise ValueError("Input app version differs from the source lock")
    run(["codesign", "--verify", "--deep", "--strict", source])
    validate_embedded_manifest(source, lock)
    binary = source / "Contents" / "Frameworks" / "Chromium Framework.framework" / "Versions" / lock["version"] / "Chromium Framework"
    exports = run(["nm", "-gU", binary], capture=True)
    symbols = {line.split()[-1] for line in exports.splitlines() if line.split()}
    missing = sorted(required_sdk_exports() - symbols)
    if missing:
        raise ValueError("Input is missing required SDK exports: " + ", ".join(missing))
    run(["swift", "build", "--configuration", "release", "--product", "CobbleChromiumClient"], cwd=ROOT)
    products = run(["swift", "build", "--configuration", "release", "--show-bin-path"], cwd=ROOT, capture=True).strip()
    client = Path(products) / "libCobbleChromiumClient.dylib"
    if not client.is_file():
        raise ValueError("Native harness client library was not produced")
    output.parent.mkdir(parents=True, exist_ok=True)
    run(["ditto", source, output])
    destination = output / "Contents" / "Frameworks" / "CobbleChromiumClient.dylib"
    run(["ditto", client, destination])
    info["CFBundleIdentifier"] = "com.ignacio.cobble.chromium-harness"
    info["CFBundleName"] = "Cobble Chromium Harness"
    info["CFBundleDisplayName"] = "Cobble Chromium Harness"
    info["CrProductDirName"] = f"Cobble Chromium Harness/{uuid.uuid4()}"
    info.pop("CFBundleURLTypes", None)
    with (output / "Contents" / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    # Preserve the engine/helper signatures and entitlements. Only the new
    # client and changed outer bundle need a local testing signature.
    run(["codesign", "--force", "--sign", "-", destination])
    run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,flags,runtime", output])
    run(["codesign", "--verify", "--deep", "--strict", output])
    print(f"Harness assembled: {output}")
    print("Run Contents/MacOS/Chromium. The harness has a unique isolated profile root; no user profile is reused.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chromium_app", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "Cobble Chromium Harness.app")
    args = parser.parse_args()
    assemble(args.chromium_app, args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
