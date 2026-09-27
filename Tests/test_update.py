import datetime
import fcntl
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build import (BUILD_RECEIPT, bootstrap_depot_tools, build_directory,
                   compile_chrome, native_payload, package, read_lock, record_sdk_build,
                   validate_sdk_build,
                   validate_sdk_exports, validate_sdk_history_policy,
                   validate_sdk_source, verify_tag)
from assemble_harness import validate_embedded_manifest
from update import MAX_RELEASE_BYTES, candidate, discover, write_lock


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.current = read_lock()
        # Stable fixture, independent of the repository's advancing live pin.
        self.current.update(version="152.0.7977.83", revision="7" * 40)
        self.now = datetime.datetime(2026, 9, 6, tzinfo=datetime.timezone.utc)

    def release(self, version="153.0.8000.1", **overrides):
        return {"channel": "Stable", "platform": "Mac", "version": version,
                "time": self.now.timestamp() * 1000 - 1000,
                "hashes": {"chromium": "a" * 40}, **overrides}

    def test_future_beta_and_other_platform_are_not_updates(self):
        with self.assertRaisesRegex(ValueError, "No published"):
            candidate(self.current, [self.release(channel="Beta"), self.release(platform="Win"),
                       self.release(time=self.now.timestamp() * 1000 + 1)], self.now)

    def test_downgrade_and_rewritten_revision_are_rejected(self):
        for release in [self.release("151.0.1.1"), self.release(self.current["version"])]:
            with self.assertRaises(ValueError):
                candidate(self.current, [release], self.now)

    def test_untrusted_version_and_revision_are_rejected(self):
        for release in [self.release("153.0.1.1;echo secret"),
                        self.release(hashes={"chromium": "$(cat ~/.codex/auth.json)"})]:
            with self.assertRaises(ValueError):
                candidate(self.current, [release], self.now)

    def test_malformed_and_nonfinite_feed_records_are_rejected(self):
        for releases in [[None], [self.release(hashes=None)],
                         [self.release(time=float("nan"))]]:
            with self.assertRaises(ValueError):
                candidate(self.current, releases, self.now)

    def test_current_version_is_noop_and_order_does_not_matter(self):
        same = self.release(self.current["version"], hashes={"chromium": self.current["revision"]})
        self.assertIsNone(candidate(self.current, [same], self.now))
        proposal = candidate(self.current, [self.release(), self.release("152.0.7999.1"), same], self.now)
        self.assertEqual(proposal["version"], "153.0.8000.1")
        self.assertEqual(proposal["depot_tools_revision"], self.current["depot_tools_revision"])
        self.assertEqual(self.current["version"], "152.0.7977.83")

    def test_git_tag_must_match_exact_pin(self):
        for revision in ["b" * 40, self.current["revision"]]:
            response = io.BytesIO(b")]}'\n" + json.dumps({"commit": revision}).encode())
            with patch("build.urllib.request.urlopen", return_value=response):
                if revision == self.current["revision"]:
                    verify_tag(self.current)
                else:
                    with self.assertRaises(ValueError):
                        verify_tag(self.current)

    def test_explicit_release_avoids_early_stable(self):
        releases = [self.release("154.0.1.1"), self.release("153.0.1.1")]
        with patch("update.urllib.request.urlopen", return_value=io.BytesIO(json.dumps(releases).encode())), patch("update.verify_tag"):
            self.assertEqual(discover(self.current, "153.0.1.1")["version"], "153.0.1.1")
        with patch("update.urllib.request.urlopen", return_value=io.BytesIO(json.dumps(releases).encode())):
            with self.assertRaisesRegex(ValueError, "No published"):
                discover(self.current, "155.0.1.1")

    def test_release_feed_read_is_bounded(self):
        response = io.BytesIO(b" " * (MAX_RELEASE_BYTES + 1))
        with patch("update.urllib.request.urlopen", return_value=response):
            with self.assertRaisesRegex(ValueError, "too large"):
                discover(self.current)

    def test_old_higher_version_does_not_override_current_release(self):
        same = self.release(self.current["version"], hashes={"chromium": self.current["revision"]})
        historical = self.release(time=self.now.timestamp() * 1000 - 86400000)
        self.assertIsNone(candidate(self.current, [historical, same], self.now))

    def test_atomic_failure_preserves_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock.json"
            path.write_text(json.dumps(self.current))
            original = path.read_bytes()
            with patch("update.os.replace", side_effect=OSError("disk error")), self.assertRaises(OSError):
                write_lock(path, {**self.current, "version": "153.0.1.1"})
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_depot_tools_bootstrap_requires_managed_python(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            depot = work / "depot_tools"
            depot.mkdir()
            with patch("build.run") as run:
                with self.assertRaisesRegex(ValueError, "Python pointer"):
                    bootstrap_depot_tools(work, {})
                run.assert_called_once_with(
                    [depot / "ensure_bootstrap"], cwd=depot, env={})

            relative = Path("bootstrap-python") / "python3" / "bin"
            (depot / relative).mkdir(parents=True)
            (depot / relative / "python3").touch()
            (depot / "python3_bin_reldir.txt").write_text(str(relative))
            with patch("build.run"):
                bootstrap_depot_tools(work, {})

    def test_native_payload_fingerprint_detects_stale_build_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            overlay = root / "chromium/overlay/chrome/cobble"
            patches = root / "chromium/patches"
            overlay.mkdir(parents=True)
            patches.mkdir(parents=True)
            (overlay / "bridge.h").write_text("bridge\n")
            (patches / "0001.patch").write_text("patch\n")
            payload = native_payload(root)
            self.assertEqual(len(payload["sha256"]), 64)
            (root / "unrelated.txt").write_text("ignored\n")
            self.assertEqual(native_payload(root), payload)

            source = root / "source"
            source.mkdir()
            (source / ".cobble-chromium-sdk.json").write_text(json.dumps({
                "patches": payload["patches"],
                "overlay": payload["overlay"],
            }))
            validate_sdk_source(source, payload)
            (overlay / "bridge.h").write_text("changed\n")
            with self.assertRaisesRegex(ValueError, "stale"):
                validate_sdk_source(source, native_payload(root))

    def test_sdk_export_validation_uses_loader_requirements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            loader = root / "Sources/CCobbleChromium/CCSLoader.c"
            loader.parent.mkdir(parents=True)
            loader.write_text(
                'RESOLVE(set_client, "CCSSetClient");\n'
                'RESOLVE(list_sites, "CCSWebsiteDataListSites");\n')
            source = root / "source"
            exports = source / "chrome/app/framework.exports"
            exports.parent.mkdir(parents=True)
            exports.write_text("_CCSSetClient\n")
            with self.assertRaisesRegex(ValueError,
                                        "_CCSWebsiteDataListSites"):
                validate_sdk_exports(source, root)
            exports.write_text(
                "_CCSSetClient\n_CCSWebsiteDataListSites\n")
            validate_sdk_exports(source, root)
            loader.write_text("")
            with self.assertRaisesRegex(ValueError, "no required exports"):
                validate_sdk_exports(source, root)

    def test_harness_rejects_stale_embedded_native_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            payload = {"sha256": "a" * 64, "overlay": {}, "patches": {}}
            manifest = {"schema": 1, "lock": self.current,
                        "variant": "sdk", "native_payload": payload,
                        "sdk_revision": "b" * 40,
                        "release_ready": False}
            (resources / "CobbleChromiumSDK.json").write_text(
                json.dumps(manifest))
            validate_embedded_manifest(app, self.current, payload)
            stale = {**payload, "sha256": "c" * 64}
            with self.assertRaisesRegex(ValueError, "differs"):
                validate_embedded_manifest(app, self.current, stale)

    def test_build_receipt_rejects_changed_inputs_and_binaries(self):
        # These files test build bookkeeping only, never Chromium behavior.
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            app = build_directory(work) / "Chromium.app"
            launcher = app / "Contents/MacOS/Chromium"
            framework = (app / "Contents/Frameworks/Chromium Framework.framework/Versions"
                         / self.current["version"] / "Chromium Framework")
            for binary in (launcher, framework):
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"compiled fixture")
            inputs = {"lock": self.current, "native_payload": "old",
                      "args_sha256": "args"}
            with patch("build.sdk_build_inputs", return_value=inputs):
                with self.assertRaisesRegex(ValueError, "No successful"):
                    validate_sdk_build(work)
                record_sdk_build(work, inputs)
                validate_sdk_build(work)
            with patch("build.sdk_build_inputs", return_value={**inputs, "native_payload": "new"}):
                with self.assertRaisesRegex(ValueError, "stale"):
                    validate_sdk_build(work)
                with self.assertRaisesRegex(ValueError, "changed during"):
                    record_sdk_build(work, inputs)
            with patch("build.sdk_build_inputs", return_value=inputs):
                framework.write_bytes(b"different compiled fixture")
                with self.assertRaisesRegex(ValueError, "stale"):
                    validate_sdk_build(work)

    def test_cli_rejects_second_writer_before_preflight(self):
        import build
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory) / ".cobble-build.lock").open("a") as writer:
                fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch("sys.argv", ["build.py", "preflight", "--work", directory]), patch("build.preflight") as preflight:
                    with self.assertRaisesRegex(ValueError, "already writing"):
                        build.main()
                    preflight.assert_not_called()

    def test_compile_stops_its_process_group_at_disk_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            with (patch("build.sdk_build_inputs", return_value={}),
                  patch("build.subprocess.Popen") as process,
                  patch("build.shutil.disk_usage") as usage,
                  patch("build.os.killpg") as stop):
                process.return_value.wait.side_effect = [subprocess.TimeoutExpired("ninja", 30), 1]
                usage.return_value.free = 7 * 1024 ** 3
                with self.assertRaisesRegex(ValueError, "disk floor"):
                    compile_chrome(Path(directory), "sdk", 6, 720)
                stop.assert_called_once_with(process.return_value.pid, __import__("signal").SIGTERM)

    def test_probe_discovers_new_overlay_object_after_graph_regeneration(self):
        regenerated = False
        def run(command, **kwargs):
            nonlocal regenerated
            if command[-1] == "build.ninja":
                regenerated = True
                return ""
            names = ["chromium", "browser_window", "downloads", "extensions",
                     "page_operations", "profile_deletion", "website_data"]
            if regenerated:
                names.extend(["client_certificates", "devtools", "local_file", "prompts",
                              "extension_install_prompt", "identity"])
            return "\n".join(f"obj/cobble_{name}.o: cxx" for name in names)

        with tempfile.TemporaryDirectory() as directory:
            with (patch("build.run", side_effect=run),
                  patch("build.build_environment", return_value={}),
                  patch("build.subprocess.Popen") as process):
                process.return_value.wait.return_value = 0
                compile_chrome(Path(directory), "sdk", 6, 1, probe=True)
                self.assertIn("obj/cobble_prompts.o", process.call_args.args[0])
                self.assertIn("obj/cobble_identity.o", process.call_args.args[0])
                self.assertIn("obj/cobble_extension_install_prompt.o", process.call_args.args[0])
                self.assertIn("obj/cobble_local_file.o",
                              process.call_args.args[0])

    def test_failed_compile_invalidates_prior_build_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            receipt = build_directory(work) / BUILD_RECEIPT
            receipt.parent.mkdir(parents=True)
            receipt.write_text("old success")
            with (patch("build.sdk_build_inputs", return_value={"lock": self.current}),
                  patch("build.build_environment", return_value={}),
                  patch("build.subprocess.Popen") as process,
                  patch("build.record_sdk_build") as record):
                process.return_value.wait.return_value = 1
                with self.assertRaises(subprocess.CalledProcessError):
                    compile_chrome(work, "sdk", 1, 1)
                self.assertFalse(receipt.exists())
                record.assert_not_called()

    def test_packaging_refreshes_only_a_validated_build_receipt(self):
        # Model signing's byte change, not a Chromium runtime. The real macOS
        # signer also changes a Mach-O launcher's hash when resources change.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            app = build_directory(work) / "Chromium.app"
            launcher = app / "Contents/MacOS/Chromium"
            framework = (app / "Contents/Frameworks/Chromium Framework.framework/Versions"
                         / self.current["version"] / "Chromium Framework")
            for binary in (launcher, framework):
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"build bookkeeping fixture")
            framework_bundle = app / "Contents/Frameworks/Chromium Framework.framework"
            helpers = framework.parent / "Helpers"
            helper_b = helpers / "Chromium Helper (Renderer).app"
            helper_a = helpers / "Chromium Helper.app"
            helper_b.mkdir(parents=True)
            helper_a.mkdir()
            payload = {"sha256": "f" * 64}
            inputs = {"lock": self.current, "native_payload": payload, "args_sha256": "args"}
            fail_verification = False
            mutate_receipt = False
            signing_targets = []
            strict_verifications = []
            receipt_path = build_directory(work) / BUILD_RECEIPT
            notices = {
                "CobbleChromiumSDK-LICENSE.txt": (root / "LICENSE", b"SDK license fixture"),
                "CobbleChromiumSDK-NOTICES.md": (root / "chromium/THIRD_PARTY_NOTICES.md", b"Attribution fixture"),
                "Chromium-LICENSE.txt": (work / "src/LICENSE", b"Chromium license fixture"),
            }
            for source, contents in notices.values():
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(contents)

            def command(arguments, **_):
                if arguments[0] == "codesign":
                    if "--force" in arguments:
                        signing_targets.append(arguments[-1])
                        for name, (_, contents) in notices.items():
                            self.assertEqual((app / "Contents/Resources" / name).read_bytes(), contents)
                        launcher.write_bytes(launcher.read_bytes() + b" signed")
                        if mutate_receipt:
                            receipt = json.loads(receipt_path.read_text())
                            receipt["binaries"] = {"changed": "during packaging"}
                            receipt_path.write_text(json.dumps(receipt))
                    elif fail_verification:
                        raise subprocess.CalledProcessError(1, arguments)
                    else:
                        strict_verifications.append(arguments)
                elif arguments[0] == "ditto":
                    Path(arguments[-1]).write_bytes(b"archive bookkeeping fixture")
                else:
                    self.fail(f"Unexpected packaging command: {arguments}")

            with (patch("build.ROOT", root),
                  patch("build.sdk_build_inputs", return_value=inputs),
                  patch("build.native_payload", return_value=payload),
                  patch("build.validate_sdk_source"),
                  patch("build.validate_sdk_history_policy"),
                  patch("build.sdk_revision", return_value="a" * 40),
                  patch("build.run", side_effect=command)):
                with self.assertRaisesRegex(ValueError, "No successful"):
                    package(work, "sdk", self.current)
                record_sdk_build(work, inputs)
                package(work, "sdk", self.current)
                self.assertEqual(signing_targets, [helper_b, helper_a, framework_bundle, app])
                self.assertEqual(strict_verifications,
                                 [["codesign", "--verify", "--deep", "--strict", app]])
                validate_sdk_build(work)
                package(work, "sdk", self.current)
                validate_sdk_build(work)
                mutate_receipt = True
                with self.assertRaisesRegex(ValueError, "receipt changed during"):
                    package(work, "sdk", self.current)
                self.assertEqual(json.loads(receipt_path.read_text())["binaries"],
                                 {"changed": "during packaging"})
                with self.assertRaisesRegex(ValueError, "stale"):
                    validate_sdk_build(work)
                mutate_receipt = False
                record_sdk_build(work, inputs)
                successful = receipt_path.read_bytes()
                fail_verification = True
                with self.assertRaises(subprocess.CalledProcessError):
                    package(work, "sdk", self.current)
                self.assertEqual(receipt_path.read_bytes(), successful)
                with self.assertRaisesRegex(ValueError, "stale"):
                    validate_sdk_build(work)

    def test_sdk_history_namespace_is_unavailable_on_mac(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            features = source / "chrome/common/extensions/api/_api_features.json"
            features.parent.mkdir(parents=True)
            features.write_text(
                '// Chromium feature file\n{"history":{"platforms":'
                '["chromeos","linux","win"]}}')
            validate_sdk_history_policy(source)
            features.write_text(
                '{"history":{"platforms":["chromeos","linux","mac","win"]}}')
            with self.assertRaisesRegex(ValueError, "history on macOS"):
                validate_sdk_history_policy(source)


if __name__ == "__main__":
    unittest.main()
