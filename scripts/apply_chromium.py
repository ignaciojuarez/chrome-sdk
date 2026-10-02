#!/usr/bin/env python3
"""Apply the pinned Cobble overlay to an exact Chromium checkout."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
STAMP = ".cobble-chromium-sdk.json"


@contextmanager
def build_lock(work):
    """All command-line source/build writers use the same nonblocking lease."""
    with (work / ".cobble-build.lock").open("a") as writer:
        try:
            fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another build stage is already writing this work directory")
        yield


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def run(args, cwd, capture=False, env=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None,
                          env=env).stdout


def manifest(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Overlay may not contain symlinks: {path}")
        if path.is_file():
            result[str(path.relative_to(directory))] = digest(path)
    return result


def patch_texts(patches):
    return {patch.name: patch.read_text(encoding="utf-8") for patch in patches}


def safe_relative(value):
    path = Path(value)
    return not path.is_absolute() and ".." not in path.parts and value != ""


def validate_checkout(source, revision):
    if not (source / ".git").exists() or not (source / "chrome").is_dir():
        raise ValueError("Not a Chromium source checkout")
    head = run(["git", "rev-parse", "HEAD"], source, capture=True).strip()
    if head != revision:
        raise ValueError(f"Chromium HEAD {head} does not match lock {revision}")


def validate_installed_files(source, installed):
    for relative, expected in installed.items():
        if not safe_relative(relative):
            raise ValueError("Invalid path in installed overlay stamp")
        path = source / relative
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ValueError(f"Installed overlay was changed: {relative}")


def validate_patch_series(source, patches, compare_worktree=False):
    """Apply the series to a temporary index, leaving the checkout untouched."""
    with tempfile.TemporaryDirectory() as directory:
        environment = os.environ.copy()
        environment["GIT_INDEX_FILE"] = str(Path(directory) / "index")
        temporary_objects = Path(directory) / "objects"
        temporary_objects.mkdir()
        source_objects = Path(run(["git", "rev-parse", "--git-path", "objects"],
                                  source, capture=True).strip())
        if not source_objects.is_absolute():
            source_objects = source / source_objects
        environment["GIT_OBJECT_DIRECTORY"] = str(temporary_objects)
        environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = str(
            source_objects.resolve())
        run(["git", "read-tree", "HEAD"], source, env=environment)
        for patch in patches:
            run(["git", "apply", "--cached", str(patch)], source,
                capture=True, env=environment)
        run(["git", "diff", "--cached", "--check"], source,
            capture=True, env=environment)
        if compare_worktree:
            run(["git", "diff", "--quiet"], source, capture=True,
                env=environment)


def validate_patch_counts(source, patches):
    for patch in patches:
        recorded = run(["git", "apply", "--numstat", str(patch)], source,
                       capture=True)
        recounted = run(
            ["git", "apply", "--recount", "--numstat", str(patch)],
            source, capture=True)
        if recorded != recounted:
            raise ValueError(f"Patch hunk line counts are wrong: {patch.name}")


def archived_patches(installed, previous_sdk, directory):
    expected = installed.get("patches")
    if not isinstance(expected, dict):
        raise ValueError("Installed patch manifest is invalid")
    texts = installed.get("patch_texts")
    if texts is None:
        if previous_sdk is None:
            raise ValueError("Legacy stamp replacement requires --previous-sdk")
        old_paths = sorted((previous_sdk / "chromium" / "patches").glob("*.patch"))
        if {path.name: digest(path) for path in old_paths} != expected:
            raise ValueError("Previous SDK patches do not match the installed stamp")
        texts = patch_texts(old_paths)
    if not isinstance(texts, dict) or set(texts) != set(expected):
        raise ValueError("Installed patch archive is invalid")

    paths = []
    for name in sorted(texts):
        if Path(name).name != name or not name.endswith(".patch"):
            raise ValueError("Installed patch archive contains an invalid name")
        text = texts[name]
        if not isinstance(text, str) or hashlib.sha256(text.encode()).hexdigest() != expected[name]:
            raise ValueError(f"Installed patch archive changed: {name}")
        path = directory / name
        path.write_text(text, encoding="utf-8")
        paths.append(path)
    return paths


def replace_patches(source, installed, desired, previous_sdk=None,
                    after_apply=None):
    with tempfile.TemporaryDirectory() as directory:
        old = archived_patches(installed, previous_sdk, Path(directory))
        validate_patch_series(source, old, compare_worktree=True)
        validate_patch_series(source, desired)

        reversed_old = []
        applied_new = []
        try:
            for patch in reversed(old):
                run(["git", "apply", "--reverse", str(patch)], source)
                reversed_old.append(patch)
            run(["git", "diff", "--quiet"], source, capture=True)
            for patch in desired:
                run(["git", "apply", str(patch)], source)
                applied_new.append(patch)
            validate_patch_series(source, desired, compare_worktree=True)
            if after_apply:
                after_apply()
        except Exception:
            for patch in reversed(applied_new):
                run(["git", "apply", "--reverse", str(patch)], source)
            for patch in reversed(reversed_old):
                run(["git", "apply", str(patch)], source)
            raise


def copy_overlay(source, overlay, previous, desired):
    validate_installed_files(source, previous)
    changed = {relative for relative, expected in desired.items()
               if previous.get(relative) != expected}
    removed = previous.keys() - desired.keys()
    staged = {}
    backups = {}
    swapped = []
    try:
        for relative in desired:
            if relative not in changed:
                continue  # Keep unchanged headers' mtimes and incremental objects.
            destination = source / relative
            if relative not in previous and destination.exists():
                raise ValueError(f"Refusing to replace unmanaged file: {relative}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            descriptor, name = tempfile.mkstemp(
                prefix=".cobble-new-", dir=destination.parent)
            os.close(descriptor)
            temporary = Path(name)
            shutil.copyfile(overlay / relative, temporary)
            staged[relative] = temporary
        for relative in previous:
            if relative not in changed and relative not in removed:
                continue
            destination = source / relative
            descriptor, name = tempfile.mkstemp(
                prefix=".cobble-old-", dir=destination.parent)
            os.close(descriptor)
            backup = Path(name)
            shutil.copyfile(destination, backup)
            backups[relative] = backup
        for relative, temporary in staged.items():
            os.replace(temporary, source / relative)
            swapped.append(relative)
        for relative in removed:
            (source / relative).unlink()
    except Exception:
        for relative in set(swapped) - previous.keys():
            (source / relative).unlink(missing_ok=True)
        for relative, backup in backups.items():
            os.replace(backup, source / relative)
        raise
    finally:
        for temporary in [*staged.values(), *backups.values()]:
            temporary.unlink(missing_ok=True)


def apply(source, sdk_root=ROOT, replace=False, previous_sdk=None):
    source = source.resolve()
    lock = json.loads((sdk_root / "chromium.lock.json").read_text())
    revision = lock["revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid Chromium revision in lock")
    validate_checkout(source, revision)

    overlay = sdk_root / "chromium" / "overlay"
    patches = sorted((sdk_root / "chromium" / "patches").glob("*.patch"))
    if not overlay.is_dir() or not patches:
        raise ValueError("Chromium overlay or patches are missing")
    validate_patch_counts(source, patches)
    desired_overlay = manifest(overlay)
    desired_patches = {patch.name: digest(patch) for patch in patches}
    stamp_path = source / STAMP

    if stamp_path.exists():
        if stamp_path.is_symlink():
            raise ValueError("Overlay stamp may not be a symlink")
        installed = json.loads(stamp_path.read_text())
        if installed.get("schema") not in (1, 2) or installed.get("revision") != revision:
            raise ValueError("Installed overlay stamp does not match the lock")
        if installed.get("patches") != desired_patches:
            if not replace:
                raise ValueError("Patch set changed; pass --replace with a verified checkpoint")
            replace_patches(
                source, installed, patches, previous_sdk,
                after_apply=lambda: copy_overlay(
                    source, overlay, installed.get("overlay", {}),
                    desired_overlay))
        else:
            validate_patch_series(source, patches, compare_worktree=True)
            copy_overlay(source, overlay, installed.get("overlay", {}),
                         desired_overlay)
    else:
        dirty = run(["git", "status", "--porcelain", "--untracked-files=no"],
                    source, capture=True).strip()
        if dirty:
            raise ValueError("Refusing to patch a modified Chromium checkout")
        # Validate the complete, ordered series against a temporary git index
        # before changing the checkout. Later patches may depend on earlier
        # ones, as long as every step applies exactly to the pinned revision.
        validate_patch_series(source, patches)
        for patch in patches:
            run(["git", "apply", str(patch)], source)
        copy_overlay(source, overlay, {}, desired_overlay)

    stamp = {"schema": 2, "revision": revision,
             "patches": desired_patches, "patch_texts": patch_texts(patches),
             "overlay": desired_overlay}
    temporary = stamp_path.with_name(STAMP + ".new")
    temporary.write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, stamp_path)
    print(f"Applied Cobble Chromium SDK overlay to {revision}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--replace", action="store_true",
                        help="replace a verified installed patch set")
    parser.add_argument("--previous-sdk", type=Path,
                        help="SDK tree matching a legacy schema-1 stamp")
    args = parser.parse_args()
    if args.previous_sdk and not args.replace:
        parser.error("--previous-sdk requires --replace")
    with build_lock(args.source.resolve().parent):
        apply(args.source, replace=args.replace, previous_sdk=args.previous_sdk)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
