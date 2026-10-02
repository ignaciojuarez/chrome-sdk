import Foundation
import CCobbleChromium

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

    init(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
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

    func cancelled() {
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

    init?(runtime: ChromiumRuntime, page: ChromiumPage, handle: OpaquePointer,
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
    func cancelled() {
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
    func cancelled() { finishCancellation() }
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
    func cancelled() { guard isPending else { return }; isPending = false; let callback = onCancel; onCancel = nil; callback?() }
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
        let result = withExtendedLifetime(strings) {
            pointers.withUnsafeBufferPointer {
                runtime.api.file_chooser_resolve?(handle, $0.baseAddress, $0.count)
            }
        }
        guard result == 1 else { return false }
        finishResolved(); return true
    }
    @discardableResult public func cancel() -> Bool {
        guard isPending, runtime.api.file_chooser_resolve?(handle, nil, 0) == 1 else { return false }
        finishResolved(); return true
    }
    private func finishResolved() { isPending = false; runtime.fileChoosers.removeValue(forKey: handle); onCancel = nil }
    func cancelled() { guard isPending else { return }; isPending = false; let callback = onCancel; onCancel = nil; callback?() }
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

    init?(runtime: ChromiumRuntime, page: ChromiumPage,
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
    func cancelled() {
        guard isPending else { return }
        isPending = false
        let callback = onCancel
        onCancel = nil
        callback?()
    }
}
