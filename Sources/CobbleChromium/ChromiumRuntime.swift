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

public struct ChromiumRuntimeInfo: Sendable, Equatable {
    public let abiVersion: UInt32
    public let chromiumVersion: String
    public let chromiumRevision: String
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
    /// Opening intent from the exact created child, independent of popup policy.
    public var onPopupWithDisposition: ((ChromiumPage?, ChromiumPage, ChromiumPopupRequest.Disposition) -> Void)?
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
    var pages: [OpaquePointer: ChromiumPage] = [:]
    var contexts: [OpaquePointer: ChromiumContext] = [:]
    var downloads: [OpaquePointer: ChromiumDownload] = [:]
    var mediaRequests: [OpaquePointer: ChromiumMediaPermissionRequest] = [:]
    var javaScriptDialogs: [OpaquePointer: ChromiumJavaScriptDialogRequest] = [:]
    var httpAuthRequests: [OpaquePointer: ChromiumHTTPAuthRequest] = [:]
    var fileChoosers: [OpaquePointer: ChromiumFileChooserRequest] = [:]
    var externalProtocolRequests: [OpaquePointer: ChromiumExternalProtocolRequest] = [:]
    var clientCertificateRequests: [OpaquePointer: ChromiumClientCertificateRequest] = [:]
    private var extensionInstallRequests: [UInt64: OpaquePointer] = [:]
    var devToolsSessions: [OpaquePointer: ChromiumDevToolsSession] = [:]
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
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

    /// The loaded native framework's build identity, available before startup.
    public func runtimeInfo() throws -> ChromiumRuntimeInfo {
        var info = CCSRuntimeInfoV1()
        info.struct_size = UInt32(MemoryLayout<CCSRuntimeInfoV1>.size)
        guard api.get_runtime_info?(&info) == 1,
              info.abi_version == CCS_ABI_VERSION,
              let version = info.chromium_version_utf8,
              let revision = info.chromium_revision_utf8 else {
            throw ChromiumError.unavailable("The native runtime did not provide a matching build identity.")
        }
        return ChromiumRuntimeInfo(abiVersion: info.abi_version,
            chromiumVersion: String(cString: version), chromiumRevision: String(cString: revision))
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
        try Task.checkCancellation()
        if isReady { return }
        guard Self.active === self, !isStopping else { throw ChromiumError.notReady }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.readyWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
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
        var client = CCSClientV13()
        client.abi_version = UInt32(CCS_ABI_VERSION)
        client.struct_size = UInt32(MemoryLayout<CCSClientV13>.size)
        client.user_data = Unmanaged.passUnretained(self).toOpaque()
        client.runtime_ui_ready = { data in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard !runtime.isStopping, !runtime.isUIReady else { return }
                runtime.isUIReady = true
                runtime.onUIReady?()
                runtime.deliverPendingQuit()
            }
        }
        client.runtime_ready = { data in
            MainActor.assumeIsolated {
                guard let data else { return }
                let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(data).takeUnretainedValue()
                guard !runtime.isStopping, !runtime.isReady else { return }
                runtime.isReady = true
                let waiters = runtime.readyWaiters
                runtime.readyWaiters.removeAll()
                for waiter in waiters.values { waiter.resume() }
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
                for waiter in waiters.values { waiter.resume(throwing: ChromiumError.closed) }
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
                      snapshot.pointee.struct_size >= MemoryLayout<CCSPageStateV5>.size else { return }
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
        client.popup_created_with_disposition = { data, opener, child, hostWindowID, disposition in
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
                    if let callback = runtime.onPopupWithDisposition {
                        callback(parent, page, ChromiumPopupRequest.Disposition(rawValue: disposition) ?? .unknown)
                    } else if let callback = runtime.onPopup { callback(parent, page) }
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
                      snapshot.pointee.struct_size >= MemoryLayout<CCSDownloadStateV2>.size else { return }
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
        guard !profileKey.utf8.contains(0), !(privateWindowKey?.utf8.contains(0) ?? false) else {
            throw ChromiumError.operationFailed("Chromium profile keys cannot contain NUL bytes.")
        }
        guard privateWindowKey != "" else {
            throw ChromiumError.operationFailed("A private window requires a nonempty isolation key.")
        }
        try await waitUntilReady()
        guard isReady, !isStopping, let open = api.context_open else { throw ChromiumError.notReady }
        let context: ChromiumContext = try await withCheckedThrowingContinuation { continuation in
            let request = ContextRequest(runtime: self, profileKey: profileKey,
                privateWindowKey: privateWindowKey, continuation: continuation)
            let data = Unmanaged.passRetained(request).toOpaque()
            profileKey.withCString { profile in
                (privateWindowKey ?? "").withCString { privateKey in
                    open(profile, privateKey, data) { data, handle, error in
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

    func makePage(url: URL?, context: ChromiumContext,
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
