#!/usr/bin/env python3
"""Discover a released stable Mac version and verify its official Git tag.

Default is read-only. --write updates the lock atomically; a workflow then opens
a review branch. This script never merges, publishes a runtime, or edits patches.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

from build import ROOT, read_lock, verify_tag

RELEASES = "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=10"
MAX_RELEASE_BYTES = 1_000_000


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", value):
        raise ValueError("Invalid version in release feed")
    return tuple(map(int, value.split(".")))


def candidate(current, releases, now):
    eligible = []
    if not isinstance(releases, list):
        raise ValueError("Invalid release feed")
    for release in releases:
        if not isinstance(release, dict):
            raise ValueError("Invalid release in feed")
        if release.get("channel") != "Stable" or release.get("platform") != "Mac":
            continue
        published = release.get("time")
        if (isinstance(published, bool) or not isinstance(published, (int, float))
                or not math.isfinite(published) or published > now.timestamp() * 1000):
            continue
        version_tuple(release.get("version"))
        hashes = release.get("hashes")
        if not isinstance(hashes, dict):
            raise ValueError("Invalid release hashes in feed")
        revision = hashes.get("chromium", "")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Invalid Chromium revision in release feed")
        eligible.append(release)
    if not eligible:
        raise ValueError("No published stable Mac releases in feed")
    # A withdrawn/short-lived higher version can remain in the history. The
    # latest publication wins; version ordering only breaks a timestamp tie.
    release = max(eligible, key=lambda item: (item["time"], version_tuple(item["version"])))
    if version_tuple(release["version"]) < version_tuple(current["version"]):
        raise ValueError("Release feed would downgrade the engine")
    revision = release["hashes"]["chromium"]
    if release["version"] == current["version"]:
        if revision != current["revision"]:
            raise ValueError("Published revision changed for the existing version")
        return None
    return {**current, "version": release["version"], "revision": revision,
            "verified_at": now.date().isoformat()}


def discover(current, version=None):
    with urllib.request.urlopen(RELEASES, timeout=30) as response:
        data = response.read(MAX_RELEASE_BYTES + 1)
    if len(data) > MAX_RELEASE_BYTES:
        raise ValueError("Release feed is too large")
    releases = json.loads(data)
    if version is not None:
        version_tuple(version)
        releases = [item for item in releases
                    if isinstance(item, dict) and item.get("version") == version]
    proposed = candidate(current, releases, datetime.datetime.now(datetime.timezone.utc))
    if proposed:
        verify_tag(proposed)
    return proposed


def write_lock(path, proposed):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(proposed, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--version", help="Select an announced stable Mac version from the feed")
    args = parser.parse_args()
    current = read_lock()
    proposed = discover(current, args.version)
    if proposed is None:
        print(f"Already on released stable Chromium {current['version']}")
        return
    print(f"Verified update: {current['version']} -> {proposed['version']} ({proposed['revision']})")
    if args.write:
        write_lock(ROOT / "chromium.lock.json", proposed)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
