import AppKit
import Foundation
import Darwin
import XCTest
import CCobbleChromium
@testable import CobbleChromium

@MainActor private var registeredClient: CCSClientV13?
nonisolated(unsafe) private var stubPageView: NSView?
nonisolated(unsafe) private var profileDeleteStatus = CCS_PROFILE_DELETE_COMPLETED
nonisolated(unsafe) private var promptCancelCount = 0
nonisolated(unsafe) private var presentedDialogKind: ChromiumJavaScriptDialogRequest.Kind?
nonisolated(unsafe) private var presentedChooserMode: ChromiumFileChooserRequest.Mode?
nonisolated(unsafe) private var identityResults: [Int32] = []
nonisolated(unsafe) private var identityUnregisterCount = 0
nonisolated(unsafe) private var contextOpenCount = 0
nonisolated(unsafe) private var nativeVersion: UnsafePointer<CChar>?
nonisolated(unsafe) private var nativeRevision: UnsafePointer<CChar>?
nonisolated(unsafe) private var nativePageData = Data()
nonisolated(unsafe) private var nativeFindOptions: UInt32 = 0
nonisolated(unsafe) private var nativeHistoryEntryID: Int32 = 0

@MainActor final class RuntimeLoadingTests: XCTestCase {
    override func setUp() async throws {
        ChromiumRuntime.testingReleaseClientRegistration()
        registeredClient = nil
        stubPageView = nil
        presentedDialogKind = nil
        presentedChooserMode = nil
        promptCancelCount = 0
        identityResults = []
        identityUnregisterCount = 0
        contextOpenCount = 0
    }

    func testMissingRuntimeIsAnExplicitError() {
        XCTAssertThrowsError(try ChromiumRuntime(launcherFrameworkHandle: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Chromium is unavailable"))
        }
    }

    func testHandleWithoutCompleteSDKExportsIsRejected() throws {
        // Existing process image, not a fixture dylib or an arbitrary executable.
        let process = try XCTUnwrap(dlopen(nil, RTLD_LAZY))
        defer { dlclose(process) }
        XCTAssertThrowsError(try ChromiumRuntime(launcherFrameworkHandle: process)) { error in
            XCTAssertTrue(error.localizedDescription.contains("export missing"))
        }
    }

    func testCookieDTOUsesStableJSONAndNullableExpiry() throws {
        let cookie = ChromiumCookie(name: "session", value: "secret", domain: ".example.com",
                                    path: "/account", expires: nil, secure: true,
                                    httpOnly: true, sameSite: .lax)
        let data = try JSONEncoder().encode([cookie])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(object.count, 1)
        XCTAssertTrue(object[0]["expiry"] is NSNull)
        XCTAssertEqual(object[0]["sameSite"] as? String, "lax")
        XCTAssertEqual(try JSONDecoder().decode([ChromiumCookie].self, from: data), [cookie])
    }

    func testUnknownExtensionSourceCannotBeMistakenForStore() throws {
        let json = #"{"id":"fixture","name":"Fixture","version":"1","enabled":true,"source":"future-source","userManageable":true,"disableReasons":0,"hasAction":false,"path":"/tmp/fixture","requestedOrigins":[],"allowedOrigins":[],"deniedPermissions":[]}"#
        let item = try JSONDecoder().decode(ChromiumExtension.self, from: Data(json.utf8))
        XCTAssertEqual(item.source, .other)
        XCTAssertFalse(item.userManageable)
    }

    func testContextIdentityResolverMapsPresetsAndUnregisters() async throws {
        var api = CCSAPI()
        api.set_client = { client in
            guard let client else { return -1 }
            MainActor.assumeIsolated { registeredClient = client.pointee }
            return 0
        }
        api.context_open = { _, _, data, callback in
            contextOpenCount += 1
            callback?(data, OpaquePointer(bitPattern: 0x51), nil)
        }
        api.context_set_identity_resolver = { _, data, callback in
            guard let callback else { identityUnregisterCount += 1; return }
            "https://phone.example/".withCString { identityResults.append(callback(data, $0)) }
            "https://other.example/".withCString { identityResults.append(callback(data, $0)) }
            identityResults.append(callback(data, nil))
        }
        let runtime = ChromiumRuntime(api: api)
        try runtime.registerClient()
        let client = try XCTUnwrap(registeredClient)
        client.runtime_ready?(client.user_data)
        let context = try await runtime.openContext(profileKey: "identity-fixture")
        context.identityResolver = { $0.host == "phone.example" ? .androidPhone : .standard }
        XCTAssertEqual(identityResults, [1, 0, 0])
        let closed = await context.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(identityUnregisterCount, 1)
    }

    func testEmptyPrivateWindowKeyNeverOpensNormalStorage() async throws {
        let fixture = try await makePromptFixture()
        let before = contextOpenCount
        do {
            let context = try await fixture.runtime.openContext(profileKey: "fixture", privateWindowKey: "")
            _ = await context.close()
            XCTFail("An explicitly private context must never fall back to normal storage")
        } catch ChromiumError.operationFailed {}
        XCTAssertEqual(contextOpenCount, before)
    }

    func testFindRejectsNULBeforeCallingNative() async throws {
        let fixture = try await makePromptFixture()
        fixture.runtime.api.page_find_with_options = { _, _, _ in XCTFail("Truncated find reached native"); return 1 }
        XCTAssertThrowsError(try fixture.page.find("safe\0ignored"))
    }

    func testFindOptionsAndEmptyInitialSelection() async throws {
        let fixture = try await makePromptFixture()
        fixture.runtime.api.page_find_with_options = { _, _, options in
            nativeFindOptions = options
            return 12
        }
        fixture.runtime.api.page_copy_initial_find_text = { _, data, callback in
            callback?(data, nil, 0, nil)
        }
        XCTAssertEqual(try fixture.page.find("word", backwards: true,
            caseSensitive: true, highlightOnly: true), 12)
        XCTAssertEqual(nativeFindOptions, 7)
        let initial = try await fixture.page.initialFindText()
        XCTAssertEqual(initial, "")
        try fixture.page.find("word")
        XCTAssertEqual(nativeFindOptions, 0)
    }

    func testHistoryRejectsMalformedSnapshotsAndUsesStableEntryIdentity() async throws {
        let fixture = try await makePromptFixture()
        fixture.runtime.api.page_copy_navigation_history_json = { _, data, callback in
            nativePageData.withUnsafeBytes { bytes in
                callback?(data, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, nil)
            }
        }
        fixture.runtime.api.page_go_to_history_entry = { _, id in
            nativeHistoryEntryID = id
            return id == 42 ? 1 : 0
        }
        let entry = #"{"id":42,"url":"https://example.test/","title":"Fixture","canNavigate":true}"#
        nativePageData = Data("{\"schemaVersion\":1,\"currentIndex\":0,\"entries\":[\(entry)]}".utf8)
        let history = try await fixture.page.navigationHistory()
        let selected = try XCTUnwrap(history.currentEntry)
        XCTAssertEqual(selected.url.host, "example.test")
        try fixture.page.go(to: selected)
        XCTAssertEqual(nativeHistoryEntryID, 42)
        for invalid in [
            "{\"schemaVersion\":2,\"currentIndex\":0,\"entries\":[\(entry)]}",
            "{\"schemaVersion\":1,\"currentIndex\":1,\"entries\":[\(entry)]}",
            "{\"schemaVersion\":1,\"currentIndex\":0,\"entries\":[\(entry),\(entry)]}",
            "{\"schemaVersion\":1,\"currentIndex\":0,\"entries\":[]}",
            "{\"schemaVersion\":1,\"currentIndex\":0,\"entries\":[\(entry.replacingOccurrences(of: "42", with: "0"))]}",
            "{\"schemaVersion\":1,\"currentIndex\":0,\"entries\":[\(entry.replacingOccurrences(of: "https://example.test/", with: "relative/path"))]}",
            "{\"schemaVersion\":1,\"currentIndex\":0,\"entries\":[\(entry.replacingOccurrences(of: "Fixture", with: String(repeating: "x", count: 4097)))]}",
        ] {
            nativePageData = Data(invalid.utf8)
            do { _ = try await fixture.page.navigationHistory(); XCTFail("Invalid history accepted") }
            catch ChromiumError.operationFailed {} catch { XCTFail("Unexpected error: \(error)") }
        }
        fixture.runtime.api.page_go_to_history_entry = { _, _ in 0 }
        XCTAssertThrowsError(try fixture.page.go(to: selected))
        fixture.page.close()
        XCTAssertThrowsError(try fixture.page.go(to: selected))
    }

    func testNativeRuntimeIdentityRejectsMismatchAndCopiesBorrowedStrings() throws {
        var api = CCSAPI()
        api.get_runtime_info = { info in
            guard let info else { return 0 }
            info.pointee.abi_version = UInt32(CCS_ABI_VERSION)
            info.pointee.chromium_version_utf8 = nativeVersion
            info.pointee.chromium_revision_utf8 = nativeRevision
            return 1
        }
        let runtime = ChromiumRuntime(api: api)
        let info = try "153.0.8010.37".withCString { version in
            try "fixture-revision".withCString { revision in
                nativeVersion = version; nativeRevision = revision
                defer { nativeVersion = nil; nativeRevision = nil }
                return try runtime.runtimeInfo()
            }
        }
        XCTAssertEqual(info.chromiumVersion, "153.0.8010.37")
        XCTAssertEqual(info.chromiumRevision, "fixture-revision")
        XCTAssertEqual(info.abiVersion, 18)
        runtime.api.get_runtime_info = { info in info?.pointee.abi_version = 17; return 1 }
        XCTAssertThrowsError(try runtime.runtimeInfo())
    }

    func testNavigationDiagnosticsClearOnRecoveryAndIgnoreClosedPageUpdates() async throws {
        let fixture = try await makePromptFixture()
        var state = CCSPageStateV5()
        state.struct_size = UInt32(MemoryLayout<CCSPageStateV5>.size)
        state.load_progress = 0.4
        state.renderer_termination_status = -1
        state.navigation_id = 52
        state.navigation_error_code = -105
        "https://unreachable.example/".withCString { url in
            "net::ERR_NAME_NOT_RESOLVED".withCString { message in
                state.navigation_error_url_utf8 = url
                state.navigation_error_description_utf8 = message
                fixture.page.update(state)
            }
        }
        XCTAssertEqual(fixture.page.estimatedProgress, 0.4)
        XCTAssertEqual(fixture.page.navigationFailure?.code, -105)
        XCTAssertEqual(fixture.page.navigationFailure?.navigationID, 52)
        XCTAssertEqual(fixture.page.navigationFailure?.url.host, "unreachable.example")
        XCTAssertNil(fixture.page.rendererTerminationStatus)
        state.navigation_error_code = 0
        state.navigation_error_url_utf8 = nil
        state.navigation_error_description_utf8 = nil
        state.load_progress = 2
        state.document_ready = 1
        state.renderer_unresponsive = 1
        fixture.page.update(state)
        XCTAssertNil(fixture.page.navigationFailure)
        XCTAssertEqual(fixture.page.estimatedProgress, 1)
        XCTAssertTrue(fixture.page.isDocumentReady)
        XCTAssertTrue(fixture.page.isUnresponsive)
        state.load_progress = .nan
        state.renderer_unresponsive = 0
        state.renderer_termination_status = 3
        fixture.page.update(state)
        XCTAssertEqual(fixture.page.estimatedProgress, 0)
        XCTAssertFalse(fixture.page.isUnresponsive)
        XCTAssertEqual(fixture.page.rendererTerminationStatus, 3)
        fixture.page.close()
        state.load_progress = 0.9
        fixture.page.update(state)
        XCTAssertEqual(fixture.page.estimatedProgress, 0)
    }

    func testReadyWaitCanBeCancelledBeforeChromiumStarts() async throws {
        var api = CCSAPI()
        api.set_client = { client in
            MainActor.assumeIsolated { registeredClient = client?.pointee }
            return 0
        }
        let runtime = ChromiumRuntime(api: api)
        try runtime.registerClient()
        let client = try XCTUnwrap(registeredClient)
        let finished = expectation(description: "cancelled readiness wait")
        let waiting = Task { @MainActor in
            do {
                try await runtime.waitUntilReady()
                XCTFail("Cancelled readiness wait succeeded")
            } catch is CancellationError {
            } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        await Task.yield()
        waiting.cancel()
        await fulfillment(of: [finished], timeout: 1)
        // Release a broken implementation's waiter too, so failure cannot hang the suite.
        client.runtime_ready?(client.user_data)
        await waiting.value
    }

    func testLateReadyCallbacksCannotRestartStoppedRuntime() async throws {
        let fixture = try await makePromptFixture()
        fixture.client.runtime_will_stop?(fixture.client.user_data)
        fixture.runtime.onReady = { XCTFail("Stopped runtime became ready") }
        fixture.runtime.onUIReady = { XCTFail("Stopped runtime became UI ready") }
        fixture.client.runtime_ready?(fixture.client.user_data)
        fixture.client.runtime_ui_ready?(fixture.client.user_data)
        XCTAssertFalse(fixture.runtime.isReady)
        XCTAssertFalse(fixture.runtime.isUIReady)
    }

    func testMissingContextEntryPointFailsWithoutLeakingContinuation() async throws {
        let fixture = try await makePromptFixture()
        fixture.runtime.api.context_open = nil
        do {
            _ = try await fixture.runtime.openContext(profileKey: "fixture")
            XCTFail("Missing context API succeeded")
        } catch ChromiumError.notReady {}
    }

    func testExtensionContextCannotCrossRuntimeOwnership() async throws {
        let fixture = try await makePromptFixture()
        let other = ChromiumRuntime(api: CCSAPI())
        let foreign = ChromiumContext(runtime: other, handle: OpaquePointer(bitPattern: 42)!,
                                      profileKey: "fixture", privateWindowKey: nil)
        do {
            _ = try await fixture.runtime.installedExtensions(in: foreign)
            XCTFail("A foreign native context reached the runtime")
        } catch ChromiumExtensionError.operationFailed(let message) {
            XCTAssertTrue(message.contains("another runtime"))
        }
    }

    func testQuitWaitsForRuntimeReadyBeforeQueuedAppEvents() async throws {
        // Direct ABI ordering fixture; it does not load or prove Chromium.
        var api = CCSAPI()
        api.set_client = { client in
            guard let client else { return -1 }
            MainActor.assumeIsolated { registeredClient = client.pointee }
            return 0
        }
        api.schedule_profile_deletion = { _, data, callback in
            callback?(data, profileDeleteStatus, nil)
        }
        let runtime = ChromiumRuntime(api: api)
        var events: [String] = []
        runtime.onReady = { events.append("ready") }
        runtime.onQuitRequested = { events.append("quit:\($0)") }
        runtime.onReopen = { events.append("reopen") }
        runtime.onOpenURLs = { _ in events.append("urls") }
        try runtime.registerClient()
        let client = try XCTUnwrap(registeredClient)

        client.app_reopen?(client.user_data)
        "https://example.test".withCString { address in
            var addresses: [UnsafePointer<CChar>?] = [address]
            addresses.withUnsafeMutableBufferPointer {
                client.app_open_urls?(client.user_data, $0.baseAddress, 1)
            }
        }
        client.app_quit_requested?(client.user_data, 0)
        client.app_quit_requested?(client.user_data, 1)
        XCTAssertEqual(events, [])

        client.runtime_ready?(client.user_data)
        XCTAssertEqual(events, ["ready", "quit:true"])

        profileDeleteStatus = CCS_PROFILE_DELETE_LOGICAL_COMMIT
        do {
            try await runtime.scheduleProfileDeletion(key: "fixture")
            XCTFail("Logical registration removal must not report physical deletion success")
        } catch ChromiumError.operationFailed {
        }
        profileDeleteStatus = CCS_PROFILE_DELETE_COMPLETED
        try await runtime.scheduleProfileDeletion(key: "fixture")
    }

    func testUnknownJavaScriptDialogKindCancelsNativeRequest() async throws {
        let fixture = try await makePromptFixture()
        fixture.runtime.onJavaScriptDialog = { presentedDialogKind = $0.kind }
        var value = CCSJavaScriptDialogRequestV1()
        value.struct_size = UInt32(MemoryLayout<CCSJavaScriptDialogRequestV1>.size)
        value.kind = CCSJavaScriptDialogKind(rawValue: numericCast(99))
        let handle = OpaquePointer(bitPattern: 0xD1)!
        fixture.client.javascript_dialog_requested?(
            fixture.client.user_data, fixture.page.handle, handle, &value)
        XCTAssertEqual(promptCancelCount, 1)
        XCTAssertNil(presentedDialogKind)
    }

    func testUnknownFileChooserModeCancelsNativeRequest() async throws {
        let fixture = try await makePromptFixture()
        fixture.runtime.onFileChooserRequest = { presentedChooserMode = $0.mode }
        var value = CCSFileChooserRequestV1()
        value.struct_size = UInt32(MemoryLayout<CCSFileChooserRequestV1>.size)
        value.mode = CCSFileChooserMode(rawValue: numericCast(99))
        let handle = OpaquePointer(bitPattern: 0xD2)!
        fixture.client.file_chooser_requested?(
            fixture.client.user_data, fixture.page.handle, handle, &value)
        XCTAssertEqual(promptCancelCount, 1)
        XCTAssertNil(presentedChooserMode)
    }

    func testUnusableLiveJavaScriptDialogRequestIsCancelled() async throws {
        let fixture = try await makePromptFixture()
        let handle = OpaquePointer(bitPattern: 0xD3)!
        fixture.client.javascript_dialog_requested?(
            fixture.client.user_data, fixture.page.handle, handle, nil)
        XCTAssertEqual(promptCancelCount, 1)
    }

    private struct PromptFixture {
        let runtime: ChromiumRuntime
        let client: CCSClientV13
        let page: ChromiumPage
    }

    func testCreatedPopupCarriesItsOwnDispositionAndKeepsLegacyCallback() async throws {
        let fixture = try await makePromptFixture()
        let hostID = UUID()
        var received: [(OpaquePointer, ChromiumPopupRequest.Disposition)] = []
        fixture.runtime.onPopupWithDisposition = { opener, child, disposition in
            XCTAssertTrue(opener === fixture.page)
            XCTAssertTrue(child.context === fixture.page.context)
            XCTAssertEqual(child.hostWindowID, hostID)
            received.append((child.handle, disposition))
        }
        let rawValues: [Int32] = [4, 3, 6, 5, 999]
        for (index, rawValue) in rawValues.enumerated() {
            let child = OpaquePointer(bitPattern: 0x30 + index)!
            hostID.uuidString.withCString {
                fixture.client.popup_created_with_disposition?(
                    fixture.client.user_data, fixture.page.handle, child, $0, rawValue)
            }
            XCTAssertEqual(received.last?.0, child)
        }
        XCTAssertEqual(received.map { $0.1 }, [.newBackgroundTab, .newForegroundTab, .newWindow, .newPopup, .unknown])
        fixture.runtime.onPopupWithDisposition = nil
        var legacyCount = 0
        fixture.runtime.onPopup = { _, _ in legacyCount += 1 }
        hostID.uuidString.withCString {
            fixture.client.popup_created_with_disposition?(
                fixture.client.user_data, fixture.page.handle, OpaquePointer(bitPattern: 0x40), $0, 3)
        }
        XCTAssertEqual(legacyCount, 1)
    }

    private func makePromptFixture() async throws -> PromptFixture {
        stubPageView = NSView()
        var api = CCSAPI()
        api.set_client = { client in
            guard let client else { return -1 }
            MainActor.assumeIsolated { registeredClient = client.pointee }
            return 0
        }
        api.context_open = { _, _, data, callback in
            contextOpenCount += 1
            callback?(data, OpaquePointer(bitPattern: 0x10), nil)
        }
        api.page_create = { _, _, _ in OpaquePointer(bitPattern: 0x20) }
        api.page_view = { _ in
            stubPageView.map { Unmanaged.passUnretained($0).toOpaque() }
        }
        api.javascript_dialog_resolve = { _, accept, _ in
            if accept == 0 { promptCancelCount += 1 }
            return 1
        }
        api.file_chooser_resolve = { _, paths, count in
            if paths == nil || count == 0 { promptCancelCount += 1 }
            return 1
        }
        let runtime = ChromiumRuntime(api: api)
        try runtime.registerClient()
        let client = try XCTUnwrap(registeredClient)
        client.runtime_ready?(client.user_data)
        let context = try await runtime.openContext(profileKey: "fixture")
        let page = try context.makePage(hostWindowID: UUID())
        return PromptFixture(runtime: runtime, client: client, page: page)
    }
}
