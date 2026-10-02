import Foundation
import CobbleChromium

@MainActor
enum HarnessPageValidation {
    static func run(page: ChromiumPage, baseline: URL) async throws -> [String: Bool] {
        let baseline = baseline.absoluteURL
        var checks: [String: Bool] = [:]
        try await wait("initial document", page: page) {
            page.urlString == baseline.absoluteString && !page.isLoading && page.isDocumentReady
        }
        checks["documentReadyAndProgress"] = page.estimatedProgress == 1 &&
            !page.isUnresponsive && page.rendererTerminationStatus == nil && page.navigationFailure == nil
        let failedURL = URL(string: "http://127.0.0.1:1/navigation-failure")!
        try page.load(failedURL)
        try await wait("structured navigation failure", page: page) {
            page.navigationFailure?.url == failedURL && !page.isLoading
        }
        checks["navigationFailureMetadata"] = page.navigationFailure.map {
            $0.code < 0 && $0.navigationID != 0 && !$0.message.isEmpty
        } ?? false
        var components = URLComponents(url: baseline, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "history", value: "second")]
        let secondURL = components.url!
        try page.load(secondURL)
        try await wait("navigation recovery", page: page) {
            page.urlString == secondURL.absoluteString && !page.isLoading && page.isDocumentReady
        }
        checks["navigationFailureClearsOnRecovery"] = page.navigationFailure == nil && page.estimatedProgress == 1

        let history = try await page.navigationHistory()
        guard let first = history.entries.first(where: { $0.url == baseline }),
              let second = history.currentEntry, second.url == secondURL, first.id != second.id else {
            throw ChromiumError.operationFailed("Native back/forward history omitted committed entries.")
        }
        try page.go(to: first)
        try await wait("history selection", page: page) {
            page.urlString == baseline.absoluteString && !page.isLoading && page.isDocumentReady
        }
        let selectedHistory = try await page.navigationHistory()
        checks["historyUsesStableEntryIdentity"] = selectedHistory.currentEntry?.id == first.id
        components.queryItems = (URLComponents(url: baseline, resolvingAgainstBaseURL: false)?.queryItems ?? []) +
            [URLQueryItem(name: "history", value: "third")]
        let thirdURL = components.url!
        try page.load(thirdURL)
        try await wait("pruned forward history", page: page) {
            page.urlString == thirdURL.absoluteString && !page.isLoading && page.isDocumentReady
        }
        do { try page.go(to: second); checks["staleHistoryEntryRejected"] = false }
        catch { checks["staleHistoryEntryRejected"] = true }
        try page.load(baseline)
        try await wait("baseline recovery", page: page) {
            page.urlString == baseline.absoluteString && !page.isLoading && page.isDocumentReady
        }

        let insensitive = try page.find("Cobble", highlightOnly: true)
        try await wait("case-insensitive find", page: page) {
            page.findResult?.requestID == insensitive && page.findResult?.isFinal == true
        }
        checks["findCaseInsensitiveCountsAllMatches"] = page.findResult?.matchCount == 3
        let sensitive = try page.find("Cobble", caseSensitive: true)
        try await wait("case-sensitive find", page: page) {
            page.findResult?.requestID == sensitive && page.findResult?.isFinal == true
        }
        checks["findCaseSensitiveCountsExactMatches"] = page.findResult?.matchCount == 1
        let initialText = try await page.initialFindText()
        checks["findInitialTextAvailable"] = initialText == "Cobble"
        try page.find("")
        checks["findEmptyClearsResults"] = page.findResult == nil
        guard checks.values.allSatisfy({ $0 }) else {
            let failed = checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")
            throw ChromiumError.operationFailed("Page API checks failed: \(failed)")
        }
        return checks
    }

    private static func wait(_ description: String, page: ChromiumPage, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !ready() {
            guard ContinuousClock.now < deadline else {
                throw ChromiumError.operationFailed("Timed out waiting for \(description): url=\(page.urlString), loading=\(page.isLoading), ready=\(page.isDocumentReady), progress=\(page.estimatedProgress), error=\(page.navigationFailure?.code ?? 0), closed=\(page.isClosed).")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
