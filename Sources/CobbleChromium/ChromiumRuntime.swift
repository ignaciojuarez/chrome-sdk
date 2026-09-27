import AppKit
import CCobbleChromium
import Observation

public enum ChromiumError: LocalizedError {
    case unavailable(String)
    case notReady
    case closed
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Chromium is unavailable: \(detail)"
        case .notReady: "Chromium has not finished starting."
        case .closed: "This Chromium page is closed."
        case .operationFailed(let detail): detail
        }
    }
}

public struct ChromiumMediaPermissionKinds: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let microphone = Self(rawValue: UInt32(CCS_MEDIA_PERMISSION_MICROPHONE.rawValue))
    public static let camera = Self(rawValue: UInt32(CCS_MEDIA_PERMISSION_CAMERA.rawValue))
}

/// A browser identity for the next top-level navigation. The host chooses this
/// from its saved URL and profile rules; no device geometry is changed.
public enum ChromiumBrowserIdentity: Int32, Sendable {
    case standard = 0
    case androidPhone = 1
    case androidTablet = 2
    case iPhone = 3
    case iPad = 4
}

public struct ChromiumPopupRequest {
    public enum Disposition: Int32, Sendable {
        case unknown = 0, currentTab, singletonTab, newForegroundTab
        case newBackgroundTab, newPopup, newWindow, saveToDisk, offTheRecord
        case ignoreAction, switchToTab, newPictureInPicture, newSplitView
    }
    public let opener: ChromiumPage
    public let openerURL: URL?
    public let topLevelURL: URL?
    public let requestingOrigin: URL?
    public let targetURL: URL?
    public let disposition: Disposition
    public let userGesture: Bool
    public let openerSuppressed: Bool
}

public struct ChromiumExtensionInstallRequest {
    public let id: UInt64
    public let page: ChromiumPage
    public let extensionID: String
    public let name: String
    public let sourceURL: URL?
    public let title: String
    public let permissionsHeading: String
    public let permissionWarnings: [String]
    public let canWithholdHostPermissions: Bool
    public let requestsHostPermissions: Bool
}

/// Register from the SDK launcher's client callback, before ChromeMain runs.
/// This object does not create a second NSApplication or own its event loop.
@MainActor public final class ChromiumRuntime {
    public private(set) var isUIReady = false
    public private(set) var isReady = false
    public var onUIReady: (() -> Void)?
    public var onReady: (() -> Void)?
    public var onWillStop: (() -> Void)?
    public var onQuitRequested: ((Bool) -> Void)?
    public var onReopen: (() -> Void)?
    public var onOpenURLs: (([URL]) -> Void)?
    public var onPopup: ((ChromiumPage?, ChromiumPage) -> Void)?
    public var popupPolicy: ((ChromiumPopupRequest) -> Bool)?
    public var onMediaPermissionRequest: ((ChromiumMediaPermissionRequest) -> Void)?
    public var onJavaScriptDialog: ((ChromiumJavaScriptDialogRequest) -> Void)?
    public var onHTTPAuthRequest: ((ChromiumHTTPAuthRequest) -> Void)?
    public var onFileChooserRequest: ((ChromiumFileChooserRequest) -> Void)?
    public var onExternalProtocolRequest: ((ChromiumExternalProtocolRequest) -> Void)?
    public var onClientCertificateRequest: ((ChromiumClientCertificateRequest) -> Void)?
    public var extensionInstallRequested: ((ChromiumExtensionInstallRequest) -> Void)?
    public var extensionInstallCancelled: ((UInt64) -> Void)?
    public var onDownload: ((ChromiumPage, ChromiumDownload) -> Void)?
    public var hostWindow: ((UUID, ChromiumPage?) -> NSWindow?)?
    var api: CCSAPI
    private var pendingURLs: [URL] = []
    private var pendingReopen = false
    private var pendingQuit: Bool?
    fileprivate var pages: [OpaquePointer: ChromiumPage] = [:]
    fileprivate var contexts: [OpaquePointer: ChromiumContext] = [:]
    var downloads: [OpaquePointer: ChromiumDownload] = [:]
    fileprivate var mediaRequests: [OpaquePointer: ChromiumMediaPermissionRequest] = [:]
    fileprivate var javaScriptDialogs: [OpaquePointer: ChromiumJavaScriptDialogRequest] = [:]
    fileprivate var httpAuthRequests: [OpaquePointer: ChromiumHTTPAuthRequest] = [:]
    fileprivate var fileChoosers: [OpaquePointer: ChromiumFileChooserRequest] = [:]
    fileprivate var externalProtocolRequests: [OpaquePointer: ChromiumExternalProtocolRequest] = [:]
    fileprivate var clientCertificateRequests: [OpaquePointer: ChromiumClientCertificateRequest] = [:]
    private var extensionInstallRequests: [UInt64: OpaquePointer] = [:]
    fileprivate var devToolsSessions: [OpaquePointer: ChromiumDevToolsSession] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var isStopping = false
    // Callback user_data must survive all Chromium shutdown callbacks.
    private static var active: ChromiumRuntime?

    /// Pass only the handle received by CCSClientMain from the native launcher.
    public init(launcherFrameworkHandle: UnsafeMutableRawPointer?) throws {
        var loaded = CCSAPI()
        var message = [CChar](repeating: 0, count: 2048)
        let result = CCSLoadAPIFromHandle(launcherFrameworkHandle, &loaded, &message, message.count)
        guard result == 0 else {
            throw ChromiumError.unavailable(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        api = loaded
    }

    init(api: CCSAPI) {
        self.api = api
    }

    private func deliverQuit(systemShutdown: Bool) {
        if let callback = onQuitRequested { callback(systemShutdown) }
        else { requestQuit() }
    }

    @discardableResult private func deliverPendingQuit() -> Bool {
        guard let systemShutdown = pendingQuit else { return false }
        pendingQuit = nil
        pendingReopen = false
        pendingURLs.removeAll()
        deliverQuit(systemShutdown: systemShutdown)
        return true
    }

    /// Waits for Chromium's initial profile and browser services. This is safe
    /// after registerClient returns, including from UI created by onUIReady.
    public func waitUntilReady() async throws {
        if isReady { return }
        guard Self.active === self, !isStopping else { throw ChromiumError.notReady }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    @discardableResult public func resolveExtensionInstall(_ id: UInt64, accept: Bool) -> Bool {
        guard let handle = extensionInstallRequests.removeValue(forKey: id) else { return false }
        return api.extension_install_resolve?(handle, accept ? 1 : 0) == 1
    }

    public func preflightProfileDeletion(key: String) async throws {
        guard isReady, let invoke = api.profile_deletion_preflight else { throw ChromiumError.notReady }
        try await profileDeletion(key: key, preflight: true, invoke: invoke)
    }

    /// Returns only after Chromium has unloaded the profile and verified its
    /// profile and cache directories are physically absent.
    public func scheduleProfileDeletion(key: String) async throws {
        guard isReady, let invoke = api.schedule_profile_deletion else { throw ChromiumError.notReady }
        try await profileDeletion(key: key, preflight: false, invoke: invoke)
    }

    private func profileDeletion(
        key: String, preflight: Bool,
        invoke: (UnsafePointer<CChar>?, UnsafeMutableRawPointer?, CCSProfileDeleteCallback?) -> Void
    ) async throws {
        guard !key.utf8.contains(0) else {
            throw ChromiumError.operationFailed("Chromium profile keys cannot contain NUL bytes.")
        }
        try await withCheckedThrowingContinuation { continuation in
            let request = ProfileDeleteRequest(preflight: preflight, continuation: continuation)
            key.withCString {
                invoke($0, Unmanaged.passRetained(request).toOpaque(), profileDeleteCallback)
            }
        }
    }

    /// Only one runtime may register per process. No unload/reinitialize path.
    public func registerClient() throws {
        guard Self.active == nil else {
            throw ChromiumError.unavailable("A Chromium client is already registered.")
        }
        var client = CCSClientV12()
        client.abi_version = UInt32(CCS_ABI_VERSION)
        client.struct_size = UInt32(MemoryLayout<CCSClientV12>.size)
        client.user_data = Unmanaged.passUnretained(self).toOpaque()
        client.runtime_ui_ready = { data in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.isUIReady = true
                runtime.onUIReady?()
                runtime.deliverPendingQuit()
            }
        }
        client.runtime_ready = { data in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.isReady = true
                let waiters = runtime.readyWaiters
                runtime.readyWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                runtime.onReady?()
                if runtime.deliverPendingQuit() { return }
                if runtime.pendingReopen { runtime.onReopen?() }
                runtime.pendingReopen = false
                if !runtime.pendingURLs.isEmpty { runtime.onOpenURLs?(runtime.pendingURLs) }
                runtime.pendingURLs.removeAll()
            }
        }
        client.runtime_will_stop = { data in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.isStopping = true
                runtime.isUIReady = false
                runtime.isReady = false
                let waiters = runtime.readyWaiters
                runtime.readyWaiters.removeAll()
                for waiter in waiters { waiter.resume(throwing: ChromiumError.closed) }
                for download in Array(runtime.downloads.values) { download.runtimeStopped() }
                runtime.downloads.removeAll()
                for request in runtime.mediaRequests.values { request.cancelled() }
                runtime.mediaRequests.removeAll()
                for request in runtime.javaScriptDialogs.values { request.cancelled() }
                runtime.javaScriptDialogs.removeAll()
                for request in runtime.httpAuthRequests.values { request.cancelled() }
                runtime.httpAuthRequests.removeAll()
                for request in runtime.fileChoosers.values { request.cancelled() }
                runtime.fileChoosers.removeAll()
                for request in runtime.externalProtocolRequests.values { request.cancelled() }
                runtime.externalProtocolRequests.removeAll()
                for request in runtime.clientCertificateRequests.values { request.cancelled() }
                runtime.clientCertificateRequests.removeAll()
                for id in runtime.extensionInstallRequests.keys { runtime.extensionInstallCancelled?(id) }
                runtime.extensionInstallRequests.removeAll()
                for session in Array(runtime.devToolsSessions.values) { session.didClose() }
                runtime.devToolsSessions.removeAll()
                runtime.onWillStop?()
                for page in runtime.pages.values { page.didClose() }
                runtime.pages.removeAll()
                for context in Array(runtime.contexts.values) { context.release() }
                runtime.contexts.removeAll()
            }
        }
        client.page_state_changed = { data, handle, snapshot in
            MainActor.assumeIsolated {
                guard let data, let handle, let snapshot,
                      snapshot.pointee.struct_size >= MemoryLayout<CCSPageStateV4>.size else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.pages[handle]?.update(snapshot.pointee)
            }
        }
        client.page_closed = { data, handle in
            MainActor.assumeIsolated {
                guard let data, let handle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.pages.removeValue(forKey: handle)?.didClose()
            }
        }
        client.page_close_cancelled = { data, handle in
            MainActor.assumeIsolated {
                guard let data, let handle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.pages[handle]?.closeCancelled()
            }
        }
        client.page_navigation_committed = { data, handle, address, title in
            MainActor.assumeIsolated {
                guard let data, let handle, let address,
                      let url = URL(string: String(cString: address)) else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let page = runtime.pages[handle], !page.isClosed, !page.isClosing else { return }
                page.onNavigationCommitted?(url, title.map { String(cString: $0) } ?? "")
            }
        }
        client.page_primary_main_frame_committed = { data, handle, address in
            MainActor.assumeIsolated {
                guard let data, let handle, let address,
                      let url = URL(string: String(cString: address)) else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let page = runtime.pages[handle], !page.isClosed, !page.isClosing else { return }
                page.onPrimaryMainFrameCommitted?(url)
            }
        }
        client.page_find_result = { data, handle, result in
            MainActor.assumeIsolated {
                guard let data, let handle, let result,
                      result.pointee.struct_size >= MemoryLayout<CCSFindResultV1>.size else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.pages[handle]?.updateFind(result.pointee)
            }
        }
        client.popup_created = { data, opener, child, hostWindowID in
            MainActor.assumeIsolated {
                guard let data, let child else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let hostWindowID,
                      let hostID = UUID(uuidString: String(cString: hostWindowID)) else {
                    runtime.retireUnhostedPage(child)
                    return
                }
                do {
                    guard let parent = opener.flatMap({ runtime.pages[$0] }) else {
                        runtime.retireUnhostedPage(child)
                        return
                    }
                    let page = try runtime.wrap(child, context: parent.context, hostWindowID: hostID)
                    if let callback = runtime.onPopup { callback(parent, page) }
                    else { runtime.forceCloseUnpresentedPage(page) }
                } catch { runtime.retireUnhostedPage(child) }
            }
        }
        client.download_created = { data, pageHandle, downloadHandle, filename in
            MainActor.assumeIsolated {
                guard let data, let downloadHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                let page = pageHandle.flatMap { runtime.pages[$0] }
                let download = ChromiumDownload(
                    runtime: runtime, page: page, handle: downloadHandle,
                    suggestedFilename: filename.map(String.init(cString:)) ?? "Download")
                runtime.downloads[downloadHandle] = download
                guard let page, let callback = runtime.onDownload else {
                    download.cancel { download.release() }
                    return
                }
                callback(page, download)
            }
        }
        client.download_state_changed = { data, handle, snapshot in
            MainActor.assumeIsolated {
                guard let data, let handle, let snapshot,
                      snapshot.pointee.struct_size >= MemoryLayout<CCSDownloadStateV1>.size else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.downloads[handle]?.update(snapshot.pointee)
            }
        }
        client.popup_requested = { data, value in
            MainActor.assumeIsolated {
                guard let data, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSPopupRequestV1>.size else { return 0 }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let openerHandle = value.pointee.opener,
                      let opener = runtime.pages[openerHandle],
                      let policy = runtime.popupPolicy else { return 0 }
                let stringURL: (UnsafePointer<CChar>?) -> URL? = {
                    $0.flatMap { URL(string: String(cString: $0)) }
                }
                let request = ChromiumPopupRequest(
                    opener: opener,
                    openerURL: stringURL(value.pointee.opener_url_utf8),
                    topLevelURL: stringURL(value.pointee.top_level_url_utf8),
                    requestingOrigin: stringURL(value.pointee.requesting_origin_utf8),
                    targetURL: stringURL(value.pointee.target_url_utf8),
                    disposition: ChromiumPopupRequest.Disposition(rawValue: value.pointee.disposition) ?? .unknown,
                    userGesture: value.pointee.user_gesture != 0,
                    openerSuppressed: value.pointee.opener_suppressed != 0)
                return policy(request) ? 1 : 0
            }
        }
        client.media_permission_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSMediaPermissionRequestV1>.size,
                      let page = runtime.pages[pageHandle],
                      let requestingOrigin = value.pointee.requesting_origin_utf8.flatMap({ URL(string: String(cString: $0)) }),
                      let embeddingOrigin = value.pointee.embedding_origin_utf8.flatMap({ URL(string: String(cString: $0)) }) else {
                    _ = runtime.api.media_permission_resolve?(requestHandle, 0)
                    return
                }
                let request = ChromiumMediaPermissionRequest(
                    runtime: runtime, page: page, handle: requestHandle,
                    id: value.pointee.request_id,
                    kinds: ChromiumMediaPermissionKinds(rawValue: value.pointee.kinds),
                    requestingOrigin: requestingOrigin, embeddingOrigin: embeddingOrigin,
                    frameProcessID: value.pointee.frame_process_id,
                    frameRoutingID: value.pointee.frame_routing_id,
                    frameToken: value.pointee.frame_token_utf8.map(String.init(cString:)) ?? "",
                    userGesture: value.pointee.user_gesture != 0)
                runtime.mediaRequests[requestHandle] = request
                if let callback = runtime.onMediaPermissionRequest { callback(request) }
                else { request.deny() }
            }
        }
        client.media_permission_cancelled = { data, requestHandle, _ in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.mediaRequests.removeValue(forKey: requestHandle)?.cancelled()
            }
        }
        client.javascript_dialog_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSJavaScriptDialogRequestV1>.size,
                      let page = runtime.pages[pageHandle],
                      let request = ChromiumJavaScriptDialogRequest(
                        runtime: runtime, page: page, handle: requestHandle,
                        value: value.pointee) else {
                    _ = runtime.api.javascript_dialog_resolve?(requestHandle, 0, nil)
                    return
                }
                runtime.javaScriptDialogs[requestHandle] = request
                if let callback = runtime.onJavaScriptDialog { callback(request) }
                else { request.cancel() }
            }
        }
        client.javascript_dialog_cancelled = { data, requestHandle, _ in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.javaScriptDialogs.removeValue(forKey: requestHandle)?.cancelled()
            }
        }
        client.http_auth_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSHTTPAuthRequestV1>.size,
                      let page = runtime.pages[pageHandle] else {
                    _ = runtime.api.http_auth_cancel?(requestHandle)
                    return
                }
                let request = ChromiumHTTPAuthRequest(
                    runtime: runtime, page: page, handle: requestHandle, value: value.pointee)
                runtime.httpAuthRequests[requestHandle] = request
                if let callback = runtime.onHTTPAuthRequest { callback(request) }
                else { request.cancel() }
            }
        }
        client.http_auth_cancelled = { data, requestHandle, _ in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.httpAuthRequests.removeValue(forKey: requestHandle)?.cancelled()
            }
        }
        client.file_chooser_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSFileChooserRequestV1>.size,
                      let page = runtime.pages[pageHandle],
                      let request = ChromiumFileChooserRequest(
                        runtime: runtime, page: page, handle: requestHandle,
                        value: value.pointee) else {
                    _ = runtime.api.file_chooser_resolve?(requestHandle, nil, 0)
                    return
                }
                runtime.fileChoosers[requestHandle] = request
                if let callback = runtime.onFileChooserRequest { callback(request) }
                else { request.cancel() }
            }
        }
        client.file_chooser_cancelled = { data, requestHandle, _ in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.fileChoosers.removeValue(forKey: requestHandle)?.cancelled()
            }
        }
        client.external_protocol_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSExternalProtocolRequestV1>.size,
                      let page = runtime.pages[pageHandle],
                      let request = ChromiumExternalProtocolRequest(
                        runtime: runtime, page: page, handle: requestHandle,
                        value: value.pointee) else {
                    _ = runtime.api.external_protocol_resolve?(requestHandle, 0)
                    return
                }
                runtime.externalProtocolRequests[requestHandle] = request
                if let callback = runtime.onExternalProtocolRequest { callback(request) }
                else { request.deny() }
            }
        }
        client.external_protocol_cancelled = { data, requestHandle, _ in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.externalProtocolRequests.removeValue(forKey: requestHandle)?.cancelled()
            }
        }
        client.devtools_session_closed = { data, sessionHandle in
            MainActor.assumeIsolated {
                guard let data, let sessionHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.devToolsSessions.removeValue(forKey: sessionHandle)?.didClose()
            }
        }
        client.client_certificate_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSClientCertificateRequestV1>.size,
                      let page = runtime.pages[pageHandle],
                      let request = ChromiumClientCertificateRequest(
                        runtime: runtime, page: page, handle: requestHandle,
                        value: value.pointee) else {
                    _ = runtime.api.client_certificate_cancel?(requestHandle)
                    return
                }
                runtime.clientCertificateRequests[requestHandle] = request
                if let callback = runtime.onClientCertificateRequest { callback(request) }
                else { request.cancel() }
            }
        }
        client.client_certificate_cancelled = { data, requestHandle, _ in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                runtime.clientCertificateRequests.removeValue(forKey: requestHandle)?.cancelled()
            }
        }
        client.extension_install_requested = { data, pageHandle, requestHandle, value in
            MainActor.assumeIsolated {
                guard let data, let requestHandle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let pageHandle, let value,
                      value.pointee.struct_size >= MemoryLayout<CCSExtensionInstallRequestV1>.size,
                      let page = runtime.pages[pageHandle],
                      !page.isClosed, !page.isClosing else {
                    _ = runtime.api.extension_install_resolve?(requestHandle, 0)
                    return
                }
                let state = value.pointee
                guard state.permission_warning_count <= 256,
                      state.permission_warning_count == 0 || state.permission_warnings_utf8 != nil else {
                    _ = runtime.api.extension_install_resolve?(requestHandle, 0)
                    return
                }
                let warnings = (0..<state.permission_warning_count).map { index in
                    state.permission_warnings_utf8?[index].map(String.init(cString:)) ?? ""
                }
                let request = ChromiumExtensionInstallRequest(
                    id: state.request_id, page: page,
                    extensionID: state.extension_id_utf8.map(String.init(cString:)) ?? "",
                    name: state.name_utf8.map(String.init(cString:)) ?? "",
                    sourceURL: state.source_url_utf8.flatMap { URL(string: String(cString: $0)) },
                    title: state.title_utf8.map(String.init(cString:)) ?? "",
                    permissionsHeading: state.permissions_heading_utf8.map(String.init(cString:)) ?? "",
                    permissionWarnings: warnings,
                    canWithholdHostPermissions: state.can_withhold_host_permissions != 0,
                    requestsHostPermissions: state.requests_host_permissions != 0)
                runtime.extensionInstallRequests[request.id] = requestHandle
                if let callback = runtime.extensionInstallRequested { callback(request) }
                else { _ = runtime.resolveExtensionInstall(request.id, accept: false) }
            }
        }
        client.extension_install_cancelled = { data, _, requestID in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                if runtime.extensionInstallRequests.removeValue(forKey: requestID) != nil {
                    runtime.extensionInstallCancelled?(requestID)
                }
            }
        }
        client.host_window = { data, hostWindowID, handle in
            let window: NSWindow? = MainActor.assumeIsolated {
                guard let data, let hostWindowID,
                      let hostID = UUID(uuidString: String(cString: hostWindowID)) else { return nil }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                return runtime.hostWindow?(hostID, handle.flatMap { runtime.pages[$0] })
            }
            return window.map { Unmanaged.passUnretained($0).toOpaque() }
        }
        client.page_activated = { data, handle in
            MainActor.assumeIsolated {
                guard let data, let handle else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard let page = runtime.pages[handle], !page.isClosed, !page.isClosing else { return }
                page.onActivate?()
            }
        }
        client.app_quit_requested = { data, systemShutdown in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                let shutdown = systemShutdown != 0
                if runtime.isUIReady { runtime.deliverQuit(systemShutdown: shutdown) }
                else { runtime.pendingQuit = (runtime.pendingQuit ?? false) || shutdown }
            }
        }
        client.app_reopen = { data in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                if runtime.isReady { runtime.onReopen?() }
                else { runtime.pendingReopen = true }
            }
        }
        client.app_open_urls = { data, strings, count in
            MainActor.assumeIsolated {
                guard let data, let strings else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                let urls = (0..<count).compactMap { index -> URL? in
                    guard let value = strings[index] else { return nil }
                    return URL(string: String(cString: value))
                }
                if runtime.isReady { runtime.onOpenURLs?(urls) }
                else { runtime.pendingURLs.append(contentsOf: urls) }
            }
        }
        guard api.set_client?(&client) == 0 else {
            throw ChromiumError.unavailable("The framework rejected this client ABI or startup order.")
        }
        Self.active = self
    }

    public func openContext(profileKey: String, privateWindowKey: String? = nil) async throws -> ChromiumContext {
        try await waitUntilReady()
        guard isReady, !isStopping else { throw ChromiumError.notReady }
        guard !profileKey.utf8.contains(0), !(privateWindowKey?.utf8.contains(0) ?? false) else {
            throw ChromiumError.operationFailed("Chromium profile keys cannot contain NUL bytes.")
        }
        let context: ChromiumContext = try await withCheckedThrowingContinuation { continuation in
            let request = ContextRequest(runtime: self, profileKey: profileKey,
                privateWindowKey: privateWindowKey, continuation: continuation)
            let data = Unmanaged.passRetained(request).toOpaque()
            profileKey.withCString { profile in
                (privateWindowKey ?? "").withCString { privateKey in
                    api.context_open?(profile, privateKey, data) { data, handle, error in
                        MainActor.assumeIsolated {
                            guard let data else { return }
                            let request = Unmanaged<ContextRequest>.fromOpaque(data).takeRetainedValue()
                            request.finish(handle: handle, error: error.map { String(cString: $0) })
                        }
                    }
                }
            }
        }
        if Task.isCancelled {
            await context.close()
            throw CancellationError()
        }
        return context
    }

    public func makePage(url: URL? = nil, profileKey: String, privateWindowKey: String? = nil,
                         hostWindowID: UUID) async throws -> ChromiumPage {
        let context = try await openContext(profileKey: profileKey, privateWindowKey: privateWindowKey)
        context.closesWhenEmpty = true
        do { return try context.makePage(url: url, hostWindowID: hostWindowID) }
        catch { await context.close(); throw error }
    }

    fileprivate func makePage(url: URL?, context: ChromiumContext,
                              hostWindowID: UUID) throws -> ChromiumPage {
        guard isReady, !context.isClosed, !context.isClosing else { throw ChromiumError.notReady }
        let handle = hostWindowID.uuidString.withCString { hostID in
            (url?.absoluteString ?? "about:blank").withCString {
                api.page_create?(context.handle, hostID, $0)
            }
        }
        guard let handle else { throw ChromiumError.unavailable("The page could not be created.") }
        do { return try wrap(handle, context: context, hostWindowID: hostWindowID) }
        catch {
            retireUnhostedPage(handle)
            throw error
        }
    }

    fileprivate func wrap(_ handle: OpaquePointer, context: ChromiumContext,
                          hostWindowID: UUID) throws -> ChromiumPage {
        if let page = pages[handle] { return page }
        guard let view = api.page_view?(handle) else {
            throw ChromiumError.unavailable("Chromium did not provide a native page view.")
        }
        let page = ChromiumPage(runtime: self, context: context, handle: handle,
            hostWindowID: hostWindowID,
            nativeView: Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue())
        pages[handle] = page
        return page
    }

    /// These paths never create a ChromiumPage wrapper, so this is the only release.
    private func retireUnhostedPage(_ handle: OpaquePointer) {
        guard isReady, pages[handle] == nil else { return }
        api.page_force_close?(handle)
        api.page_release?(handle)
    }

    /// A wrapped popup owns its own release through `didClose()`, but with no
    /// presentation callback it still needs a non-cancellable retirement.
    private func forceCloseUnpresentedPage(_ page: ChromiumPage) {
        guard isReady, !page.isClosed else { return }
        page.forceClose()
    }

    public func requestQuit() { api.request_quit?(0) }
    public func cancelQuit() { api.cancel_quit?() }

    static func testingReleaseClientRegistration() {
        active = nil
    }
}

@MainActor private final class ContextRequest {
    let runtime: ChromiumRuntime
    let profileKey: String
    let privateWindowKey: String?
    let continuation: CheckedContinuation<ChromiumContext, Error>

    init(runtime: ChromiumRuntime, profileKey: String, privateWindowKey: String?,
         continuation: CheckedContinuation<ChromiumContext, Error>) {
        self.runtime = runtime
        self.profileKey = profileKey
        self.privateWindowKey = privateWindowKey
        self.continuation = continuation
    }

    func finish(handle: OpaquePointer?, error: String?) {
        guard let handle else {
            continuation.resume(throwing: ChromiumError.unavailable(error ?? "Profile initialization failed."))
            return
        }
        guard runtime.isReady else {
            runtime.api.context_release?(handle)
            continuation.resume(throwing: ChromiumError.notReady)
            return
        }
        let context = ChromiumContext(runtime: runtime, handle: handle,
            profileKey: profileKey, privateWindowKey: privateWindowKey)
        runtime.contexts[handle] = context
        continuation.resume(returning: context)
    }
}

@MainActor public final class ChromiumMediaPermissionRequest {
    public let id: UInt64
    public let page: ChromiumPage
    public let kinds: ChromiumMediaPermissionKinds
    public let requestingOrigin: URL
    public let embeddingOrigin: URL
    public let frameProcessID: Int32
    public let frameRoutingID: Int32
    public let frameToken: String
    public let userGesture: Bool
    public private(set) var isPending = true
    public var onCancel: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    fileprivate init(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
                     id: UInt64, kinds: ChromiumMediaPermissionKinds,
                     requestingOrigin: URL, embeddingOrigin: URL,
                     frameProcessID: Int32, frameRoutingID: Int32,
                     frameToken: String, userGesture: Bool) {
        self.runtime = runtime
        self.page = page
        self.handle = handle
        self.id = id
        self.kinds = kinds
        self.requestingOrigin = requestingOrigin
        self.embeddingOrigin = embeddingOrigin
        self.frameProcessID = frameProcessID
        self.frameRoutingID = frameRoutingID
        self.frameToken = frameToken
        self.userGesture = userGesture
    }

    @discardableResult public func allow() -> Bool { resolve(allow: true) }
    @discardableResult public func deny() -> Bool { resolve(allow: false) }

    private func resolve(allow: Bool) -> Bool {
        guard isPending,
              runtime.api.media_permission_resolve?(handle, allow ? 1 : 0) == 1 else { return false }
        isPending = false
        runtime.mediaRequests.removeValue(forKey: handle)
        onCancel = nil
        return true
    }

    fileprivate func cancelled() {
        guard isPending else { return }
        isPending = false
        let callback = onCancel
        onCancel = nil
        callback?()
    }
}

public struct ChromiumClientCertificateChoice: Sendable {
    public let id: UInt64
    public let subject: String
    public let issuer: String
    /// Uppercase hexadecimal without DER INTEGER sign-padding zero octets.
    public let serialNumber: String
    public let validFrom: Date?
    public let validUntil: Date?
}

@MainActor public final class ChromiumClientCertificateRequest {
    public enum Context: Sendable {
        case document(frameProcessID: Int32, frameRoutingID: Int32, frameToken: String)
        case navigation(navigationID: Int64)
    }
    public let id: UInt64
    public let page: ChromiumPage
    public let challengerOrigin: String
    public let topLevelOrigin: String
    public let visiblePageOrigin: String
    public let context: Context
    public let primaryMainFrame: Bool
    public let choices: [ChromiumClientCertificateChoice]
    public let choicesTruncated: Bool
    public private(set) var isPending = true
    public var onCancel: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    fileprivate init?(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
                      value: CCSClientCertificateRequestV1) {
        guard value.choice_count > 0, value.choice_count <= 64, let nativeChoices = value.choices else { return nil }
        self.runtime = runtime; self.page = page; self.handle = handle; id = value.request_id
        challengerOrigin = value.challenger_origin_utf8.map(String.init(cString:)) ?? ""
        topLevelOrigin = value.top_level_origin_utf8.map(String.init(cString:)) ?? ""
        visiblePageOrigin = value.visible_page_origin_utf8.map(String.init(cString:)) ?? ""
        primaryMainFrame = value.primary_main_frame != 0
        choicesTruncated = value.choices_truncated != 0
        if value.is_navigation != 0 {
            guard value.navigation_id > 0 else { return nil }
            context = .navigation(navigationID: value.navigation_id)
        } else {
            let token = value.frame_token_utf8.map(String.init(cString:)) ?? ""
            guard value.frame_process_id >= 0, value.frame_routing_id >= 0, !token.isEmpty else { return nil }
            context = .document(frameProcessID: value.frame_process_id,
                                frameRoutingID: value.frame_routing_id, frameToken: token)
        }
        choices = (0..<value.choice_count).compactMap { index in
            let choice = nativeChoices[index]
            guard choice.struct_size >= MemoryLayout<CCSClientCertificateChoiceV1>.size else { return nil }
            let from = choice.valid_from_unix_seconds
            let until = choice.valid_until_unix_seconds
            return ChromiumClientCertificateChoice(
                id: choice.choice_id,
                subject: choice.subject_utf8.map(String.init(cString:)) ?? "",
                issuer: choice.issuer_utf8.map(String.init(cString:)) ?? "",
                serialNumber: choice.serial_utf8.map(String.init(cString:)) ?? "",
                validFrom: from > 0 ? Date(timeIntervalSince1970: TimeInterval(from)) : nil,
                validUntil: until > 0 ? Date(timeIntervalSince1970: TimeInterval(until)) : nil)
        }
        guard choices.count == value.choice_count else { return nil }
    }
    @discardableResult public func select(choiceID: UInt64) -> Bool {
        guard isPending, choices.contains(where: { $0.id == choiceID }),
              runtime.api.client_certificate_select?(handle, choiceID) == 1 else { return false }
        finishResolved(); return true
    }
    @discardableResult public func cancel() -> Bool {
        guard isPending, runtime.api.client_certificate_cancel?(handle) == 1 else { return false }
        finishResolved(); return true
    }
    private func finishResolved() {
        isPending = false
        runtime.clientCertificateRequests.removeValue(forKey: handle)
        onCancel = nil
    }
    fileprivate func cancelled() {
        guard isPending else { return }
        isPending = false
        let callback = onCancel
        onCancel = nil
        callback?()
    }
}

@MainActor public final class ChromiumJavaScriptDialogRequest {
    public enum Kind: Sendable { case alert, confirm, prompt, beforeUnload, formRepost }
    public let id: UInt64
    public let page: ChromiumPage
    public let kind: Kind
    public let requestingOrigin: String
    public let topLevelOrigin: String
    public let frameProcessID: Int32
    public let frameRoutingID: Int32
    public let frameToken: String
    public let message: String
    public let defaultText: String
    public let isReload: Bool
    public private(set) var isPending = true
    public var onCancel: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    init?(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
          value: CCSJavaScriptDialogRequestV1) {
        switch value.kind {
        case CCS_JAVASCRIPT_DIALOG_ALERT: kind = .alert
        case CCS_JAVASCRIPT_DIALOG_CONFIRM: kind = .confirm
        case CCS_JAVASCRIPT_DIALOG_PROMPT: kind = .prompt
        case CCS_JAVASCRIPT_DIALOG_BEFORE_UNLOAD: kind = .beforeUnload
        case CCS_JAVASCRIPT_DIALOG_FORM_REPOST: kind = .formRepost
        default: return nil
        }
        self.runtime = runtime; self.page = page; self.handle = handle; id = value.request_id
        requestingOrigin = value.requesting_origin_utf8.map(String.init(cString:)) ?? ""
        topLevelOrigin = value.top_level_origin_utf8.map(String.init(cString:)) ?? ""
        frameProcessID = value.frame_process_id; frameRoutingID = value.frame_routing_id
        frameToken = value.frame_token_utf8.map(String.init(cString:)) ?? ""
        message = value.message_utf8.map(String.init(cString:)) ?? ""
        defaultText = value.default_prompt_utf8.map(String.init(cString:)) ?? ""
        isReload = value.is_reload != 0
    }

    @discardableResult public func accept(promptText: String? = nil) -> Bool {
        resolve(accept: true, promptText: promptText)
    }
    @discardableResult public func cancel() -> Bool { resolve(accept: false, promptText: nil) }
    private func resolve(accept: Bool, promptText: String?) -> Bool {
        guard isPending else { return false }
        if let promptText, promptText.utf8.contains(0) { return false }
        let result: UInt8? = if let promptText {
            promptText.withCString { runtime.api.javascript_dialog_resolve?(handle, accept ? 1 : 0, $0) }
        } else {
            runtime.api.javascript_dialog_resolve?(handle, accept ? 1 : 0, nil)
        }
        guard result == 1 else { return false }
        isPending = false; runtime.javaScriptDialogs.removeValue(forKey: handle); onCancel = nil
        return true
    }
    fileprivate func cancelled() { finishCancellation() }
    private func finishCancellation() {
        guard isPending else { return }; isPending = false
        let callback = onCancel; onCancel = nil; callback?()
    }
}

@MainActor public final class ChromiumHTTPAuthRequest {
    public let id: UInt64
    public let page: ChromiumPage
    public let requestURL: URL?
    public let challengerOrigin: String
    public let topLevelOrigin: String
    public let scheme: String
    public let realm: String
    public let documentFrameToken: String
    public let networkProcessID: Int32
    public let networkRequestID: Int32
    public let isProxy: Bool
    public let firstAttempt: Bool
    public let primaryMainFrameNavigation: Bool
    public let navigation: Bool
    public private(set) var isPending = true
    public var onCancel: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    init(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
         value: CCSHTTPAuthRequestV1) {
        self.runtime = runtime; self.page = page; self.handle = handle; id = value.request_id
        requestURL = value.request_url_utf8.flatMap { URL(string: String(cString: $0)) }
        challengerOrigin = value.challenger_origin_utf8.map(String.init(cString:)) ?? ""
        topLevelOrigin = value.top_level_origin_utf8.map(String.init(cString:)) ?? ""
        scheme = value.scheme_utf8.map(String.init(cString:)) ?? ""
        realm = value.realm_utf8.map(String.init(cString:)) ?? ""
        documentFrameToken = value.document_frame_token_utf8.map(String.init(cString:)) ?? ""
        networkProcessID = value.network_process_id; networkRequestID = value.network_request_id
        isProxy = value.is_proxy != 0; firstAttempt = value.first_attempt != 0
        primaryMainFrameNavigation = value.primary_main_frame_navigation != 0
        navigation = value.navigation != 0
    }
    @discardableResult public func submit(username: String, password: String) -> Bool {
        guard isPending else { return false }
        guard !username.utf8.contains(0), !password.utf8.contains(0) else { return false }
        let result = username.withCString { user in password.withCString {
            runtime.api.http_auth_resolve?(handle, user, $0)
        }}
        guard result == 1 else { return false }
        finishResolved(); return true
    }
    @discardableResult public func cancel() -> Bool {
        guard isPending, runtime.api.http_auth_cancel?(handle) == 1 else { return false }
        finishResolved(); return true
    }
    private func finishResolved() { isPending = false; runtime.httpAuthRequests.removeValue(forKey: handle); onCancel = nil }
    fileprivate func cancelled() { guard isPending else { return }; isPending = false; let callback = onCancel; onCancel = nil; callback?() }
}

@MainActor public final class ChromiumFileChooserRequest {
    public enum Mode: Sendable { case open, openMultiple, uploadFolder, openDirectory, save }
    public let id: UInt64
    public let page: ChromiumPage
    public let mode: Mode
    public let requestingOrigin: String
    public let topLevelOrigin: String
    public let frameProcessID: Int32
    public let frameRoutingID: Int32
    public let frameToken: String
    public let title: String
    public let defaultFilename: String
    public let acceptedTypes: [String]
    public private(set) var isPending = true
    public var onCancel: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    init?(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
          value: CCSFileChooserRequestV1) {
        switch value.mode {
        case CCS_FILE_CHOOSER_OPEN: mode = .open
        case CCS_FILE_CHOOSER_OPEN_MULTIPLE: mode = .openMultiple
        case CCS_FILE_CHOOSER_UPLOAD_FOLDER: mode = .uploadFolder
        case CCS_FILE_CHOOSER_OPEN_DIRECTORY: mode = .openDirectory
        case CCS_FILE_CHOOSER_SAVE: mode = .save
        default: return nil
        }
        self.runtime = runtime; self.page = page; self.handle = handle; id = value.request_id
        requestingOrigin = value.requesting_origin_utf8.map(String.init(cString:)) ?? ""
        topLevelOrigin = value.top_level_origin_utf8.map(String.init(cString:)) ?? ""
        frameProcessID = value.frame_process_id; frameRoutingID = value.frame_routing_id
        frameToken = value.frame_token_utf8.map(String.init(cString:)) ?? ""
        title = value.title_utf8.map(String.init(cString:)) ?? ""
        defaultFilename = value.default_filename_utf8.map(String.init(cString:)) ?? ""
        if let values = value.accepted_types_utf8 {
            acceptedTypes = (0..<value.accepted_type_count).compactMap { values[$0].map(String.init(cString:)) }
        } else { acceptedTypes = [] }
    }
    @discardableResult public func select(_ urls: [URL]) -> Bool {
        guard isPending else { return false }
        if urls.isEmpty { return cancel() }
        guard mode == .openMultiple || urls.count == 1 else { return false }
        guard urls.allSatisfy({ $0.isFileURL && !$0.path.utf8.contains(0) }) else { return false }
        let strings = urls.map { $0.path as NSString }
        let pointers: [UnsafePointer<CChar>?] = strings.map(\.utf8String)
        guard pointers.allSatisfy({ $0 != nil }) else { return false }
        let result = pointers.withUnsafeBufferPointer {
            runtime.api.file_chooser_resolve?(handle, $0.baseAddress, $0.count)
        }
        guard result == 1 else { return false }
        finishResolved(); return true
    }
    @discardableResult public func cancel() -> Bool {
        guard isPending, runtime.api.file_chooser_resolve?(handle, nil, 0) == 1 else { return false }
        finishResolved(); return true
    }
    private func finishResolved() { isPending = false; runtime.fileChoosers.removeValue(forKey: handle); onCancel = nil }
    fileprivate func cancelled() { guard isPending else { return }; isPending = false; let callback = onCancel; onCancel = nil; callback?() }
}

/// A site-requested handoff to another application. Native has already blocked
/// Chromium's launcher; after `allow()` succeeds, the host may open `targetURL`.
@MainActor public final class ChromiumExternalProtocolRequest {
    public let id: UInt64
    public let page: ChromiumPage
    public let targetURL: URL
    public let requestingOrigin: String
    public let topLevelOrigin: String
    public let frameProcessID: Int32
    public let frameRoutingID: Int32
    public let frameToken: String
    public let userGesture: Bool
    public let isPrimaryMainFrame: Bool
    public let isFencedFrame: Bool
    public private(set) var isPending = true
    public var onCancel: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    fileprivate init?(runtime: ChromiumRuntime, page: ChromiumPage,
                      handle: OpaquePointer,
                      value: CCSExternalProtocolRequestV1) {
        guard let target = value.target_url_utf8.flatMap({
            URL(string: String(cString: $0))
        }) else { return nil }
        self.runtime = runtime; self.page = page; self.handle = handle
        id = value.request_id; targetURL = target
        requestingOrigin = value.requesting_origin_utf8.map(String.init(cString:)) ?? ""
        topLevelOrigin = value.top_level_origin_utf8.map(String.init(cString:)) ?? ""
        frameProcessID = value.frame_process_id
        frameRoutingID = value.frame_routing_id
        frameToken = value.frame_token_utf8.map(String.init(cString:)) ?? ""
        userGesture = value.user_gesture != 0
        isPrimaryMainFrame = value.primary_main_frame != 0
        isFencedFrame = value.fenced_frame != 0
    }

    @discardableResult public func allow() -> Bool { resolve(allow: true) }
    @discardableResult public func deny() -> Bool { resolve(allow: false) }
    private func resolve(allow: Bool) -> Bool {
        guard isPending,
              runtime.api.external_protocol_resolve?(handle, allow ? 1 : 0) == 1
        else { return false }
        isPending = false
        runtime.externalProtocolRequests.removeValue(forKey: handle)
        onCancel = nil
        return true
    }
    fileprivate func cancelled() {
        guard isPending else { return }
        isPending = false
        let callback = onCancel
        onCancel = nil
        callback?()
    }
}

/// Keep one context for an application profile/window identity. Close it only
/// after its pages finish closing; named private windows use separate OTR data.
@MainActor public final class ChromiumContext {
    public let profileKey: String
    public let privateWindowKey: String?
    public private(set) var isClosed = false
    public private(set) var isClosing = false
    /// Install before `makePage`. Called synchronously on Chromium's UI thread
    /// for top-level destinations, including native-created popups. Do not
    /// navigate or close the context from this callback.
    public var identityResolver: ((URL) -> ChromiumBrowserIdentity)? {
        didSet {
            guard !isClosed else { return }
            let callback: CCSIdentityResolver? = identityResolver == nil ? nil : { data, address in
                MainActor.assumeIsolated {
                    guard let data, let address,
                          let url = URL(string: String(cString: address)) else {
                        return ChromiumBrowserIdentity.standard.rawValue
                    }
                    let context = Unmanaged<ChromiumContext>.fromOpaque(data).takeUnretainedValue()
                    return (context.identityResolver?(url) ?? .standard).rawValue
                }
            }
            runtime.api.context_set_identity_resolver?(
                handle, callback == nil ? nil : Unmanaged.passUnretained(self).toOpaque(), callback)
        }
    }
    public var onExtensionsChanged: (() -> Void)? {
        didSet {
            guard !isClosed, privateWindowKey == nil else { return }
            let callback: CCSExtensionChangedCallback? = onExtensionsChanged == nil ? nil : { data in
                MainActor.assumeIsolated {
                    guard let data else { return }
                    let context = Unmanaged<ChromiumContext>.fromOpaque(data).takeUnretainedValue()
                    context.onExtensionsChanged?()
                }
            }
            runtime.api.extension_observe?(handle,
                callback == nil ? nil : Unmanaged.passUnretained(self).toOpaque(), callback)
        }
    }
    fileprivate var closesWhenEmpty = false
    let handle: OpaquePointer
    let runtime: ChromiumRuntime
    private var closeTask: Task<Bool, Never>?

    init(runtime: ChromiumRuntime, handle: OpaquePointer, profileKey: String, privateWindowKey: String?) {
        self.runtime = runtime
        self.handle = handle
        self.profileKey = profileKey
        self.privateWindowKey = privateWindowKey
    }

    public func makePage(url: URL? = nil, hostWindowID: UUID) throws -> ChromiumPage {
        try runtime.makePage(url: url, context: self, hostWindowID: hostWindowID)
    }

    @discardableResult public func close() async -> Bool {
        if let closeTask { return await closeTask.value }
        guard !isClosed else { return true }
        isClosing = true
        let task = Task { @MainActor in
            let pages = self.runtime.pages.values.filter { $0.context === self }
            pages.forEach { $0.close() }
            var allClosed = true
            for page in pages {
                if !(await page.waitUntilClosed()) { allClosed = false }
            }
            guard allClosed else { self.isClosing = false; return false }
            self.release()
            return true
        }
        closeTask = task
        let result = await task.value
        closeTask = nil
        return result
    }

    fileprivate func pageDidClose() {
        if closesWhenEmpty, !runtime.pages.values.contains(where: { $0.context === self && !$0.isClosed }) {
            Task { await close() }
        }
    }

    fileprivate func release() {
        guard !isClosed else { return }
        identityResolver = nil
        onExtensionsChanged = nil
        isClosed = true
        isClosing = false
        runtime.contexts.removeValue(forKey: handle)
        runtime.api.context_release?(handle)
    }
}

public struct ChromiumCertificateDetails: Sendable {
    public let subject: String
    public let issuer: String
    public let validFrom: Date?
    public let validUntil: Date?
}

public struct ChromiumMixedContentDetails: Sendable {
    public let displayed: Bool
    public let ran: Bool
    public let containedForm: Bool
    public let displayedWithCertificateErrors: Bool
    public let ranWithCertificateErrors: Bool
}

public struct ChromiumConnectionDetails: Sendable {
    public let url: URL
    public let connection: ChromiumPage.Connection
    public let certificate: ChromiumCertificateDetails?
    public let certificateChain: [ChromiumCertificateDetails]
    public let certificateChainTruncated: Bool
    public let certificateErrorCodes: [String]
    public let mixedContent: ChromiumMixedContentDetails
}

@MainActor @Observable public final class ChromiumPage {
    public enum Connection: Sendable { case unknown, empty, secure, mixed, insecure }
    public struct FindResult: Sendable, Equatable {
        public let requestID: Int32
        public let matchCount: Int
        public let activeMatchOrdinal: Int
        public let isFinal: Bool
    }
    public let nativeView: NSView
    public let context: ChromiumContext
    public private(set) var hostWindowID: UUID
    public private(set) var urlString = ""
    public private(set) var title = ""
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isCrashed = false
    public private(set) var isAudible = false
    public private(set) var isAudioMuted = false
    public private(set) var isCapturingMicrophone = false
    public private(set) var isCapturingCamera = false
    public private(set) var faviconPNG: Data?
    public private(set) var hoveredLink: String?
    public private(set) var hasPendingPrompt = false
    public private(set) var connection: Connection = .unknown
    public private(set) var securityErrorPage = false
    public private(set) var securityCertificateError = false
    public private(set) var securityDisplayedMixedContent = false
    public private(set) var securityRanMixedContent = false
    public private(set) var findResult: FindResult?
    public private(set) var isClosed = false
    public private(set) var isClosing = false
    public var onChange: (() -> Void)?
    public var onActivate: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onCloseCancelled: (() -> Void)?
    public var onNavigationCommitted: ((URL, String) -> Void)?
    public var onPrimaryMainFrameCommitted: ((URL) -> Void)?
    public var onFindResult: ((FindResult) -> Void)?
    @ObservationIgnored private let runtime: ChromiumRuntime
    @ObservationIgnored let handle: OpaquePointer
    @ObservationIgnored private var closeWaiters: [CheckedContinuation<Bool, Never>] = []

    init(runtime: ChromiumRuntime, context: ChromiumContext, handle: OpaquePointer,
         hostWindowID: UUID, nativeView: NSView) {
        self.runtime = runtime
        self.context = context
        self.handle = handle
        self.hostWindowID = hostWindowID
        self.nativeView = nativeView
    }

    fileprivate func update(_ state: CCSPageStateV4) {
        guard !isClosed, !isClosing else { return }
        urlString = state.url_utf8.map { String(cString: $0) } ?? ""
        title = state.title_utf8.map { String(cString: $0) } ?? ""
        isLoading = state.loading != 0
        canGoBack = state.can_go_back != 0
        canGoForward = state.can_go_forward != 0
        isCrashed = state.crashed != 0
        isAudible = state.audible != 0
        isAudioMuted = state.audio_muted != 0
        isCapturingMicrophone = state.capturing_microphone != 0
        isCapturingCamera = state.capturing_camera != 0
        if let bytes = state.favicon_png, state.favicon_png_size > 0 {
            faviconPNG = Data(bytes: bytes, count: state.favicon_png_size)
        } else {
            faviconPNG = nil
        }
        hoveredLink = state.hovered_link_utf8.map(String.init(cString:))
        hasPendingPrompt = state.has_pending_prompt != 0
        switch state.connection {
        case CCS_PAGE_CONNECTION_EMPTY: connection = .empty
        case CCS_PAGE_CONNECTION_SECURE: connection = .secure
        case CCS_PAGE_CONNECTION_MIXED: connection = .mixed
        case CCS_PAGE_CONNECTION_INSECURE: connection = .insecure
        default: connection = .unknown
        }
        securityErrorPage = state.security_error_page != 0
        securityCertificateError = state.security_certificate_error != 0
        securityDisplayedMixedContent = state.security_displayed_mixed_content != 0
        securityRanMixedContent = state.security_ran_mixed_content != 0
        onChange?()
    }

    fileprivate func updateFind(_ result: CCSFindResultV1) {
        guard !isClosed, !isClosing else { return }
        let value = FindResult(requestID: result.request_id,
                               matchCount: Int(result.match_count),
                               activeMatchOrdinal: Int(result.active_match_ordinal),
                               isFinal: result.final_update != 0)
        findResult = value
        onFindResult?(value)
    }

    public func load(_ url: URL) throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        url.absoluteString.withCString { runtime.api.page_load_url?(handle, $0) }
    }
    public func goBack() { if !isClosed && !isClosing { runtime.api.page_go_back?(handle) } }
    public func goForward() { if !isClosed && !isClosing { runtime.api.page_go_forward?(handle) } }
    @discardableResult public func reload() -> Bool {
        guard !isClosed, !isClosing else { return false }
        return runtime.api.page_reload?(handle) == 1
    }
    public func reloadFromOrigin() throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard runtime.api.page_reload_from_origin?(handle) == 1 else {
            throw ChromiumError.operationFailed("Reload from origin is unavailable for this Chromium page.")
        }
    }
    public func stop() { if !isClosed && !isClosing { runtime.api.page_stop?(handle) } }
    public func focus() { if !isClosed && !isClosing { runtime.api.page_focus?(handle) } }
    public func setVisible(_ visible: Bool) {
        if !isClosed && !isClosing { runtime.api.page_set_visible?(handle, visible ? 1 : 0) }
    }

    public func move(toHostWindowID hostWindowID: UUID) throws {
        guard !isClosed, !isClosing, !context.isClosed, !context.isClosing else {
            throw ChromiumError.closed
        }
        let moved = hostWindowID.uuidString.withCString {
            runtime.api.page_move_to_host?(handle, $0)
        }
        guard moved == 1 else {
            throw ChromiumError.operationFailed("The Chromium page could not move to that window.")
        }
        self.hostWindowID = hostWindowID
    }

    /// Starts or advances a case-insensitive search. Empty text clears it.
    /// Success means the request was accepted; matching happens asynchronously.
    @discardableResult public func find(_ text: String, backwards: Bool = false) throws -> Int32? {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        let requestID = text.withCString { runtime.api.page_find?(handle, $0, backwards ? 1 : 0) }
        guard let requestID, requestID >= 0 else { throw ChromiumError.operationFailed("Find is unavailable for this Chromium page.") }
        if text.isEmpty { findResult = nil }
        return requestID == 0 ? nil : requestID
    }

    public var zoomFactor: Double? {
        guard !isClosed, !isClosing, let value = runtime.api.page_get_zoom_factor?(handle),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Sets tab-local zoom using Chromium's supported bounds.
    public func setZoomFactor(_ factor: Double) throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard factor.isFinite, factor > 0 else {
            throw ChromiumError.operationFailed("Zoom must be a finite, positive factor.")
        }
        guard runtime.api.page_set_zoom_factor?(handle, factor) == 1 else {
            throw ChromiumError.operationFailed("Zoom is unavailable for this Chromium page.")
        }
    }

    public func printPage() throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard runtime.api.page_print?(handle) == 1 else {
            throw ChromiumError.operationFailed("Printing is unavailable for this Chromium page.")
        }
    }

    public func snapshotPNG() async throws -> Data {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard let capture = runtime.api.page_capture_viewport_png else {
            throw ChromiumError.operationFailed("Viewport capture is unavailable for this Chromium page.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = PageDataRequest(continuation: continuation)
            capture(handle, Unmanaged.passRetained(request).toOpaque(), pageDataCallback)
        }
    }

    public func currentDOM() async throws -> String {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard let operation = runtime.api.page_current_dom else {
            throw ChromiumError.operationFailed("Reading the current DOM is unavailable.")
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            let request = PageDataRequest(continuation: continuation)
            operation(handle, Unmanaged.passRetained(request).toOpaque(), pageDataCallback)
        }
        guard let dom = String(data: data, encoding: .utf8) else {
            throw ChromiumError.operationFailed("Chromium returned invalid UTF-8 for the current DOM.")
        }
        return dom
    }

    /// Chromium's native MHTML representation of the current primary page.
    public func webArchive() async throws -> Data {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard let operation = runtime.api.page_create_mhtml_archive else {
            throw ChromiumError.operationFailed("Creating an MHTML archive is unavailable.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = PageDataRequest(continuation: continuation)
            operation(handle, Unmanaged.passRetained(request).toOpaque(), pageDataCallback)
        }
    }

    /// Returns details for the exact currently visible security state. A nil
    /// result means Chromium has not initialized matching connection details.
    public func connectionDetails() async throws -> ChromiumConnectionDetails? {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard let operation = runtime.api.page_copy_connection_details_json else {
            throw ChromiumError.operationFailed("Connection details are unavailable.")
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            let request = PageDataRequest(continuation: continuation)
            operation(handle, Unmanaged.passRetained(request).toOpaque(), pageDataCallback)
        }
        let value: ConnectionDetailsPayload
        do {
            value = try JSONDecoder().decode(ConnectionDetailsPayload.self, from: data)
        } catch {
            throw ChromiumError.operationFailed("Chromium returned invalid connection details.")
        }
        guard value.schemaVersion == 1 else {
            throw ChromiumError.operationFailed("Chromium returned unsupported connection details.")
        }
        let chainPayload = value.certificateChain ?? []
        guard chainPayload.count <= 16,
              chainPayload.allSatisfy({
                  $0.subject.utf8.count <= 1024 && $0.issuer.utf8.count <= 1024
              }) else {
            throw ChromiumError.operationFailed("Chromium returned invalid certificate-chain details.")
        }
        guard value.available else { return nil }
        let connection: Connection
        switch value.connection {
        case "empty": connection = .empty
        case "secure": connection = .secure
        case "mixed": connection = .mixed
        case "insecure": connection = .insecure
        default: connection = .unknown
        }
        let certificate = value.certificate.map {
            ChromiumCertificateDetails(
                subject: $0.subject, issuer: $0.issuer,
                validFrom: $0.validFromUnixSeconds.map(Date.init(timeIntervalSince1970:)),
                validUntil: $0.validUntilUnixSeconds.map(Date.init(timeIntervalSince1970:)))
        }
        let certificateChain = chainPayload.map {
            ChromiumCertificateDetails(
                subject: $0.subject, issuer: $0.issuer,
                validFrom: $0.validFromUnixSeconds.map(Date.init(timeIntervalSince1970:)),
                validUntil: $0.validUntilUnixSeconds.map(Date.init(timeIntervalSince1970:)))
        }
        return ChromiumConnectionDetails(
            url: value.url, connection: connection, certificate: certificate,
            certificateChain: certificateChain,
            certificateChainTruncated: value.certificateChainTruncated ?? false,
            certificateErrorCodes: value.certificateErrorCodes,
            mixedContent: ChromiumMixedContentDetails(
                displayed: value.mixedContent.displayed,
                ran: value.mixedContent.ran,
                containedForm: value.mixedContent.containedForm,
                displayedWithCertificateErrors:
                    value.mixedContent.displayedWithCertificateErrors,
                ranWithCertificateErrors:
                    value.mixedContent.ranWithCertificateErrors))
    }

    /// Opens one exact, readable local regular file. Chromium reports success
    /// only after the selected file becomes the primary committed document.
    public func openLocalFile(_ url: URL) async throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard url.isFileURL, !url.absoluteString.utf8.contains(0),
              let open = runtime.api.page_open_local_file else {
            throw ChromiumError.operationFailed("Opening local files is unavailable.")
        }
        try await withCheckedThrowingContinuation { continuation in
            let request = LocalFileRequest(continuation: continuation)
            url.absoluteString.withCString {
                open(handle, $0, Unmanaged.passRetained(request).toOpaque(),
                     localFileCallback)
            }
        }
    }

    public func openDevTools(hostWindowID: UUID) throws -> ChromiumDevToolsSession {
        guard runtime.isReady, !isClosed, !isClosing, !hasPendingPrompt else {
            throw ChromiumError.notReady
        }
        guard let open = runtime.api.page_open_devtools,
              let sessionHandle = hostWindowID.uuidString.withCString({
                  open(handle, $0)
              }) else {
            throw ChromiumError.operationFailed("Chromium DevTools is unavailable for this page.")
        }
        guard runtime.api.devtools_session_is_closed?(sessionHandle) == 0,
              let view = runtime.api.devtools_session_view?(sessionHandle) else {
            _ = runtime.api.devtools_session_close?(sessionHandle)
            runtime.api.devtools_session_release?(sessionHandle)
            throw ChromiumError.operationFailed("Chromium DevTools closed before it was presented.")
        }
        let session = ChromiumDevToolsSession(
            runtime: runtime,
            handle: sessionHandle,
            nativeView: Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue())
        runtime.devToolsSessions[sessionHandle] = session
        return session
    }

    /// Mutes this tab's local/system output without pausing media or changing capture.
    public func setAudioMuted(_ muted: Bool) throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard runtime.api.page_set_audio_muted?(handle, muted ? 1 : 0) == 1 else {
            throw ChromiumError.operationFailed("Audio mute is unavailable for this Chromium page.")
        }
        guard let current = runtime.api.page_is_audio_muted?(handle) else {
            throw ChromiumError.operationFailed("Audio mute state is unavailable for this Chromium page.")
        }
        if (current != 0) != muted {
            throw ChromiumError.operationFailed("Chromium did not apply the requested audio mute state.")
        }
    }

    /// Stops every camera and microphone stream owned by this page.
    @discardableResult public func stopMediaCapture() -> Bool {
        guard !isClosed, !isClosing else { return false }
        return runtime.api.page_stop_media_capture?(handle) == 1
    }

    public func close() {
        guard !isClosed, !isClosing else { return }
        isClosing = true
        runtime.api.page_close?(handle)
    }

    /// Discard a page after the application has accepted data loss, or retire
    /// an orphaned page. This intentionally skips beforeunload confirmation.
    public func forceClose() {
        guard !isClosed else { return }
        isClosing = true
        runtime.api.page_force_close?(handle)
    }

    /// Returns false if closing was cancelled. A cancelled page remains usable.
    @discardableResult public func waitUntilClosed() async -> Bool {
        if isClosed { return true }
        guard isClosing else { return false }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    fileprivate func closeCancelled() {
        guard !isClosed, isClosing else { return }
        isClosing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
        onCloseCancelled?()
        onChange?()
    }

    fileprivate func didClose() {
        guard !isClosed else { return }
        isClosed = true
        isClosing = false
        isLoading = false
        let callback = onClose
        onClose = nil
        onCloseCancelled = nil
        onNavigationCommitted = nil
        onPrimaryMainFrameCommitted = nil
        onFindResult = nil
        onActivate = nil
        onChange = nil
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
        callback?()
        runtime.api.page_release?(handle)
        context.pageDidClose()
    }
}

@MainActor public final class ChromiumDevToolsSession {
    public let nativeView: NSView
    public private(set) var isClosed = false
    public var onClose: (() -> Void)?
    private let runtime: ChromiumRuntime
    private let handle: OpaquePointer

    fileprivate init(runtime: ChromiumRuntime, handle: OpaquePointer,
                     nativeView: NSView) {
        self.runtime = runtime
        self.handle = handle
        self.nativeView = nativeView
    }

    public func focus() {
        if !isClosed { runtime.api.devtools_session_focus?(handle) }
    }

    public func setVisible(_ visible: Bool) {
        if !isClosed {
            runtime.api.devtools_session_set_visible?(handle, visible ? 1 : 0)
        }
    }

    @discardableResult public func close() -> Bool {
        guard !isClosed else { return false }
        return runtime.api.devtools_session_close?(handle) == 1
    }

    fileprivate func didClose() {
        guard !isClosed else { return }
        isClosed = true
        let callback = onClose
        onClose = nil
        callback?()
        runtime.api.devtools_session_release?(handle)
    }
}

private final class ProfileDeleteRequest: @unchecked Sendable {
    let preflight: Bool
    let continuation: CheckedContinuation<Void, Error>
    init(preflight: Bool, continuation: CheckedContinuation<Void, Error>) {
        self.preflight = preflight
        self.continuation = continuation
    }
}

private let profileDeleteCallback: CCSProfileDeleteCallback = { data, status, error in
    guard let data else { return }
    let request = Unmanaged<ProfileDeleteRequest>.fromOpaque(data).takeRetainedValue()
    if (request.preflight && status == CCS_PROFILE_DELETE_READY) ||
       (!request.preflight && status == CCS_PROFILE_DELETE_COMPLETED) {
        request.continuation.resume()
    } else {
        let message = error.map(String.init(cString:)) ?? "Chromium could not delete the profile."
        request.continuation.resume(throwing: ChromiumError.operationFailed(message))
    }
}

private final class PageDataRequest: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>
    init(continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
}

private final class LocalFileRequest: @unchecked Sendable {
    let continuation: CheckedContinuation<Void, Error>
    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
}

private let localFileCallback: CCSPageDataCallback = { data, _, _, error in
    guard let data else { return }
    let request = Unmanaged<LocalFileRequest>.fromOpaque(data).takeRetainedValue()
    if let error {
        request.continuation.resume(
            throwing: ChromiumError.operationFailed(String(cString: error)))
    } else {
        request.continuation.resume()
    }
}

private struct ConnectionDetailsPayload: Decodable {
    struct Certificate: Decodable {
        let subject: String
        let issuer: String
        let validFromUnixSeconds: TimeInterval?
        let validUntilUnixSeconds: TimeInterval?
    }
    struct MixedContent: Decodable {
        let displayed: Bool
        let ran: Bool
        let containedForm: Bool
        let displayedWithCertificateErrors: Bool
        let ranWithCertificateErrors: Bool
    }
    let schemaVersion: Int
    let available: Bool
    let url: URL
    let connection: String
    let certificate: Certificate?
    let certificateChain: [Certificate]?
    let certificateChainTruncated: Bool?
    let certificateErrorCodes: [String]
    let mixedContent: MixedContent
}

private let pageDataCallback: CCSPageDataCallback = { data, bytes, length, error in
    guard let data else { return }
    let request = Unmanaged<PageDataRequest>.fromOpaque(data).takeRetainedValue()
    if let error {
        request.continuation.resume(
            throwing: ChromiumError.operationFailed(String(cString: error)))
    } else if let bytes, length > 0 {
        request.continuation.resume(returning: Data(bytes: bytes, count: length))
    } else {
        request.continuation.resume(
            throwing: ChromiumError.operationFailed("Chromium returned empty page data."))
    }
}
