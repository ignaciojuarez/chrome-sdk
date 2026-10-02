# Chrome SDK

A native macOS SDK built on Chromium, with a Swift API for embedding the browser engine. Used by [Cobble](https://github.com/ignaciojuarez/cobble-browser). Independent project; not an official Google SDK. This repository contains the Swift API, a narrow native bridge, patches against a pinned Chromium release, and an independent test harness. It does **not** contain a Chromium checkout. Matched development runtimes are published as immutable GitHub Release assets; they are not release-qualified app downloads.

| | |
| --- | --- |
| ABI | 18 (development; matched runtime required) |
| Engine | Chromium 153.0.8010.37, pinned in [`chromium.lock.json`](chromium.lock.json) |
| Platform | Apple Silicon macOS |
| Source | Swift 6, Objective-C++, C++, Python |
| Status | Development build; no release signing or notarization |

The app embeds Chromium's real framework, helpers, and resources. The Swift package alone does not render pages. Cobble also builds separately with WebKit.

See [AUDIT.md](AUDIT.md) for the feature inventory, known gaps, ownership map,
and validation limits. Existing APIs do not imply full Chrome UI compatibility.

## Development workflow

This public repository is the source of truth. Work on branches or temporary
worktrees here; the former private SDK repository is archived. Cobble pins an
exact SDK commit, and Full packaging requires that commit’s matched runtime,
ABI, source lock and native-payload hashes. Keep one incremental Chromium work
directory outside Git. Keep packaged runtimes outside the source checkout and
retain one rollback runtime instead of copying source/build trees.

ABI 18 adds `runtimeInfo()`, structured main-frame navigation failures,
load progress/document readiness, primary-renderer health, native history entry
selection, case-sensitive/count-only find, initial find text, and download source,
MIME, byte-count and interruption metadata. Download MIME is Chromium's effective
type and may reflect the filename's native mapping rather than the response
header alone. This client requires a rebuilt ABI 18 runtime; ABI 17 binaries
cannot load it. Recoverable download failures preserve
callbacks through repeated retries, and an empty private-window key is rejected.

ABI 17 adds `ChromiumRuntime.onPopupWithDisposition`, delivering the created
child’s exact opening intent. Command-click and middle-click children can stay
in the background; ordinary popups and Shift-modified children activate. The
legacy `onPopup` callback remains available for hosts that always activate.

Lightweight source and Swift checks run in CI. Chromium-update discovery opens
a review proposal; native builds remain manual, and checkpoint uploads default
to off. A lock update alone never qualifies or publishes a runtime.

## Build

The source checks need Python 3 and Node.js. The Swift package needs Xcode:

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
node Tests/test_smoke_fixture.mjs
swift test
swift build --product CobbleChromiumClient
```

A full engine build needs an Apple Silicon Mac, Xcode, Chromium's source dependencies, and at least 100 GiB of free space. The driver downloads the exact Chromium and `depot_tools` commits in [`chromium.lock.json`](chromium.lock.json), then applies this repository's [`chromium/overlay`](chromium/overlay) and [`chromium/patches`](chromium/patches). Use a dedicated work directory outside this repository:

```sh
WORK=/path/to/chromium-build
python3 scripts/build.py preflight --work "$WORK"
python3 scripts/build.py prepare --work "$WORK"
python3 scripts/build.py configure --work "$WORK" --variant sdk
python3 scripts/build.py probe --work "$WORK" --variant sdk
python3 scripts/build.py compile --work "$WORK" --variant sdk
python3 scripts/build.py package --work "$WORK" --variant sdk
```

The build produces an unbranded `Chromium.app` and an SDK archive named with
the engine version, SDK revision and native-payload fingerprint. Packaging
refuses existing output and checks the source lock, overlay, patch hashes,
exports, and successful build receipt. Use `package --artifacts /path/to/new-output`
to keep immutable archives outside the source checkout; the default is ignored
`artifacts/`. To run the independent harness:

```sh
python3 scripts/assemble_harness.py "$WORK/src/out/Cobble/Chromium.app" \
  --output '/tmp/Cobble Chromium Harness.app'
node scripts/smoke.mjs '/tmp/Cobble Chromium Harness.app'
```

The build can take hours and substantial memory. `--jobs` controls native build parallelism (default: 3). Builds for a new Chromium release require patch review and fresh runtime validation; changing the lock alone is insufficient.

## Layout

- `Sources/CobbleChromium/`: Swift process (`ChromiumRuntime`), profile
  (`ChromiumContext`), page (`ChromiumPage`), consent (`ChromiumPrompts`) and service APIs.
- `Sources/CCobbleChromium/`: dynamic loader for the native bridge.
- `chromium/overlay/` and `chromium/patches/`: additions and changes to the pinned Chromium source.
- `Sources/ChromiumHarness/` and `scripts/smoke.mjs`: isolated native behavior checks.
- `scripts/build.py`: source preparation, build, provenance checks, and packaging.

## Limits

The project is under development. The packaged runtime is marked `release_ready: false`. Distribution signing, notarization, broad website compatibility, accessibility, performance, proprietary codecs, DRM, and some authentication flows remain unqualified. Do not treat the harness or source checks as a release gate.

## License and attribution

Original Cobble SDK code in this snapshot is licensed under [GPLv3](LICENSE). The [previous BSD grant](LICENSES/Cobble-BSD-3-Clause.txt) remains available for earlier copies. Chromium code appearing in the patches retains [Chromium's license](chromium/LICENSE.chromium); its other third-party components retain their own notices. The build packages Chromium's generated credits. [`chromium/THIRD_PARTY_NOTICES.md`](chromium/THIRD_PARTY_NOTICES.md) records the Mori Browser attribution for the native adapter structure.
