import AppKit
import Foundation
import Darwin
import XCTest
import CCobbleChromium
@testable import CobbleChromium

@MainActor private var registeredClient: CCSClientV12?
nonisolated(unsafe) private var stubPageView: NSView?
nonisolated(unsafe) private var profileDeleteStatus = CCS_PROFILE_DELETE_COMPLETED
nonisolated(unsafe) private var promptCancelCount = 0
nonisolated(unsafe) private var presentedDialogKind: ChromiumJavaScriptDialogRequest.Kind?
nonisolated(unsafe) private var presentedChooserMode: ChromiumFileChooserRequest.Mode?
nonisolated(unsafe) private var identityResults: [Int32] = []
nonisolated(unsafe) private var identityUnregisterCount = 0

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
        let client: CCSClientV12
        let page: ChromiumPage
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
