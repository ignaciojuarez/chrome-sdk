import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parents[1] / "scripts" / "apply_chromium.py"
SPEC = importlib.util.spec_from_file_location("apply_chromium", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ApplyChromiumTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.sdk = root / "sdk"
        self.source = root / "src"
        (self.sdk / "chromium/overlay/chrome/cobble").mkdir(parents=True)
        (self.sdk / "chromium/patches").mkdir(parents=True)
        (self.source / "chrome").mkdir(parents=True)
        (self.source / "chrome/value.txt").write_text("upstream\n")
        subprocess.run(["git", "init", "-q"], cwd=self.source, check=True)
        subprocess.run(["git", "config", "user.name", "SDK Test"],
                       cwd=self.source, check=True)
        subprocess.run(["git", "config", "user.email",
                        "sdk-test@example.invalid"], cwd=self.source,
                       check=True)
        subprocess.run(["git", "add", "."], cwd=self.source, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.source,
                       check=True)
        revision = subprocess.run(["git", "rev-parse", "HEAD"],
                                  cwd=self.source, check=True, text=True,
                                  stdout=subprocess.PIPE).stdout.strip()
        (self.sdk / "chromium.lock.json").write_text(
            json.dumps({"revision": revision}))
        (self.sdk / "chromium/overlay/chrome/cobble/bridge.h").write_text(
            "first\n")
        (self.sdk / "chromium/patches/0001.patch").write_text(
            """diff --git a/chrome/value.txt b/chrome/value.txt
--- a/chrome/value.txt
+++ b/chrome/value.txt
@@ -1 +1 @@
-upstream
+patched
""")

    def tearDown(self):
        self.temporary.cleanup()

    def test_apply_is_idempotent_and_updates_unchanged_overlay(self):
        MODULE.apply(self.source, self.sdk)
        MODULE.apply(self.source, self.sdk)
        installed = self.source / "chrome/cobble/bridge.h"
        self.assertEqual(installed.read_text(), "first\n")
        (self.sdk / "chromium/overlay/chrome/cobble/bridge.h").write_text(
            "second\n")
        MODULE.apply(self.source, self.sdk)
        self.assertEqual(installed.read_text(), "second\n")

    def test_rejects_wrong_revision_and_changed_installed_overlay(self):
        lock = self.sdk / "chromium.lock.json"
        lock.write_text(json.dumps({"revision": "0" * 40}))
        with self.assertRaisesRegex(ValueError, "does not match lock"):
            MODULE.apply(self.source, self.sdk)
        revision = subprocess.run(["git", "rev-parse", "HEAD"],
                                  cwd=self.source, check=True, text=True,
                                  stdout=subprocess.PIPE).stdout.strip()
        lock.write_text(json.dumps({"revision": revision}))
        MODULE.apply(self.source, self.sdk)
        (self.source / "chrome/cobble/bridge.h").write_text("local edit\n")
        with self.assertRaisesRegex(ValueError, "was changed"):
            MODULE.apply(self.source, self.sdk)

    def test_patch_context_mismatch_changes_nothing(self):
        (self.source / "chrome/value.txt").write_text("different\n")
        subprocess.run(["git", "add", "."], cwd=self.source, check=True)
        subprocess.run(["git", "commit", "-qm", "different"],
                       cwd=self.source, check=True)
        revision = subprocess.run(["git", "rev-parse", "HEAD"],
                                  cwd=self.source, check=True, text=True,
                                  stdout=subprocess.PIPE).stdout.strip()
        (self.sdk / "chromium.lock.json").write_text(
            json.dumps({"revision": revision}))
        with self.assertRaises(subprocess.CalledProcessError):
            MODULE.apply(self.source, self.sdk)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "different\n")
        self.assertFalse((self.source / "chrome/cobble/bridge.h").exists())

    def test_rejects_malformed_hunks_before_dropping_lines(self):
        patch_path = self.sdk / "chromium/patches/0001.patch"
        patch_path.write_text(
            """diff --git a/chrome/value.txt b/chrome/value.txt
--- a/chrome/value.txt
+++ b/chrome/value.txt
@@ -1 +1 @@
-upstream
+patched
+silently ignored without validation
""")
        with self.assertRaisesRegex(ValueError, "hunk line counts"):
            MODULE.apply(self.source, self.sdk)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "upstream\n")

    def test_dependent_patch_series_is_preflighted_in_order(self):
        (self.sdk / "chromium/patches/0002.patch").write_text(
            """diff --git a/chrome/value.txt b/chrome/value.txt
--- a/chrome/value.txt
+++ b/chrome/value.txt
@@ -1 +1 @@
-patched
+twice-patched
""")
        MODULE.apply(self.source, self.sdk)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "twice-patched\n")
        MODULE.apply(self.source, self.sdk)

    def test_idempotent_apply_rejects_changed_patched_source(self):
        MODULE.apply(self.source, self.sdk)
        (self.source / "chrome/value.txt").write_text("manual edit\n")
        with self.assertRaises(subprocess.CalledProcessError):
            MODULE.apply(self.source, self.sdk)

    def test_replace_preserves_unmanaged_files_and_can_be_reapplied(self):
        MODULE.apply(self.source, self.sdk)
        generated = self.source / "out/Default/generated.txt"
        generated.parent.mkdir(parents=True)
        generated.write_text("keep\n")
        (self.sdk / "chromium/patches/0001.patch").write_text(
            """diff --git a/chrome/value.txt b/chrome/value.txt
--- a/chrome/value.txt
+++ b/chrome/value.txt
@@ -1 +1 @@
-upstream
+replacement
""")

        MODULE.apply(self.source, self.sdk, replace=True)
        MODULE.apply(self.source, self.sdk)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "replacement\n")
        self.assertEqual(generated.read_text(), "keep\n")

    def test_replace_rejects_unmanaged_tracked_change_without_mutation(self):
        extra = self.source / "chrome/extra.txt"
        extra.write_text("base\n")
        subprocess.run(["git", "add", "."], cwd=self.source, check=True)
        subprocess.run(["git", "commit", "-qm", "extra"], cwd=self.source,
                       check=True)
        revision = subprocess.run(["git", "rev-parse", "HEAD"],
                                  cwd=self.source, check=True, text=True,
                                  stdout=subprocess.PIPE).stdout.strip()
        (self.sdk / "chromium.lock.json").write_text(
            json.dumps({"revision": revision}))
        MODULE.apply(self.source, self.sdk)
        extra.write_text("local\n")
        (self.sdk / "chromium/patches/0001.patch").write_text(
            (self.sdk / "chromium/patches/0001.patch").read_text().replace(
                "+patched", "+replacement"))

        with self.assertRaises(subprocess.CalledProcessError):
            MODULE.apply(self.source, self.sdk, replace=True)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "patched\n")
        self.assertEqual(extra.read_text(), "local\n")

    def test_legacy_replace_requires_matching_previous_sdk(self):
        MODULE.apply(self.source, self.sdk)
        previous = Path(self.temporary.name) / "previous-sdk"
        shutil.copytree(self.sdk, previous)
        stamp = self.source / MODULE.STAMP
        installed = json.loads(stamp.read_text())
        installed["schema"] = 1
        installed.pop("patch_texts")
        stamp.write_text(json.dumps(installed))
        (self.sdk / "chromium/patches/0001.patch").write_text(
            (self.sdk / "chromium/patches/0001.patch").read_text().replace(
                "+patched", "+replacement"))

        with self.assertRaisesRegex(ValueError, "--previous-sdk"):
            MODULE.apply(self.source, self.sdk, replace=True)
        MODULE.apply(self.source, self.sdk, replace=True,
                     previous_sdk=previous)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "replacement\n")

    def test_replace_preserves_legacy_malformed_patch_semantics(self):
        patch_path = self.sdk / "chromium/patches/0001.patch"
        old_text = """diff --git a/chrome/value.txt b/chrome/value.txt
--- a/chrome/value.txt
+++ b/chrome/value.txt
@@ -1 +1 @@
-upstream
+patched
+previously ignored
"""
        patch_path.write_text(old_text)
        subprocess.run(["git", "apply", str(patch_path)], cwd=self.source,
                       check=True)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "patched\n")
        overlay = self.sdk / "chromium/overlay"
        installed_overlay = MODULE.manifest(overlay)
        destination = self.source / "chrome/cobble/bridge.h"
        destination.parent.mkdir(parents=True)
        shutil.copyfile(overlay / "chrome/cobble/bridge.h", destination)
        (self.source / MODULE.STAMP).write_text(json.dumps({
            "schema": 2,
            "revision": subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=self.source, check=True,
                text=True, stdout=subprocess.PIPE).stdout.strip(),
            "patches": {patch_path.name: MODULE.digest(patch_path)},
            "patch_texts": {patch_path.name: old_text},
            "overlay": installed_overlay,
        }))
        patch_path.write_text(old_text.replace("+1 @@", "+1,2 @@"))

        MODULE.apply(self.source, self.sdk, replace=True)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "patched\npreviously ignored\n")

    def test_replace_rolls_back_if_applying_new_series_fails(self):
        MODULE.apply(self.source, self.sdk)
        original_stamp = (self.source / MODULE.STAMP).read_bytes()
        first = self.sdk / "chromium/patches/0001.patch"
        first.write_text(first.read_text().replace("+patched", "+replacement"))
        second = self.sdk / "chromium/patches/0002.patch"
        second.write_text(
            """diff --git a/chrome/value.txt b/chrome/value.txt
--- a/chrome/value.txt
+++ b/chrome/value.txt
@@ -1 +1 @@
-replacement
+final
""")
        real_run = MODULE.run
        failed = False

        def fail_second_apply(args, cwd, capture=False, env=None):
            nonlocal failed
            if (not failed and env is None and len(args) == 3
                    and args[:2] == ["git", "apply"]
                    and Path(args[-1]).name == "0002.patch"):
                failed = True
                raise subprocess.CalledProcessError(1, args)
            return real_run(args, cwd, capture=capture, env=env)

        with patch.object(MODULE, "run", side_effect=fail_second_apply):
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE.apply(self.source, self.sdk, replace=True)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "patched\n")
        self.assertEqual((self.source / MODULE.STAMP).read_bytes(),
                         original_stamp)

    def test_replace_rolls_back_patches_and_overlay_if_swap_fails(self):
        second = self.sdk / "chromium/overlay/chrome/cobble/second.h"
        second.write_text("old second\n")
        MODULE.apply(self.source, self.sdk)
        original_stamp = (self.source / MODULE.STAMP).read_bytes()
        (self.sdk / "chromium/overlay/chrome/cobble/bridge.h").write_text(
            "new first\n")
        second.write_text("new second\n")
        patch_file = self.sdk / "chromium/patches/0001.patch"
        patch_file.write_text(patch_file.read_text().replace(
            "+patched", "+replacement"))
        real_replace = MODULE.os.replace
        swaps = 0

        def fail_second_overlay_swap(source, destination):
            nonlocal swaps
            if Path(destination).name in ("bridge.h", "second.h"):
                swaps += 1
                if swaps == 2:
                    raise OSError("injected overlay swap failure")
            return real_replace(source, destination)

        with patch.object(MODULE.os, "replace",
                          side_effect=fail_second_overlay_swap):
            with self.assertRaisesRegex(OSError, "injected"):
                MODULE.apply(self.source, self.sdk, replace=True)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "patched\n")
        self.assertEqual(
            (self.source / "chrome/cobble/bridge.h").read_text(), "first\n")
        self.assertEqual(
            (self.source / "chrome/cobble/second.h").read_text(),
            "old second\n")
        self.assertEqual((self.source / MODULE.STAMP).read_bytes(),
                         original_stamp)

    def test_unmanaged_overlay_collision_rolls_back_new_patches(self):
        MODULE.apply(self.source, self.sdk)
        original_stamp = (self.source / MODULE.STAMP).read_bytes()
        collision = self.source / "chrome/cobble/new.h"
        collision.write_text("unmanaged\n")
        (self.sdk / "chromium/overlay/chrome/cobble/new.h").write_text(
            "managed\n")
        patch_file = self.sdk / "chromium/patches/0001.patch"
        patch_file.write_text(patch_file.read_text().replace(
            "+patched", "+replacement"))

        with self.assertRaisesRegex(ValueError, "unmanaged"):
            MODULE.apply(self.source, self.sdk, replace=True)
        self.assertEqual((self.source / "chrome/value.txt").read_text(),
                         "patched\n")
        self.assertEqual(collision.read_text(), "unmanaged\n")
        self.assertEqual((self.source / MODULE.STAMP).read_bytes(),
                         original_stamp)


if __name__ == "__main__":
    unittest.main()
