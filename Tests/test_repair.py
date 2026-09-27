import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).parents[1] / "scripts" / "repair.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("repair", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RepairTests(unittest.TestCase):
    def assert_rejected(self, responses, message, codex_calls,
                        lock_version="153.0.8000.1"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "failure.log"
            log.write_text("compiler failure")
            with (patch.object(MODULE, "ROOT", root),
                  patch.object(MODULE, "read_lock",
                               return_value={"version": lock_version}),
                  patch.object(MODULE, "run", side_effect=responses),
                  patch.object(MODULE.subprocess, "run") as codex):
                with self.assertRaisesRegex(SystemExit, message):
                    MODULE.main([str(log)])
                self.assertEqual(codex.call_count, codex_calls)

    def test_rejects_non_update_branch_before_codex(self):
        self.assert_rejected(["main\n"], "exact update", 0)

    def test_rejects_dirty_branch_before_codex(self):
        self.assert_rejected(
            ["update/chromium-153.0.8000.1\n", "?? notes.txt\n"],
            "Commit the verified", 0)

    def test_rejects_branch_that_does_not_match_lock_before_codex(self):
        self.assert_rejected(["update/chromium-153.0.8000.1\n"],
                             "must match", 0, lock_version="154.0.1.2")

    def test_rejects_out_of_scope_codex_change(self):
        for tracked, untracked in [("README.md\0", ""),
                                   ("", "notes.txt\0")]:
            self.assert_rejected(
                ["update/chromium-153.0.8000.1\n", "", "a" * 40,
                 "update/chromium-153.0.8000.1\n", "a" * 40,
                 tracked, untracked],
                "outside the native repair scope", 1)

    def test_rejects_codex_commit(self):
        self.assert_rejected(
            ["update/chromium-153.0.8000.1\n", "", "a" * 40,
             "update/chromium-153.0.8000.1\n", "b" * 40],
            "committed history", 1)

    def test_rejects_repaired_patch_with_incorrect_hunk_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patches = root / "chromium/patches"
            patches.mkdir(parents=True)
            (patches / "0001.patch").write_text(
                "diff --git a/value.txt b/value.txt\n"
                "--- a/value.txt\n+++ b/value.txt\n"
                "@@ -1 +1 @@\n-old\n+new\n+silently omitted\n")
            with (patch.object(MODULE, "changed_paths",
                               return_value=["chromium/patches/0001.patch"]),
                  patch.object(MODULE, "native_payload")):
                with self.assertRaisesRegex(ValueError, "hunk line counts"):
                    MODULE.validate_repair(root)

    def test_read_tail_bounds_the_diagnostic(self):
        class Stream(io.BytesIO):
            def read(self, size=-1):
                self.requested = size
                return super().read(size)

        stream = Stream(b"prefix" + b"x" * 100_000)
        fake_path = MagicMock()
        fake_path.open.return_value.__enter__.return_value = stream
        self.assertEqual(len(MODULE.read_tail(fake_path)), 100_000)
        self.assertEqual(stream.requested, 100_000)

    def run_metadata(self, **changes):
        metadata = {"repository": {"full_name": "owner/sdk"},
                    "path": ".github/workflows/chromium-build.yml",
                    "head_sha": "a" * 40, "status": "completed",
                    "conclusion": "failure", "run_attempt": 2,
                    "event": "workflow_dispatch", "id": 42}
        metadata.update(changes)
        return metadata

    def test_run_diagnostic_rejects_wrong_authenticated_metadata(self):
        cases = [
            {"repository": {"full_name": "other/sdk"}},
            {"path": ".github/workflows/other.yml"},
            {"head_sha": "b" * 40},
            {"status": "in_progress"},
            {"conclusion": "success"},
            {"event": "push"},
            {"id": 43},
        ]
        for changes in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                responses = ["owner/sdk\n", json.dumps(self.run_metadata(**changes))]
                with patch.object(MODULE, "run", side_effect=responses):
                    with self.assertRaisesRegex(ValueError, "not a failed Chromium build"):
                        MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_requires_receipt_and_sdk_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            responses = ["owner/sdk\n", json.dumps(self.run_metadata()), None]
            with patch.object(MODULE, "run", side_effect=responses):
                with self.assertRaisesRegex(ValueError, "no build-context"):
                    MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_accepts_matching_sdk_receipt_and_bounds_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def fake_run(args, **kwargs):
                if args[:3] == ["gh", "repo", "view"]:
                    return "owner/sdk\n"
                if args[:2] == ["gh", "api"]:
                    return json.dumps(self.run_metadata())
                destination = Path(args[args.index("--dir") + 1])
                logs = destination / "chromium-logs"
                logs.mkdir(parents=True)
                (logs / "probe.log").write_text("probe")
                (logs / "compile.log").write_bytes(b"prefix" + b"x" * 100_000)
                (logs / "build-context.json").write_text(json.dumps({
                    "schema": 1, "repository": "owner/sdk",
                    "sdk_revision": "a" * 40, "run_id": "42",
                    "run_attempt": 2,
                    "workflow": ".github/workflows/chromium-build.yml",
                    "variant": "sdk",
                }))

            with patch.object(MODULE, "run", side_effect=fake_run):
                diagnostic = MODULE.download_run_diagnostic(42, root, "a" * 40)
            self.assertEqual(diagnostic, "x" * 100_000)

    def test_run_diagnostic_rejects_absent_native_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def fake_run(args, **kwargs):
                if args[:3] == ["gh", "repo", "view"]:
                    return "owner/sdk\n"
                if args[:2] == ["gh", "api"]:
                    return json.dumps(self.run_metadata())
                destination = Path(args[args.index("--dir") + 1])
                logs = destination / "chromium-logs"
                logs.mkdir()
                (logs / "build-context.json").write_text(json.dumps({
                    "schema": 1, "repository": "owner/sdk",
                    "sdk_revision": "a" * 40, "run_id": "42",
                    "run_attempt": 2,
                    "workflow": ".github/workflows/chromium-build.yml",
                    "variant": "sdk",
                }))

            with patch.object(MODULE, "run", side_effect=fake_run):
                with self.assertRaisesRegex(ValueError, "no native repair diagnostic"):
                    MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_rejects_non_sdk_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def fake_run(args, **kwargs):
                if args[:3] == ["gh", "repo", "view"]:
                    return "owner/sdk\n"
                if args[:2] == ["gh", "api"]:
                    return json.dumps(self.run_metadata())
                destination = Path(args[args.index("--dir") + 1])
                logs = destination / "chromium-logs"
                logs.mkdir()
                (logs / "build-context.json").write_text(json.dumps({
                    "schema": 1, "repository": "owner/sdk",
                    "sdk_revision": "a" * 40, "run_id": "42",
                    "run_attempt": 2,
                    "workflow": ".github/workflows/chromium-build.yml",
                    "variant": "upstream",
                }))

            with patch.object(MODULE, "run", side_effect=fake_run):
                with self.assertRaisesRegex(ValueError, "receipt does not match"):
                    MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_rejects_stale_artifact_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "artifacts/ai-repair-run-42").mkdir(parents=True)
            responses = ["owner/sdk\n", json.dumps(self.run_metadata())]
            with patch.object(MODULE, "run", side_effect=responses):
                with self.assertRaisesRegex(ValueError, "already exists"):
                    MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_rejects_ambiguous_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def fake_run(args, **kwargs):
                if args[:3] == ["gh", "repo", "view"]:
                    return "owner/sdk\n"
                if args[:2] == ["gh", "api"]:
                    return json.dumps(self.run_metadata())
                destination = Path(args[args.index("--dir") + 1])
                context = json.dumps({"schema": 1})
                (destination / "build-context.json").write_text(context)
                (destination / "chromium-logs").mkdir()
                (destination / "chromium-logs/build-context.json").write_text(context)

            with patch.object(MODULE, "run", side_effect=fake_run):
                with self.assertRaisesRegex(ValueError, "build-context"):
                    MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_rejects_stale_receipt_identity(self):
        for changed in ({"sdk_revision": "b" * 40}, {"run_attempt": 1}):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)

                def fake_run(args, **kwargs):
                    if args[:3] == ["gh", "repo", "view"]:
                        return "owner/sdk\n"
                    if args[:2] == ["gh", "api"]:
                        return json.dumps(self.run_metadata())
                    destination = Path(args[args.index("--dir") + 1])
                    receipt = {"schema": 1, "repository": "owner/sdk",
                               "sdk_revision": "a" * 40, "run_id": "42",
                               "run_attempt": 2,
                               "workflow": ".github/workflows/chromium-build.yml",
                               "variant": "sdk", **changed}
                    (destination / "build-context.json").write_text(json.dumps(receipt))

                with patch.object(MODULE, "run", side_effect=fake_run):
                    with self.assertRaisesRegex(ValueError, "receipt does not match"):
                        MODULE.download_run_diagnostic(42, root, "a" * 40)

    def test_run_diagnostic_rejects_symlinked_log_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside"
            outside.mkdir()

            def fake_run(args, **kwargs):
                if args[:3] == ["gh", "repo", "view"]:
                    return "owner/sdk\n"
                if args[:2] == ["gh", "api"]:
                    return json.dumps(self.run_metadata())
                destination = Path(args[args.index("--dir") + 1])
                (destination / "chromium-logs").symlink_to(outside, target_is_directory=True)
                (outside / "build-context.json").write_text("{}")
                (outside / "compile.log").write_text("outside")

            with patch.object(MODULE, "run", side_effect=fake_run):
                with self.assertRaisesRegex(ValueError, "build-context"):
                    MODULE.download_run_diagnostic(42, root, "a" * 40)


if __name__ == "__main__":
    unittest.main()
