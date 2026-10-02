import Foundation
import CCobbleChromium

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
    var closesWhenEmpty = false
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

    func pageDidClose() {
        if closesWhenEmpty, !runtime.pages.values.contains(where: { $0.context === self && !$0.isClosed }) {
            Task { await close() }
        }
    }

    func release() {
        guard !isClosed else { return }
        identityResolver = nil
        onExtensionsChanged = nil
        isClosed = true
        isClosing = false
        runtime.contexts.removeValue(forKey: handle)
        runtime.api.context_release?(handle)
    }
}

@MainActor final class ContextRequest {
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
