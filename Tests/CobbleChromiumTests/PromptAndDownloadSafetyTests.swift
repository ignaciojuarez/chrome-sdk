import AppKit
import Foundation
import XCTest
import CCobbleChromium
@testable import CobbleChromium

nonisolated(unsafe) private var nativeResolveCount = 0
nonisolated(unsafe) private var lastFileChooserCount: Int?
nonisolated(unsafe) private var lastFileChooserCancelled = false
nonisolated(unsafe) private var lastDialogAccept: UInt8?
nonisolated(unsafe) private var lastAuthSubmitted = false
nonisolated(unsafe) private var downloadControlState: UInt32 = 0

@MainActor final class PromptAndDownloadSafetyTests: XCTestCase {
    override func setUp() {
        nativeResolveCount = 0
        lastFileChooserCount = nil
        lastFileChooserCancelled = false
        lastDialogAccept = nil
        lastAuthSubmitted = false
        downloadControlState = 0
    }

    func testDownloadTerminalStatusLatchesCallbacks() {
        let runtime = ChromiumRuntime(api: CCSAPI())
        let download = ChromiumDownload(
            runtime: runtime, page: nil, handle: OpaquePointer(bitPattern: 1)!,
            suggestedFilename: "file.bin")
        var finishes = 0
        var failures = 0
        var progress = 0
        download.onFinish = { finishes += 1 }
        download.onFailure = { _ in failures += 1 }
        download.onProgress = { _, _ in progress += 1 }

        var state = CCSDownloadStateV2()
        state.status = CCS_DOWNLOAD_IN_PROGRESS
        state.received_bytes = 1
        state.total_bytes = 2
        download.update(state)
        XCTAssertEqual(progress, 1)

        state.status = CCS_DOWNLOAD_COMPLETE
        download.update(state)
        download.update(state)
        state.status = CCS_DOWNLOAD_FAILED
        download.update(state)
        state.status = CCS_DOWNLOAD_IN_PROGRESS
        download.update(state)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(progress, 1)
    }

    func testDownloadFailureLatchesAndRuntimeStopDoesNotSynthesizeFinish() {
        let runtime = ChromiumRuntime(api: CCSAPI())
        let download = ChromiumDownload(
            runtime: runtime, page: nil, handle: OpaquePointer(bitPattern: 2)!,
            suggestedFilename: "file.bin")
        var finishes = 0
        var failures = 0
        download.onFinish = { finishes += 1 }
        download.onFailure = { _ in failures += 1 }

        var state = CCSDownloadStateV2()
        state.status = CCS_DOWNLOAD_FAILED
        download.update(state)
        download.update(state)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(finishes, 0)

        let stopped = ChromiumDownload(
            runtime: runtime, page: nil, handle: OpaquePointer(bitPattern: 3)!,
            suggestedFilename: "other.bin")
        stopped.onFinish = { finishes += 1 }
        stopped.onFailure = { _ in failures += 1 }
        stopped.runtimeStopped()
        state.status = CCS_DOWNLOAD_COMPLETE
        stopped.update(state)
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(failures, 1)
    }

    func testRecoverableDownloadKeepsCallbacksAcrossRepeatedInterruptions() throws {
        var api = CCSAPI()
        api.download_get_control_state = { _ in downloadControlState }
        api.download_set_paused = { _, _ in downloadControlState = 1; return 1 }
        let runtime = ChromiumRuntime(api: api)
        let download = ChromiumDownload(runtime: runtime, page: nil,
            handle: OpaquePointer(bitPattern: 20)!, suggestedFilename: "retry.bin")
        var failures = 0
        var progress = 0
        var finishes = 0
        download.onFailure = { _ in failures += 1 }
        download.onProgress = { _, _ in progress += 1 }
        download.onFinish = { finishes += 1 }
        var state = CCSDownloadStateV2()
        for _ in 0..<2 {
            downloadControlState = 2
            state.status = CCS_DOWNLOAD_FAILED
            download.update(state)
            XCTAssertTrue(download.canResume)
            try download.resume()
            state.status = CCS_DOWNLOAD_IN_PROGRESS
            download.update(state)
        }
        downloadControlState = 0
        state.status = CCS_DOWNLOAD_COMPLETE
        download.update(state)
        download.update(state)
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(progress, 2)
        XCTAssertEqual(finishes, 1)
    }

    func testDownloadMetadataIsCopiedBeforeCallbacksAndClearsOnResume() {
        var api = CCSAPI()
        api.download_get_control_state = { _ in 2 }
        let runtime = ChromiumRuntime(api: api)
        let download = ChromiumDownload(runtime: runtime, page: nil,
            handle: OpaquePointer(bitPattern: 23)!, suggestedFilename: "redirect.bin")
        var failures = 0
        download.onFailure = { _ in
            failures += 1
            XCTAssertEqual(download.interruptionReasonCode, 20)
            XCTAssertEqual(download.receivedBytes, 40)
            XCTAssertNil(download.totalBytes)
        }
        var state = CCSDownloadStateV2()
        state.status = CCS_DOWNLOAD_FAILED
        state.interrupt_reason = 20
        state.received_bytes = 40
        state.total_bytes = -1
        "https://example.test/start".withCString { original in
            "https://example.test/file".withCString { current in
                "application/octet-stream".withCString { mime in
                    state.original_url_utf8 = original
                    state.current_url_utf8 = current
                    state.mime_type_utf8 = mime
                    download.update(state)
                }
            }
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(download.originalURL?.absoluteString, "https://example.test/start")
        XCTAssertEqual(download.currentURL?.absoluteString, "https://example.test/file")
        XCTAssertEqual(download.mimeType, "application/octet-stream")
        state = CCSDownloadStateV2()
        state.status = CCS_DOWNLOAD_IN_PROGRESS
        state.received_bytes = -1
        state.total_bytes = 100
        download.update(state)
        XCTAssertNil(download.interruptionReasonCode)
        XCTAssertNil(download.originalURL)
        XCTAssertNil(download.currentURL)
        XCTAssertNil(download.mimeType)
        XCTAssertEqual(download.receivedBytes, 0)
        XCTAssertEqual(download.totalBytes, 100)
    }

    func testReleasedDownloadIgnoresLateStateEvenIfCallbacksAreReinstalled() {
        let runtime = ChromiumRuntime(api: CCSAPI())
        let download = ChromiumDownload(runtime: runtime, page: nil,
            handle: OpaquePointer(bitPattern: 21)!, suggestedFilename: "released.bin")
        download.release()
        var finishes = 0
        download.onFinish = { finishes += 1 }
        var state = CCSDownloadStateV2()
        state.status = CCS_DOWNLOAD_COMPLETE
        download.update(state)
        XCTAssertEqual(finishes, 0)
    }

    func testCancelBarrierDisablesControlsAndLateDestinationBeforeHostCompletion() {
        var api = CCSAPI()
        api.download_cancel = { _, data, callback in callback?(data) }
        api.download_get_control_state = { _ in 2 }
        api.download_set_destination = { _, _ in XCTFail("Cancelled destination reached native") }
        let runtime = ChromiumRuntime(api: api)
        let download = ChromiumDownload(runtime: runtime, page: nil,
            handle: OpaquePointer(bitPattern: 22)!, suggestedFilename: "cancelled.bin")
        var completions = 0
        download.onFinish = { XCTFail("Cancelled download finished") }
        download.cancel {
            completions += 1
            XCTAssertFalse(download.canResume)
            do { try download.resume(); XCTFail("Cancelled download resumed") }
            catch ChromiumError.closed {}
            catch { XCTFail("Unexpected error: \(error)") }
            download.setDestination(URL(fileURLWithPath: "/tmp/late-download.bin"))
        }
        var state = CCSDownloadStateV2()
        state.status = CCS_DOWNLOAD_COMPLETE
        download.update(state)
        XCTAssertEqual(completions, 1)
    }

    func testJavaScriptPromptRejectsInteriorNUL() throws {
        var api = CCSAPI()
        api.javascript_dialog_resolve = { _, accept, _ in
            nativeResolveCount += 1
            lastDialogAccept = accept
            return 1
        }
        let runtime = ChromiumRuntime(api: api)
        let page = attachedPage(runtime)
        var value = CCSJavaScriptDialogRequestV1()
        value.kind = CCS_JAVASCRIPT_DIALOG_PROMPT
        let request = try XCTUnwrap(ChromiumJavaScriptDialogRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 4)!, value: value))
        XCTAssertEqual(request.kind, .prompt)
        XCTAssertFalse(request.accept(promptText: "ok\0bad"))
        XCTAssertTrue(request.isPending)
        XCTAssertEqual(nativeResolveCount, 0)
        XCTAssertTrue(request.accept(promptText: "ok"))
        XCTAssertEqual(nativeResolveCount, 1)
        XCTAssertEqual(lastDialogAccept, 1)
        XCTAssertFalse(request.isPending)
    }

    func testHTTPAuthRejectsInteriorNUL() {
        var api = CCSAPI()
        api.http_auth_resolve = { _, _, _ in
            lastAuthSubmitted = true
            nativeResolveCount += 1
            return 1
        }
        let runtime = ChromiumRuntime(api: api)
        let page = attachedPage(runtime)
        let request = ChromiumHTTPAuthRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 5)!,
            value: CCSHTTPAuthRequestV1())
        XCTAssertFalse(request.submit(username: "user\0name", password: "secret"))
        XCTAssertFalse(request.submit(username: "user", password: "se\0cret"))
        XCTAssertTrue(request.isPending)
        XCTAssertFalse(lastAuthSubmitted)
        XCTAssertTrue(request.submit(username: "user", password: "secret"))
        XCTAssertEqual(nativeResolveCount, 1)
        XCTAssertTrue(lastAuthSubmitted)
    }

    func testUnknownJavaScriptDialogKindRefusesInitialization() {
        let runtime = ChromiumRuntime(api: CCSAPI())
        let page = attachedPage(runtime)
        var value = CCSJavaScriptDialogRequestV1()
        value.kind = CCS_JAVASCRIPT_DIALOG_ALERT
        XCTAssertEqual(
            ChromiumJavaScriptDialogRequest(
                runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 6)!,
                value: value)?.kind,
            .alert)

        value.kind = CCSJavaScriptDialogKind(rawValue: numericCast(99))
        XCTAssertNil(ChromiumJavaScriptDialogRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 7)!, value: value))
    }

    func testUnknownFileChooserModeRefusesInitialization() {
        let runtime = ChromiumRuntime(api: CCSAPI())
        let page = attachedPage(runtime)
        var value = CCSFileChooserRequestV1()
        value.mode = CCS_FILE_CHOOSER_OPEN
        XCTAssertEqual(
            ChromiumFileChooserRequest(
                runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 8)!,
                value: value)?.mode,
            .open)

        value.mode = CCSFileChooserMode(rawValue: numericCast(99))
        XCTAssertNil(ChromiumFileChooserRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 9)!, value: value))
    }

    func testFileChooserSelectValidatesModeCountUTF8AndEmptyCancel() throws {
        var api = CCSAPI()
        api.file_chooser_resolve = { _, paths, count in
            nativeResolveCount += 1
            lastFileChooserCount = Int(count)
            lastFileChooserCancelled = paths == nil || count == 0
            return 1
        }
        let runtime = ChromiumRuntime(api: api)
        let page = attachedPage(runtime)
        var value = CCSFileChooserRequestV1()
        value.mode = CCS_FILE_CHOOSER_OPEN
        let open = try XCTUnwrap(ChromiumFileChooserRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 10)!, value: value))
        let file = URL(fileURLWithPath: "/tmp/one.txt")
        let other = URL(fileURLWithPath: "/tmp/two.txt")
        XCTAssertFalse(open.select([file, other]))
        XCTAssertEqual(nativeResolveCount, 0)
        XCTAssertTrue(open.isPending)
        XCTAssertTrue(open.select([]))
        XCTAssertEqual(nativeResolveCount, 1)
        XCTAssertTrue(lastFileChooserCancelled)
        XCTAssertFalse(open.isPending)

        value.mode = CCS_FILE_CHOOSER_OPEN_MULTIPLE
        let multiple = try XCTUnwrap(ChromiumFileChooserRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 11)!, value: value))
        XCTAssertTrue(multiple.select([file, other]))
        XCTAssertEqual(lastFileChooserCount, 2)
        XCTAssertFalse(lastFileChooserCancelled)

        value.mode = CCS_FILE_CHOOSER_SAVE
        let save = try XCTUnwrap(ChromiumFileChooserRequest(
            runtime: runtime, page: page, handle: OpaquePointer(bitPattern: 12)!, value: value))
        let nulPath = URL(fileURLWithPath: "/tmp/nul\u{0}name.txt")
        if nulPath.path.utf8.contains(0) {
            XCTAssertFalse(save.select([nulPath]))
        }
        XCTAssertFalse(save.select([URL(string: "https://example.test/file")!]))
        XCTAssertTrue(save.isPending)
    }

    private func attachedPage(_ runtime: ChromiumRuntime) -> ChromiumPage {
        let handle = OpaquePointer(bitPattern: 0x51)!
        let context = ChromiumContext(
            runtime: runtime, handle: handle, profileKey: "fixture", privateWindowKey: nil)
        return ChromiumPage(
            runtime: runtime, context: context, handle: handle,
            hostWindowID: UUID(), nativeView: NSView())
    }
}
