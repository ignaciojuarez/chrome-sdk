import AppKit
import CCobbleChromium
import Observation

public struct ChromiumNavigationFailure: LocalizedError, Sendable, Equatable {
    public let navigationID: Int64
    public let code: Int32
    public let url: URL
    public let message: String
    public var errorDescription: String? { message }
}

public struct ChromiumNavigationHistory: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Identifiable {
        public let id: Int32
        public let url: URL
        public let title: String
        public let canNavigate: Bool
    }
    let schemaVersion: Int
    public let currentIndex: Int
    public let entries: [Entry]
    public var currentEntry: Entry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
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
    public private(set) var estimatedProgress: Double = 0
    public private(set) var isDocumentReady = false
    /// Whether the primary main-frame renderer is currently unresponsive.
    public private(set) var isUnresponsive = false
    /// Native base::TerminationStatus, available after the renderer exits.
    public private(set) var rendererTerminationStatus: Int32?
    public private(set) var navigationFailure: ChromiumNavigationFailure?
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

    func update(_ state: CCSPageStateV5) {
        guard !isClosed, !isClosing else { return }
        urlString = state.url_utf8.map { String(cString: $0) } ?? ""
        title = state.title_utf8.map { String(cString: $0) } ?? ""
        isLoading = state.loading != 0
        estimatedProgress = state.load_progress.isFinite ? min(1, max(0, state.load_progress)) : 0
        isDocumentReady = state.document_ready != 0
        isUnresponsive = state.renderer_unresponsive != 0
        rendererTerminationStatus = state.renderer_termination_status >= 0 ? state.renderer_termination_status : nil
        if state.navigation_error_code != 0,
           let address = state.navigation_error_url_utf8,
           let url = URL(string: String(cString: address)) {
            navigationFailure = ChromiumNavigationFailure(navigationID: state.navigation_id,
                code: state.navigation_error_code, url: url,
                message: state.navigation_error_description_utf8.map(String.init(cString:)) ?? "Navigation failed.")
        } else {
            navigationFailure = nil
        }
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

    func updateFind(_ result: CCSFindResultV1) {
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

    /// Starts or advances a native search. Empty text clears it. Highlight-only
    /// searches count matches without moving the selection. Results arrive asynchronously.
    @discardableResult public func find(_ text: String, backwards: Bool = false,
        caseSensitive: Bool = false, highlightOnly: Bool = false) throws -> Int32? {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard !text.utf8.contains(0) else {
            throw ChromiumError.operationFailed("Find text cannot contain NUL bytes.")
        }
        let options: UInt32 = (backwards ? 1 : 0) | (caseSensitive ? 2 : 0) | (highlightOnly ? 4 : 0)
        let requestID = text.withCString { runtime.api.page_find_with_options?(handle, $0, options) }
        guard let requestID, requestID >= 0 else { throw ChromiumError.operationFailed("Find is unavailable for this Chromium page.") }
        if text.isEmpty { findResult = nil }
        return requestID == 0 ? nil : requestID
    }

    /// Selected text, or Chromium's previous search text when there is no selection.
    public func initialFindText() async throws -> String {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard let operation = runtime.api.page_copy_initial_find_text else {
            throw ChromiumError.operationFailed("Initial find text is unavailable.")
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            let request = PageDataRequest(continuation: continuation, allowsEmpty: true)
            operation(handle, Unmanaged.passRetained(request).toOpaque(), pageDataCallback)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChromiumError.operationFailed("Chromium returned invalid find text.")
        }
        return text
    }

    /// A bounded snapshot of this tab's native back/forward list. This is not
    /// persistent browsing history and must not be persisted for private pages.
    public func navigationHistory() async throws -> ChromiumNavigationHistory {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard let operation = runtime.api.page_copy_navigation_history_json else {
            throw ChromiumError.operationFailed("Navigation history is unavailable.")
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            let request = PageDataRequest(continuation: continuation)
            operation(handle, Unmanaged.passRetained(request).toOpaque(), pageDataCallback)
        }
        guard data.count <= 4 * 1024 * 1024,
              let history = try? JSONDecoder().decode(ChromiumNavigationHistory.self, from: data),
              history.schemaVersion == 1, history.entries.count <= 512,
              history.currentIndex == -1 || history.entries.indices.contains(history.currentIndex),
              Set(history.entries.map(\.id)).count == history.entries.count,
              history.entries.allSatisfy({ $0.id > 0 && $0.url.scheme != nil &&
                  $0.url.absoluteString.utf8.count <= 65536 && $0.title.utf8.count <= 4096 }) else {
            throw ChromiumError.operationFailed("Chromium returned invalid navigation history.")
        }
        return history
    }

    /// Selects an existing entry by stable identity. Absent and local-file entries
    /// are rejected; use `openLocalFile` to renew local authorization. Native
    /// before-unload and POST confirmation still apply.
    public func go(to entry: ChromiumNavigationHistory.Entry) throws {
        guard !isClosed, !isClosing else { throw ChromiumError.closed }
        guard entry.canNavigate, entry.id > 0,
              runtime.api.page_go_to_history_entry?(handle, entry.id) == 1 else {
            throw ChromiumError.operationFailed("This navigation history entry is no longer available.")
        }
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

    func closeCancelled() {
        guard !isClosed, isClosing else { return }
        isClosing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
        onCloseCancelled?()
        onChange?()
    }

    func didClose() {
        guard !isClosed else { return }
        isClosed = true
        isClosing = false
        isLoading = false
        estimatedProgress = 0
        isDocumentReady = false
        isUnresponsive = false
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

    init(runtime: ChromiumRuntime, handle: OpaquePointer,
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

    func didClose() {
        guard !isClosed else { return }
        isClosed = true
        let callback = onClose
        onClose = nil
        callback?()
        runtime.api.devtools_session_release?(handle)
    }
}

private final class PageDataRequest: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>
    let allowsEmpty: Bool
    init(continuation: CheckedContinuation<Data, Error>, allowsEmpty: Bool = false) {
        self.continuation = continuation
        self.allowsEmpty = allowsEmpty
    }
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
    } else if length == 0 && request.allowsEmpty {
        request.continuation.resume(returning: Data())
    } else if let bytes, length > 0 {
        request.continuation.resume(returning: Data(bytes: bytes, count: length))
    } else {
        request.continuation.resume(
            throwing: ChromiumError.operationFailed("Chromium returned empty page data."))
    }
}
