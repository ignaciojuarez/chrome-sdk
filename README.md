# Chrome SDK

A native macOS SDK built on Chromium, with a Swift API for embedding the browser engine. Used by [Cobble](https://github.com/ignaciojuarez/cobble-browser). Independent project; not an official Google SDK. This repository contains the Swift API, a narrow native bridge, patches against a pinned Chromium release, and an independent test harness. It does **not** contain a Chromium checkout or a prebuilt runtime.

| | |
| --- | --- |
| Engine | Chromium 153.0.8010.37, pinned in [`chromium.lock.json`](chromium.lock.json) |
| Platform | Apple Silicon macOS |
| Source | Swift 6, Objective-C++, C++, Python |
| Status | Development build; no release signing or notarization |

The app embeds Chromium's real framework, helpers, and resources. The Swift package alone does not render pages. Cobble also builds separately with WebKit.

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

The build produces an unbranded `Chromium.app` and a versioned SDK archive under the ignored `artifacts/` directory. Packaging checks the source lock, overlay, patch hashes, exports, and successful build receipt. To run the independent harness:

```sh
python3 scripts/assemble_harness.py "$WORK/src/out/Cobble/Chromium.app" \
  --output '/tmp/Cobble Chromium Harness.app'
node scripts/smoke.mjs '/tmp/Cobble Chromium Harness.app'
```

The build can take hours and substantial memory. `--jobs` controls native build parallelism (default: 3). Builds for a new Chromium release require patch review and fresh runtime validation; changing the lock alone is insufficient.

## Layout

- `Sources/CobbleChromium/`: Swift runtime and page API.
- `Sources/CCobbleChromium/`: dynamic loader for the native bridge.
- `chromium/overlay/` and `chromium/patches/`: additions and changes to the pinned Chromium source.
- `Sources/ChromiumHarness/` and `scripts/smoke.mjs`: isolated native behavior checks.
- `scripts/build.py`: source preparation, build, provenance checks, and packaging.

## Limits

The project is under development. The packaged runtime is marked `release_ready: false`. Distribution signing, notarization, broad website compatibility, accessibility, performance, proprietary codecs, DRM, and some authentication flows remain unqualified. Do not treat the harness or source checks as a release gate.

## License and attribution

Original Cobble SDK code in this snapshot is licensed under [GPLv3](LICENSE). The [previous BSD grant](LICENSES/Cobble-BSD-3-Clause.txt) remains available for earlier copies. Chromium code appearing in the patches retains [Chromium's license](chromium/LICENSE.chromium); its other third-party components retain their own notices. The build packages Chromium's generated credits. [`chromium/THIRD_PARTY_NOTICES.md`](chromium/THIRD_PARTY_NOTICES.md) records the Mori Browser attribution for the native adapter structure.
