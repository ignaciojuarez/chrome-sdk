import CCobbleChromium
import Foundation

@MainActor public final class ChromiumDownload {
    public let suggestedFilename: String
    public private(set) weak var page: ChromiumPage?
    public private(set) var originalURL: URL?
    public private(set) var currentURL: URL?
    public private(set) var mimeType: String?
    public private(set) var receivedBytes: Int64 = 0
    /// Nil means Chromium has not provided a positive total size.
    public private(set) var totalBytes: Int64?
    /// Native DownloadInterruptReason for the current failure; nil otherwise.
    public private(set) var interruptionReasonCode: Int32?
    public var onProgress: ((Int64, Int64) -> Void)?
    public var onFinish: (() -> Void)?
    /// A recoverable interruption keeps callbacks installed. Check `canResume`
    /// before treating a failure as terminal or disposing of the staging file.
    public var onFailure: ((Error) -> Void)?

    private unowned let runtime: ChromiumRuntime
    private var handle: OpaquePointer?
    private var destinationResolved = false
    private var isTerminal = false

    init(runtime: ChromiumRuntime, page: ChromiumPage?, handle: OpaquePointer,
         suggestedFilename: String) {
        self.runtime = runtime
        self.page = page
        self.handle = handle
        self.suggestedFilename = suggestedFilename
    }

    /// Supplies Chromium with Cobble's private staging file. Chromium keeps
    /// ownership of that file until a terminal callback has crossed its file
    /// sequence; the caller may then move or delete it.
    public func setDestination(_ url: URL?) {
        guard !isTerminal, !destinationResolved, let handle else { return }
        destinationResolved = true
        guard let url, url.isFileURL, !url.path.utf8.contains(0) else {
            runtime.api.download_set_destination?(handle, nil)
            return
        }
        url.path.withCString { runtime.api.download_set_destination?(handle, $0) }
    }

    public var canPause: Bool { controlState & 1 != 0 }
    public var canResume: Bool { controlState & 2 != 0 }
    public var isPaused: Bool { controlState & 4 != 0 }

    /// Controls the existing transfer. Chromium may offer a safe GET retry after
    /// an interruption; other interrupted and finished downloads cannot resume.
    public func pause() throws { try setPaused(true) }
    public func resume() throws { try setPaused(false) }

    private var controlState: UInt32 {
        guard !isTerminal, let handle else { return 0 }
        return runtime.api.download_get_control_state?(handle) ?? 0
    }

    private func setPaused(_ paused: Bool) throws {
        guard !isTerminal, let handle else { throw ChromiumError.closed }
        guard runtime.api.download_set_paused?(handle, paused ? 1 : 0) == 1 else {
            throw ChromiumError.operationFailed("This download cannot be paused or resumed.")
        }
    }

    public func cancel(completion: @escaping () -> Void) {
        guard let handle, let cancel = runtime.api.download_cancel else {
            completion()
            return
        }
        let request = DownloadCancelRequest { [weak self] in
            self?.markTerminal()
            completion()
        }
        cancel(handle, Unmanaged.passRetained(request).toOpaque(), downloadCancelCallback)
    }

    public func release() {
        guard let handle else { return }
        markTerminal()
        self.handle = nil
        runtime.downloads.removeValue(forKey: handle)
        runtime.api.download_release?(handle)
        page = nil
        onProgress = nil
        onFinish = nil
        onFailure = nil
    }

    func update(_ state: CCSDownloadStateV2) {
        guard handle != nil, !isTerminal else { return }
        originalURL = state.original_url_utf8.flatMap { $0.pointee == 0 ? nil : URL(string: String(cString: $0)) }
        currentURL = state.current_url_utf8.flatMap { $0.pointee == 0 ? nil : URL(string: String(cString: $0)) }
        mimeType = state.mime_type_utf8.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
        receivedBytes = max(0, state.received_bytes)
        totalBytes = state.total_bytes > 0 ? state.total_bytes : nil
        interruptionReasonCode = state.interrupt_reason == 0 ? nil : state.interrupt_reason
        switch state.status {
        case CCS_DOWNLOAD_IN_PROGRESS:
            onProgress?(state.received_bytes, state.total_bytes)
        case CCS_DOWNLOAD_COMPLETE:
            let callback = onFinish
            markTerminal()
            callback?()
        case CCS_DOWNLOAD_CANCELLED:
            let callback = onFailure
            markTerminal()
            callback?(CancellationError())
        case CCS_DOWNLOAD_FAILED:
            let message = state.error_utf8.map(String.init(cString:)) ??
                "Chromium could not complete the download."
            let callback = onFailure
            if !canResume { markTerminal() }
            callback?(ChromiumError.operationFailed(message))
        default:
            let callback = onFailure
            markTerminal()
            callback?(ChromiumError.operationFailed(
                "Chromium returned an unknown download state."))
        }
    }

    func runtimeStopped() {
        // Chromium's post-main-loop callback does not prove its file sequence
        // has drained. Invalidate without a terminal callback so clients leave
        // private staging data for OS cleanup instead of moving or deleting it.
        isTerminal = true
        handle = nil
        page = nil
        onProgress = nil
        onFinish = nil
        onFailure = nil
    }

    private func markTerminal() {
        isTerminal = true
        onProgress = nil
        onFinish = nil
        onFailure = nil
    }
}

@MainActor private final class DownloadCancelRequest {
    private var completion: (() -> Void)?

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    func finish() {
        let callback = completion
        completion = nil
        callback?()
    }
}

private let downloadCancelCallback: CCSDownloadCancelCallback = { data in
    guard let data else { return }
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        guard let data = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<DownloadCancelRequest>.fromOpaque(data).takeRetainedValue().finish()
    }
}
