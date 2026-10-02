# SDK gap and correctness audit

Review date: 2026-10-02. Baseline: ABI 17, Chromium 153.0.8010.37,
SDK commit `439dba2`; this implementation advances the development ABI to 18.
This is a source and fixture audit, not a claim of complete
Chrome parity or release qualification. **The remaining work is substantial.**

## Reading the inventory

| State | Meaning |
| --- | --- |
| Fixed | Implemented in this worktree; validation is recorded below |
| Implemented | New API exists; native acceptance or host qualification remains pending |
| Partial | Some requested behavior exists; the remaining feature gap is named |
| Present | Implementation exists; the stated test or qualification may still be missing |
| Missing | No complete SDK/host path found; acceptance work is explicit |
| Qualify | Upstream implementation or a partial bridge exists, but end-to-end evidence is insufficient |
| Host | Belongs in the embedding app, not Chromium SDK |
| Excluded | Deliberate product/security boundary; preserve it |

P0 = privacy/data loss; P1 = browser correctness; P2 = compatibility/features;
P3 = developer experience. Presence in this list does not mean a stub should be
turned on. A permission UI, document-bound response, cancellation, native
implementation, and regression test are all required before enabling a surface.

## Confirmed defects and build improvements

| ID | Priority | Finding | Resolution / check |
| --- | --- | --- | --- |
| F01 | P1 | Swift latched recoverable download failures as terminal; second interruption and completion disappeared | Fixed: preserve callbacks while native advertises resume; repeated-interruption regression |
| F02 | P0 | `privateWindowKey: ""` selected normal native storage while Swift labeled it private | Fixed: reject explicit empty private key before calling native; isolation regression |
| F03 | P1 | Startup readiness waits ignored task cancellation | Fixed: cancellable waiter registry; cancellation regression |
| F04 | P1 | Late readiness callbacks could revive a stopped runtime | Fixed: stop/duplicate guards; callback-order regression |
| F05 | P1 | A missing context entry point retained a continuation forever | Fixed: require entry point before allocation; missing-entry-point regression |
| F06 | P1 | Find text containing NUL was silently truncated at the C boundary | Fixed: reject before invocation; regression |
| F07 | P1 | Extension operations accepted a context belonging to another runtime | Fixed: shared ownership guard covers all extension operations; regression |
| F08 | P1 | Reinstalled download callbacks could receive late state after release | Fixed: terminal latch and live-handle guard; regression |
| F09 | P1 | Explicit download cancellation did not latch Swift callbacks at the file barrier | Fixed: latch before host completion; cancellation regression |
| F10 | P3 | Native probe duplicated thirteen source names and a magic count | Fixed: derive expected objects from the overlay, reject missing/ambiguous objects |
| F11 | P1 | Packaging reused a version-only archive name and overwrote output | Fixed: source/payload suffix, exclusive output creation, external `--artifacts` directory |
| F12 | P3 | Runtime, prompts, contexts, page state and response decoding shared a 1,734-line Swift file | Fixed: split by ownership without renaming existing public types; the separate feature additions advance ABI |
| F13 | P1 | File chooser C strings could outlive their NSString owners in optimized builds | Fixed: retain owners through the native call; optimized chooser fixtures |
| F14 | P1 | Direct overlay application bypassed the native build writer lock | Fixed: shared lock for both CLIs, in-process application under the build lease; contention regression |
| F15 | P1 | A native probe could compile a stale installed payload and appear green | Fixed: validate source/provenance before and after probing; stale-source regression |
| F16 | P1 | State callbacks borrowed page-owned favicon/link/error buffers that a reentrant host could invalidate | Fixed: local copies survive host navigation/close during callbacks |
| F17 | P1 | A navigation begun inside a host callback could lose its diagnostic identity to the preceding start event | Fixed: install identity before callbacks and refuse stale overwrite |
| F18 | P1 | Nested download callbacks could clear an outer lifetime guard and schedule deletion while its stack frame was active | Fixed: scoped restoration for every client callback; nested cancellation/run-loop fixture added |
| F19 | P2 | Reapplying one overlay source rewrote unchanged headers and triggered broad recompilation | Fixed: swap only changed/removed files after validation; inode/mtime and removal regression |
| F20 | P1 | A valid payload stamp could hide later edits to tracked Chromium source during build/package | Fixed: reuse the exact patch-series worktree comparison at each build-input validation; real Git drift regression |
| F21 | P1 | Chromium resets its queried load-progress counter after completion; later state callbacks regressed the SDK to 0% | Fixed: retain observer progress until the next navigation/crash; native document/recovery checks caught this regression |
| F22 | P2 | The NUL-find regression mocked the legacy entry point and could pass without exercising the current native call | Fixed: mock the options entry point; add zero-ID, relative-URL and oversized-title history cases |

## Runtime, lifecycle and embedding

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| R01 | Present | One registered runtime and one AppKit event loop; loader rejects incomplete exports |
| R02 | Present | Separate UI-ready and profile-ready callbacks; startup order tests exist |
| R03 | Fixed | Cancellable readiness; cancellation must finish even if Chromium never becomes ready |
| R04 | Present | Named normal profiles and window-specific OTR contexts; native fixture covers separation |
| R05 | Fixed | Empty private identity cannot silently select persistent storage |
| R06 | Present | Before-unload close refusal and force-close are separate APIs |
| R07 | Qualify | Stress concurrent context close, popup creation, download ownership and runtime shutdown |
| R08 | Present | App-owned NSWindow lookup, live tab movement and activation callbacks |
| R09 | Present | Exact child popup disposition, legacy callback fallback; modified-link fixture |
| R10 | Qualify | Native selection versus visibility and focus across multiple windows, Spaces and minimized windows |
| R11 | Implemented | ABI 18 `ChromiumNavigationFailure` with navigation identity, network code, URL and description; cancellation is not a failure; native recovery fixture passed |
| R12 | Implemented | ABI 18 progress and native document readiness, including native BFCache-aware query; mapped into Cobble progress state |
| R13 | Missing | Host navigation policy for ordinary navigations/redirects; popup policy is a separate path |
| R14 | Implemented | Bounded native back/forward snapshots and stable-entry selection; entries absent from this page are refused, local files still require descriptor authorization |
| R15 | Implemented | ABI 18 primary-renderer termination status and responsiveness; deterministic crash fixture passed; genuine hang/recovery still requires qualification |
| R16 | Host | Workspace/session restoration policy; preserve private-tab exclusion and URL-only recovery |
| R17 | Qualify | Engine crash recovery, network-service/GPU restart and suspended-machine recovery |
| R18 | Missing | Per-operation cancellation for async DOM/archive/snapshot/data calls; retain native callback storage until acknowledgement |

## Page operations and native macOS behavior

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| U01 | Present | URL navigation, reload, origin reload, stop, focus, visibility |
| U02 | Present | Case-insensitive find, native request IDs/count/ordinal; empty text clears search |
| U03 | Fixed | Find rejects interior NUL rather than changing the search query |
| U04 | Partial | Case-sensitive, highlight/count-only find and selected-text initialization added; whole-word matching remains missing (not exposed by Chromium FindTabHelper) |
| U05 | Present | Tab-local bounded zoom; invalid/nonfinite factors rejected |
| U06 | Qualify | Native edit menu cut/copy/paste/undo/redo, spelling/dictionary suggestions, first responder routing and disabled-item state |
| U07 | Qualify | Keyboard shortcuts, dead keys, CJK IME composition and keyboard-only tab movement |
| U08 | Qualify | VoiceOver tree, focus announcements, zoom, high contrast and reduced motion |
| U09 | Qualify | Native page context menus and drag/drop across app-owned windows |
| U10 | Present | Bounded viewport PNG capture; navigation/close/shutdown cancellation lives natively |
| U11 | Present | Current DOM and native MHTML archive with bounded native operations |
| U12 | Missing | Print-to-PDF data API; existing `printPage` delegates to native printing |
| U13 | Qualify | Printing page ranges, cancellation, background tab and missing-printer cases |
| U14 | Missing | Web fullscreen with origin disclosure, Escape handling, navigation and tab-close cleanup |
| U15 | Missing | Pointer lock with explicit origin disclosure and guaranteed unlock |
| U16 | Missing | Keyboard lock with an escape mechanism independent of the renderer |
| U17 | Missing | Owned Picture-in-Picture lifecycle and state/events |
| U18 | Missing | EyeDropper implementation (`OpenEyeDropper` returns null) |
| U19 | Missing | Translation UI/service integration (`ShowTranslateBubble` is a stub) |
| U20 | Host | Reader UI, toolbar, favorites, spaces, history UI and browser themes |

## Permissions, authentication and browser services

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| P01 | Present | Camera/microphone prompt identities, stale-document rejection and cancellation |
| P02 | Qualify | Real microphone/camera hardware, denied/revoked TCC, device loss and multiple captures |
| P03 | Missing | Screen/window/tab capture chooser and visible capture indicator; device media is not display capture |
| P04 | Missing | Granular capture mute/stop controls; current stop terminates all user-media streams |
| P05 | Missing | General permission check/request/result bridge with consistent revocation; the current runtime denies unowned permission prompts |
| P06 | Missing | Geolocation consent, accuracy selection and revocation through owned UI |
| P07 | Missing | Notification permission plus macOS notification delivery/click lifecycle |
| P08 | Missing | Clipboard read permission UI and origin-bound cancellation |
| P09 | Missing | Persistent-storage, idle-detection and other general permission surfaces |
| P10 | Missing | WebUSB chooser and device-disconnect lifecycle; currently denied |
| P11 | Missing | WebHID chooser and disconnect lifecycle; currently denied |
| P12 | Missing | Web Serial chooser, remembered grants and revocation; currently denied |
| P13 | Missing | Web Bluetooth chooser and TCC integration; deliberately blocked before adapter startup |
| P14 | Qualify | File System Access API pickers, writable grants and persisted-handle reauthorization; upload chooser is not sufficient |
| P15 | Present | HTTP/proxy authentication with cancel, NUL rejection and document-bound callbacks |
| P16 | Present | Client-certificate selection uses native keys, bounded metadata and exact navigation/document context |
| P17 | Qualify | Real enterprise mTLS, smart cards, expired certificates and Keychain access prompts |
| P18 | Missing | Owned FedCM account chooser; patch 0030 currently refuses the unhosted dialog |
| P19 | Qualify | WebAuthn/passkeys, Touch ID, security keys, conditional mediation and cancellation |
| P20 | Qualify | Apple Passwords system helper integration and real-site Sign in with Apple |
| P21 | Excluded | Cobble-managed password vault, Chrome account sync and telemetry |
| P22 | Missing | Address/payment autofill UI; current bubble handler does not provide complete surfaces |

## Downloads and local files

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| D01 | Present | Network and blob downloads, bounded host destination handoff |
| D02 | Present | Existing/dangling destination rejection and file-sequence completion barrier |
| D03 | Present | Pause/resume and cancellation of a live transfer |
| D04 | Fixed | Multiple recoverable GET interruptions retain progress/failure/completion handlers |
| D05 | Present | Interrupted POST requests must not be replayed; native guards and smoke case exist |
| D06 | Fixed | Release and cancellation make late Swift callbacks inert |
| D07 | Missing | Restart-persistent download recovery; current handles are process-local |
| D08 | Implemented | ABI 18 original/current URLs, MIME, normalized byte counts and native interruption code; retry and completion metadata fixtures passed |
| D09 | Qualify | Safe Browsing/download verdict availability in the shipped unbranded runtime |
| D10 | Present | Exact local-file descriptor authorization; rejects directories, symlinks and adjacent access |
| D11 | Missing | Local PDF viewing through the authorized-file path; native explicitly rejects it |
| D12 | Missing | User-authorized document bundles/subresources; do not grant parent directories implicitly |
| D13 | Qualify | Network PDF viewer, save/print, forms, accessibility and document download |
| D14 | Qualify | Real removable disks, disk-full, destination replacement and filesystem permission changes |

## Profiles, storage and identity

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| S01 | Present | Normal/private profile leases, profile-deletion preflight and physical-deletion verification |
| S02 | Qualify | Deletion while tasks are active, recovery after crash and restart with pending deletion |
| S03 | Present | Website-data enumeration and supported site/profile/cache removal scopes |
| S04 | Missing | Per-origin byte counts and granular cookie/IndexedDB/service-worker/cache breakdown |
| S05 | Missing | Site-data time-range deletion; current time cutoff supports cache only |
| S06 | Present | Restricted HTTPS cookie transfer with full-batch validation and private-context rejection |
| S07 | Excluded | Unrestricted cookie copying, partitioned-cookie flattening and WebKit store migration |
| S08 | Qualify | Cookie replacement failure semantics; transfer is intentionally non-atomic |
| S09 | Present | Navigation-bound browser identity, redirect/popup inheritance and BFCache restoration |
| S10 | Qualify | Service/shared-worker identity remains native; document identity does not emulate a whole device |
| S11 | Missing | Explicit proxy configuration/preferences API for embedders |
| S12 | Missing | Per-context language/Accept-Language configuration API |
| S13 | Missing | Public certificate-exception management; preserve fail-closed validation until an owned flow exists |
| S14 | Qualify | Offline/service-worker persistence, quota pressure, third-party storage and partitioning |
| S15 | Excluded | A second custom network cache or duplicate application history database |

## Extensions and content blocking

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| E01 | Present | Native extension registry metadata and change observation |
| E02 | Present | Unpacked install, enable/disable/remove and exact site access with withheld permissions |
| E03 | Present | Owned extension-install consent bridge; source and user-manageability distinctions |
| E04 | Fixed | Extension operations reject contexts from another runtime |
| E05 | Missing | Native extension action popup host; `performExtensionAction` reports unsupported |
| E06 | Missing | Extension side-panel host; currently reports unsupported |
| E07 | Qualify | Chrome Web Store installation, signed CRX validation, update consent and restart |
| E08 | Missing | Private extension access with explicit opt-in and isolated events/storage; currently denied |
| E09 | Qualify | MV3 workers, alarms, commands, messaging and native tabs/windows topology across restarts |
| E10 | Qualify | Options pages, external links, downloads and host-window ownership in arbitrary extensions |
| E11 | Present | Bounded DNR blocker subset and readiness before requests; no script injection |
| E12 | Missing | Filter-list conversion, cosmetics and richer rules; current API deliberately accepts a subset |
| E13 | Qualify | Large rulesets, extension collisions, permission increases and corrupted installed copies |
| E14 | Excluded | Native messaging, Chrome Apps, extension themes and extension access to Chromium history |

## Security, resources, build and distribution

| ID | State | Gap / evidence / next acceptance criterion |
| --- | --- | --- |
| B01 | Present | Exact Chromium/depot_tools locks, overlay/patch hashes and native export checks |
| B02 | Present | Native child sandboxes retained; the macOS host remains unsandboxed |
| B03 | Qualify | Operation-denial sandbox tests on each shipped child type; installed Seatbelt alone is insufficient |
| B04 | Present | Versioned ABI and all-required-symbol loader; registration rejects mismatched ABI |
| B05 | Implemented | `runtimeInfo()` returns the loaded ABI, Chromium version and upstream revision; no blanket capability claim for unfinished host UI |
| B06 | Present | Dedicated incremental cache, one cooperating build writer, disk floor and bounded compile slices |
| B07 | Fixed | Probe source discovery no longer requires synchronized filename/count edits |
| B08 | Fixed | Runtime archive filenames distinguish SDK revision and native payload; existing outputs are preserved |
| B09 | Fixed | External artifact directory selection avoids keeping runtime archives in source worktrees |
| B10 | Qualify | Fresh-machine build/rebuild and reproducibility; incremental success is not a clean-build proof |
| B11 | Missing | Hermetic dependency/artifact inventory beyond lock, payload and current license notices |
| B12 | Qualify | Ordinary-launch networking without diagnostic suppression; fresh/reused profiles and unmanaged policy |
| B13 | Missing | Sustained CPU/RAM/energy baselines, renderer counts and regression thresholds |
| B14 | Qualify | Video decode/encode, WebGL/WebGPU, WebRTC calls and screen sleep/wake |
| B15 | Missing | Licensed proprietary codecs/Widevine distribution; enabling a flag does not supply redistribution rights |
| B16 | Qualify | Real-site compatibility matrix: conferencing, editors, media, enterprise SSO and payments |
| B17 | Missing | Fuzzing/property coverage for ABI strings, JSON records, manifests and patch application |
| B18 | Qualify | Developer ID signing, notarization, stapling, clean install, rollback and sustained everyday use |
| B19 | Host | App update feed, release channels, source pin advancement and user-facing update UX |
| B20 | Present | Update discovery reports 154.0.8037.98 available above pinned 153.0.8010.37; source update, patch rebase and matched runtime qualification remain outstanding |
| B21 | Missing | Documented security-patch owner/response deadline and emergency runtime rollback exercise |
| B22 | Missing | Automated native CI runner capacity sufficient for repeatable full SDK acceptance |

## Architecture and naming

```text
Cobble UI / persistence / engine-neutral contracts
                    ↓
Cobble Chromium adapter
                    ↓
Swift SDK: Runtime → Context → Page
                 ↘ Prompts / Downloads / Extensions / WebsiteData
                    ↓
CCobbleChromium: loader + versioned C ABI
                    ↓
Chromium overlay: native lifetime, policy, browser services
                    ↓
Pinned upstream Chromium + narrowly ordered patches
```

| Owner | Files / rule |
| --- | --- |
| Process and host callbacks | `Sources/CobbleChromium/ChromiumRuntime.swift` |
| Profile leases and context close | `ChromiumContext.swift` |
| Page state, operations, DevTools and page result decoding | `ChromiumPage.swift` |
| Document-bound consent objects | `ChromiumPrompts.swift` |
| Independent services | Existing `ChromiumDownloads`, `ChromiumExtensions`, `ChromiumWebsiteData`, `ChromiumBlockingRules` |
| C ABI compatibility | Existing `CCS*` exported names and versioned structs; no cosmetic ABI rename |
| Native implementation | Existing `cobble_<responsibility>.h/.mm`; preserve upstream overlay paths |
| Build | `build.py` stages and immutable source/payload-specific archives; preserve existing object directory |
| Patches | Keep current ordering; two historical `0012-` names are ordered lexically. Avoid renumbering applied payloads solely for aesthetics |
| Evidence | Synthetic fixtures; native receipts and binaries outside Git |

The split keeps one Swift module, with internal bridge hooks rather than extra
frameworks, service locators or generic lifecycle managers. New host surfaces
must route through the same ownership path. Chromium owns browser mechanics;
Cobble owns user-visible UI and persisted choices. Never let a stub pretend to
support a permission or let Chromium create an unowned Views window.

## Implementation order for the remaining surfaces

| Order | Work | Completion evidence |
| --- | --- | --- |
| 1 | Fixed defects above, source/API review, regressions | Passing SDK tests and full existing native smoke |
| 2 | Navigation failures/progress, runtime capabilities, structured downloads | ABI revision, loader coverage, adapter integration, native fixture |
| 3 | General permission broker and owned fullscreen/lock UI | Origin disclosure, cancellation, navigation/close races, keyboard/accessibility tests |
| 4 | Extension popup/side-panel surfaces and private opt-in | Multiple-window/restart fixtures and representative real extensions |
| 5 | Device choosers, display capture, FedCM and authentication | Real hardware/TCC/account tests with explicit user-visible consent |
| 6 | Local PDF/bundles, print-to-PDF and persistent downloads | Descriptor/grant isolation, interrupted writes, restart and disk-failure tests |
| 7 | Performance, networking, security, distribution | Named native/manual/release gates; do not infer from Swift tests |

## Research and comparison basis

- Local source: all SDK Swift services, C loader/header, native overlay boundaries,
  patch inventory, build/assembly scripts, existing native smoke and Cobble's
  engine contracts/adapter. This is not a line-by-line proof of upstream Chromium.
- [Chromium embedding and tab helpers](https://github.com/chromium/chromium/blob/main/docs/tab_helpers.md):
  browser tab services extend WebContents; native helper presence is distinct from
  a complete host UI. The pinned local source is authoritative for implementation.
- [Chromium WebContentsDelegate](https://github.com/chromium/chromium/blob/main/content/public/browser/web_contents_delegate.h):
  comparison surface for navigation, focus, fullscreen, capture and chooser ownership.
- [CEF client handlers](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_client.h)
  and [browser API](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_browser.h):
  comparison checklist for events, frame lifecycle, printing, find, input and developer tools.
  These are comparison APIs, not dependencies added to this SDK.
- [CEF permissions](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_permission_handler.h):
  separates media access from general permission prompts and dismissal.
- [CEF requests](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_request_handler.h),
  [contexts](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_request_context.h),
  [frames](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_frame.h):
  comparison for navigation policy, authentication, profile operations and editing.
- [Electron webContents](https://www.electronjs.org/docs/latest/api/web-contents/)
  and [session](https://www.electronjs.org/docs/latest/api/session): additional
  comparison for native history, PDF output, permission checks versus prompts,
  session proxy/language controls and spellchecking. macOS spelling uses the OS;
  a separate dictionary engine is not required. Isolated script execution and
  custom protocols would need a separate, bounded host API design; their absence
  is not permission to inject scripts into arbitrary browsing pages automatically.
- [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview):
  native embedding comparator; Cobble's existing WebKit adapter is the concrete app contract.
- [Chromium macOS build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md):
  upstream build reference; this project retains its pinned toolchain and incremental cache.

## Validation record

Baseline: 66 Python tests, 20 Swift tests, and the Node fixture checks passed.
Current worktree checks: 71 Python tests, 34 Swift tests in debug and release,
and 9 Cobble adapter tests passed. Cobble hosted suite: 579 tests, initially
3 GUI skips, zero failures; all three audio playback fixtures ran. After the
desktop session was unlocked, all three skipped GUI tests passed in a focused
rerun with zero skips. Runner configuration inheritance passed.
Cobble’s optimized ABI 18 client also builds without Swift compiler warnings.
Two obsolete tests were removed with an unused default-browser callback helper;
the actual settings path uses the native async API.

The corrected ABI 18 full native build/package passed deep/strict ad-hoc
signatures, checksum and ZIP integrity. Native smoke caught and drove the
completed-load progress fix. After unlocking the desktop session, the full run
passed 237 native checks with zero skips, plus
navigation/DOM/forms, rendering, WebGL2/worker canvas, repeated interrupted-download
recovery and metadata, nested terminal cancellation, profile restart, clean
shutdown and empty durable History tables. Synthetic rendering screenshots were
also inspected.

The earlier activation failure was environmental. All five formerly skipped
DevTools frontend checks now pass: exact inspected target, docking rejection,
new-tab escape rejection, frontend crash closure and reopening after that crash.
This completes the automated native smoke gate; broader manual focus,
accessibility and IME qualification remain separate.
No public release, real-account test, hardware permission grant, or signing/notarization
qualification is implied by this audit.
