import Foundation
import CobbleChromium

@MainActor
enum HarnessRepostValidation {
    static func run(runtime: ChromiumRuntime, token: String, origin: URL,
                    baseline: URL, reserveHost: () -> UUID,
                    showPage: (ChromiumPage) -> Void,
                    closeHost: ((UUID) -> Void)?,
                    activateBeforeUnload: ((ChromiumPage) async throws -> Void)? = nil)
                    async throws -> [String: Bool] {
        let previousDialog = runtime.onJavaScriptDialog
        defer { runtime.onJavaScriptDialog = previousDialog }

        let context = try await runtime.openContext(profileKey: "harness-repost")
        let host = reserveHost()
        let page = try context.makePage(url: baseline, hostWindowID: host)
        showPage(page)
        defer { closeHost?(host) }
        try await wait(page, url: baseline)

        var checks: [String: Bool] = [:]

        // Explicit SDK reload cancellation must retain the exact POST document.
        let cancelledSignature = try await loadCase("sdk-cancel", on: page,
                                                    token: token, origin: origin)
        var request = try await captureRequest(on: page, runtime: runtime) { page.reload() }
        checks["postRepostMetadata"] = validMetadata(request, page: page, origin: origin)
        checks["postRepostSDKCancelExactlyOnce"] = request.cancel() && !request.cancel() &&
            !request.accept() && !request.isPending
        try await Task.sleep(for: .milliseconds(300))
        let retainedSignature = try await signature(page)
        let cancelledStats = try await waitForStats("sdk-cancel", token: token,
                                                    origin: origin, postCount: 1)
        checks["postRepostSDKCancelRetainsDocument"] =
            page.title == title("sdk-cancel", count: 1, token: token) &&
            cancelledSignature == expectedSignature("sdk-cancel", token: token) &&
            retainedSignature == cancelledSignature && !page.hasPendingPrompt &&
            validStats(cancelledStats, name: "sdk-cancel", token: token, count: 1)

        // Accept resumes Chromium's deferred request rather than reconstructing it.
        let acceptedSignature = try await loadCase("sdk-accept", on: page,
                                                   token: token, origin: origin)
        request = try await captureRequest(on: page, runtime: runtime) { page.reload() }
        let accepted = request.accept() && !request.accept() && !request.cancel()
        try await wait(page, url: repostURL("sdk-accept", token: token, origin: origin),
                       title: title("sdk-accept", count: 2, token: token))
        let reloadedSignature = try await signature(page)
        let acceptedStats = try await waitForStats("sdk-accept", token: token,
                                                   origin: origin, postCount: 2)
        checks["postRepostSDKAcceptPreservesRequest"] = accepted &&
            acceptedSignature == expectedSignature("sdk-accept", token: token) &&
            reloadedSignature == acceptedSignature &&
            validStats(acceptedStats, name: "sdk-accept", token: token, count: 2)

        let originSignature = try await loadCase("origin-accept", on: page,
                                                 token: token, origin: origin)
        request = try await captureRequest(on: page, runtime: runtime) {
            do { try page.reloadFromOrigin(); return true } catch { return false }
        }
        let originAccepted = request.accept()
        try await wait(page, url: repostURL("origin-accept", token: token, origin: origin),
                       title: title("origin-accept", count: 2, token: token))
        let originReloadedSignature = try await signature(page)
        let originStats = try await waitForStats("origin-accept", token: token,
                                                 origin: origin, postCount: 2)
        checks["postRepostOriginAcceptPreservesRequest"] = originAccepted &&
            !request.cancel() &&
            originSignature == expectedSignature("origin-accept", token: token) &&
            originReloadedSignature == originSignature &&
            validStats(originStats, name: "origin-accept", token: token, count: 2)

        // A renderer reload uses the same owned request and continuation.
        var rendererRequest: ChromiumJavaScriptDialogRequest?
        runtime.onJavaScriptDialog = { incoming in
            guard incoming.page === page, incoming.kind == .formRepost else {
                incoming.cancel(); return
            }
            rendererRequest = incoming
            incoming.accept()
        }
        try page.load(startURL("renderer-accept", token: token, origin: origin,
                               renderer: true))
        try await wait(page, url: repostURL("renderer-accept", token: token, origin: origin),
                       title: title("renderer-accept", count: 2, token: token))
        checks["rendererPostRepostAccepted"] = rendererRequest.map {
            validMetadata($0, page: page, origin: origin) && !$0.isPending && !$0.accept()
        } ?? false
        let rendererSignature = try await signature(page)
        let rendererStats = try await waitForStats("renderer-accept", token: token,
                                                   origin: origin, postCount: 2)
        checks["rendererPostRepostPreservesRequest"] =
            rendererSignature == expectedSignature("renderer-accept", token: token) &&
            validStats(rendererStats, name: "renderer-accept", token: token, count: 2)

        // With no callback installed Chromium must deny instead of showing native UI.
        runtime.onJavaScriptDialog = nil
        try page.load(startURL("unhandled", token: token, origin: origin,
                               renderer: true))
        try await wait(page, url: repostURL("unhandled", token: token, origin: origin),
                       title: title("unhandled", count: 1, token: token))
        try await Task.sleep(for: .milliseconds(300))
        let unhandledDOM = try await page.currentDOM()
        let unhandledStats = try await waitForStats("unhandled", token: token,
                                                    origin: origin, postCount: 1)
        checks["unhandledPostRepostDenied"] =
            page.title == title("unhandled", count: 1, token: token) &&
            unhandledDOM.contains("data-reload-attempted=\"true\"") &&
            !page.hasPendingPrompt &&
            validStats(unhandledStats, name: "unhandled", token: token, count: 1)

        // Replacing the navigation cancels the suspended request exactly once.
        _ = try await loadCase("stale", on: page, token: token, origin: origin)
        request = try await captureRequest(on: page, runtime: runtime) { page.reload() }
        var staleCancellationCount = 0
        request.onCancel = { staleCancellationCount += 1 }
        try page.load(baseline)
        try await wait(page, url: baseline)
        try await waitForCondition("stale repost cancellation") { staleCancellationCount == 1 }
        checks["stalePostRepostCancelledOnce"] = !request.isPending &&
            staleCancellationCount == 1 && !request.accept() && !request.cancel()

        // Before-unload requires trusted activation; the driver owns that input path.
        if let activateBeforeUnload {
            _ = try await loadCase("beforeunload", on: page, token: token, origin: origin,
                                   beforeUnload: true)
            try await activateBeforeUnload(page)
            var requests: [ChromiumJavaScriptDialogRequest] = []
            runtime.onJavaScriptDialog = { incoming in
                guard incoming.page === page else { incoming.cancel(); return }
                requests.append(incoming)
                if requests.count == 1 { incoming.cancel() }
                else if incoming.kind == .beforeUnload { incoming.accept() }
                else { incoming.cancel() }
            }
            let firstReloadAccepted = page.reload()
            try await waitForCondition("cancelled before-unload", page: page) {
                requests.count == 1
            }
            let cancelledBeforeUnloadStats = try await waitForStats(
                "beforeunload", token: token, origin: origin, postCount: 1)
            checks["beforeUnloadCancelPreventsRepost"] = firstReloadAccepted &&
                requests.map(\.kind) == [.beforeUnload] &&
                validMetadata(requests[0], page: page, origin: origin,
                              kind: .beforeUnload) &&
                page.title == title("beforeunload", count: 1, token: token) &&
                validStats(cancelledBeforeUnloadStats, name: "beforeunload",
                           token: token, count: 1)
            let secondReloadAccepted = page.reload()
            try await waitForCondition("before-unload then repost", page: page) {
                requests.count == 3
            }
            let sameDocument = requests.count == 3 &&
                documentIdentity(requests[1]) == documentIdentity(requests[2])
            let beforeUnloadStats = try await waitForStats(
                "beforeunload", token: token, origin: origin, postCount: 1)
            checks["beforeUnloadPrecedesRepost"] = secondReloadAccepted &&
                requests.map(\.kind) == [.beforeUnload, .beforeUnload, .formRepost] &&
                validMetadata(requests[1], page: page, origin: origin,
                              kind: .beforeUnload) &&
                validMetadata(requests[2], page: page, origin: origin) &&
                sameDocument && page.title == title("beforeunload", count: 1, token: token) &&
                validStats(beforeUnloadStats, name: "beforeunload", token: token, count: 1) &&
                !page.hasPendingPrompt
        }

        // Closing the owning page cancels its outstanding request.
        let closingHost = reserveHost()
        let closingPage = try context.makePage(
            url: startURL("close", token: token, origin: origin),
            hostWindowID: closingHost)
        showPage(closingPage)
        try await wait(closingPage, url: repostURL("close", token: token, origin: origin),
                       title: title("close", count: 1, token: token))
        let closingRequest = try await captureRequest(on: closingPage, runtime: runtime) {
            closingPage.reload()
        }
        var closeCancellationCount = 0
        closingRequest.onCancel = { closeCancellationCount += 1 }
        closingPage.forceClose()
        let closed = await closingPage.waitUntilClosed()
        try await waitForCondition("closed-page repost cancellation", page: closingPage) {
            closeCancellationCount == 1
        }
        checks["closedPostRepostCancelledOnce"] = closed &&
            closeCancellationCount == 1 && !closingRequest.isPending &&
            !closingRequest.accept() && !closingRequest.cancel()
        closeHost?(closingHost)

        page.forceClose()
        guard await page.waitUntilClosed(), await context.close() else {
            throw Failure("Repost fixture page or context did not close.")
        }
        return checks
    }

    private static func captureRequest(on page: ChromiumPage, runtime: ChromiumRuntime,
                                       trigger: () -> Bool) async throws
        -> ChromiumJavaScriptDialogRequest {
        var result: ChromiumJavaScriptDialogRequest?
        runtime.onJavaScriptDialog = { incoming in
            guard incoming.page === page, incoming.kind == .formRepost else {
                incoming.cancel(); return
            }
            guard result == nil else { incoming.cancel(); return }
            result = incoming
        }
        guard trigger() else { throw Failure("Chromium refused a POST reload before publishing its prompt.") }
        try await waitForCondition("form repost prompt", page: page) { result != nil }
        return result!
    }

    private static func loadCase(_ name: String, on page: ChromiumPage,
                                 token: String, origin: URL,
                                 beforeUnload: Bool = false) async throws -> String {
        try page.load(startURL(name, token: token, origin: origin,
                               beforeUnload: beforeUnload))
        try await wait(page, url: repostURL(name, token: token, origin: origin),
                       title: title(name, count: 1, token: token))
        return try await signature(page)
    }

    private static func startURL(_ name: String, token: String, origin: URL,
                                 renderer: Bool = false,
                                 beforeUnload: Bool = false) -> URL {
        var parts = URLComponents(
            url: origin.appendingPathComponent("fixture/\(token)/repost-start"),
            resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "case", value: name)]
        if renderer { items.append(URLQueryItem(name: "renderer", value: "1")) }
        if beforeUnload { items.append(URLQueryItem(name: "beforeunload", value: "1")) }
        parts.queryItems = items
        return parts.url!
    }

    private static func repostURL(_ name: String, token: String, origin: URL) -> URL {
        var parts = URLComponents(
            url: origin.appendingPathComponent("fixture/\(token)/repost"),
            resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "case", value: name)]
        return parts.url!
    }

    private static func title(_ name: String, count: Int, token: String) -> String {
        "Cobble Repost \(name) \(count) \(token)"
    }

    private static func expectedSignature(_ name: String, token: String) -> String {
        "POST:" + Data("token=\(token)&case=\(name)".utf8).base64EncodedString()
    }

    private static func signature(_ page: ChromiumPage) async throws -> String {
        let dom = try await page.currentDOM()
        guard let method = attribute("data-request-method", in: dom),
              let body = attribute("data-request-body-base64", in: dom) else {
            throw Failure("POST response omitted its request signature.")
        }
        return "\(method):\(body)"
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=\"") else { return nil }
        let value = text[range.upperBound...]
        guard let end = value.firstIndex(of: "\"") else { return nil }
        return String(value[..<end])
    }

    private static func validMetadata(_ request: ChromiumJavaScriptDialogRequest,
                                      page: ChromiumPage, origin: URL,
                                      kind: ChromiumJavaScriptDialogRequest.Kind = .formRepost) -> Bool {
        request.page === page && request.kind == kind && request.isReload &&
            request.frameProcessID >= 0 && request.frameRoutingID >= 0 &&
            !request.frameToken.isEmpty && canonicalOrigin(request.requestingOrigin) == canonicalOrigin(origin) &&
            canonicalOrigin(request.topLevelOrigin) == canonicalOrigin(origin)
    }

    private static func documentIdentity(_ request: ChromiumJavaScriptDialogRequest) -> String {
        "\(request.frameProcessID):\(request.frameRoutingID):\(request.frameToken)"
    }

    private static func canonicalOrigin(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return canonicalOrigin(url)
    }

    private static func canonicalOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let defaultPort = scheme == "http" ? 80 : scheme == "https" ? 443 : nil
        return "\(scheme)://\(host)" + (url.port == nil || url.port == defaultPort ? "" : ":\(url.port!)")
    }

    private static func wait(_ page: ChromiumPage, url: URL,
                             title: String? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if page.isClosed { throw Failure("Repost validation page closed unexpectedly.") }
            if page.urlString == url.absoluteString, !page.isLoading,
               title == nil || page.title == title { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Timed out waiting for repost navigation to \(url.absoluteString); \(diagnostics(page)).")
    }

    private static func waitForCondition(_ description: String,
                                         page: ChromiumPage? = nil,
                                         condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = page.map { "; \(diagnostics($0))" } ?? ""
        throw Failure("Timed out waiting for \(description)\(state).")
    }

    private static func diagnostics(_ page: ChromiumPage) -> String {
        "url=\(page.urlString) title=\(page.title) loading=\(page.isLoading) crashed=\(page.isCrashed)"
    }

    private struct RepostStats: Decodable {
        let postCount: Int
        let nonPostCount: Int
        let bodyBase64: [String]
    }

    private static func waitForStats(_ name: String, token: String, origin: URL,
                                     postCount: Int) async throws -> RepostStats {
        let deadline = ContinuousClock.now + .seconds(12)
        var latest: RepostStats?
        while ContinuousClock.now < deadline {
            latest = try await fetchStats(name, token: token, origin: origin)
            if latest?.postCount == postCount { return latest! }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Timed out waiting for repost stats for \(name); postCount=\(latest?.postCount ?? -1) nonPostCount=\(latest?.nonPostCount ?? -1).")
    }

    private static func fetchStats(_ name: String, token: String,
                                   origin: URL) async throws -> RepostStats {
        var parts = URLComponents(
            url: origin.appendingPathComponent("fixture/\(token)/repost-stats"),
            resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "case", value: name)]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("Repost stats endpoint failed for \(name).")
        }
        return try JSONDecoder().decode(RepostStats.self, from: data)
    }

    private static func validStats(_ stats: RepostStats, name: String,
                                   token: String, count: Int) -> Bool {
        let body = Data("token=\(token)&case=\(name)".utf8).base64EncodedString()
        return stats.postCount == count && stats.nonPostCount == 0 &&
            stats.bodyBase64 == Array(repeating: body, count: count)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
