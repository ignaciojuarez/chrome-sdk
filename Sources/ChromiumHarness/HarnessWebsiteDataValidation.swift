import CobbleChromium
import Foundation

@MainActor
enum HarnessWebsiteDataValidation {
    struct URLs: Codable {
        let aSetup: URL
        let aRead: URL
        let subdomainSetup: URL
        let subdomainRead: URL
        let bSetup: URL
        let bRead: URL
        let ipSetup: URL
        let ipRead: URL
        let aCache: URL
        let oldCache: URL
        let newCache: URL
        let bCache: URL
        let cacheStats: URL
        let domainA: String
        let domainB: String
        let token: String

        static func load(from environment: [String: String]) -> Self? {
            guard let json = environment["COBBLE_CHROMIUM_WEBSITE_DATA_URLS"] else { return nil }
            return try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
        }
    }

    static func run(
        context: ChromiumContext,
        privateContext: ChromiumContext,
        page: ChromiumPage,
        urls: URLs,
        freshPage: (URL) throws -> ChromiumPage
    ) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]

        checks.merge(try await runCookieTransfer(
            context: context, privateContext: privateContext, token: urls.token)) { _, new in new }

        try await seed(page, urls.aSetup, label: "a", token: urls.token)
        try await seed(page, urls.subdomainSetup, label: "sub", token: urls.token)
        try await seed(page, urls.bSetup, label: "b", token: urls.token)
        try await seed(page, urls.ipSetup, label: "ip", token: urls.token)
        let seededA = try await state(page, urls.aRead, label: "a", token: urls.token)
        let seededSubdomain = try await state(
            page, urls.subdomainRead, label: "sub", token: urls.token)
        checks["siteDataSeededBeforeRemoval"] = seededA == "11111" && seededSubdomain == "11111"
        guard checks["siteDataSeededBeforeRemoval"] == true else {
            throw Failure("Website-data seed did not create all five parent and subdomain stores.")
        }
        _ = try await loadCache(freshPage, urls.aCache, key: "domain-a", token: urls.token)
        _ = try await loadCache(freshPage, urls.bCache, key: "domain-b", token: urls.token)
        let seededHits = try await cacheHits(urls.cacheStats)
        _ = try await loadCache(freshPage, urls.aCache, key: "domain-a", token: urls.token)
        checks["domainDiskCacheSeedConfirmed"] =
            try await cacheHits(urls.cacheStats)["domain-a"] == seededHits["domain-a"]

        try await context.removeWebsiteData(categories: .siteData, for: urls.domainA)
        let aAfterSiteRemoval = try await state(page, urls.aRead, label: "a", token: urls.token)
        let subAfterSiteRemoval = try await state(
            page, urls.subdomainRead, label: "sub", token: urls.token)
        checks["domainSiteDataRemovesParentAndSubdomain"] =
            aAfterSiteRemoval == "00000" && subAfterSiteRemoval == "00000"
        checks["domainSiteDataPreservesOtherDomain"] =
            try await state(page, urls.bRead, label: "b", token: urls.token) == "11111"
        _ = try await loadCache(freshPage, urls.aCache, key: "domain-a", token: urls.token)
        checks["siteDataOnlyPreservesHTTPDiskCache"] =
            try await cacheHits(urls.cacheStats)["domain-a"] == seededHits["domain-a"]

        try await seed(page, urls.aSetup, label: "a", token: urls.token)
        try await context.removeWebsiteData(categories: .cache, for: urls.domainA)
        checks["cacheOnlyPreservesSiteData"] =
            try await state(page, urls.aRead, label: "a", token: urls.token) == "11111"
        _ = try await loadCache(freshPage, urls.aCache, key: "domain-a", token: urls.token)
        checks["domainCacheRemovalEvictsDiskEntry"] =
            try await cacheHits(urls.cacheStats)["domain-a", default: 0] ==
                seededHits["domain-a", default: 0] + 1
        _ = try await loadCache(freshPage, urls.bCache, key: "domain-b", token: urls.token)
        checks["domainCacheRemovalPreservesOtherDomainDiskEntry"] =
            try await cacheHits(urls.cacheStats)["domain-b"] == seededHits["domain-b"]

        try await context.removeWebsiteData(categories: [.siteData, .cache], for: urls.domainA)
        checks["combinedDomainRemovalClearsSiteData"] =
            try await state(page, urls.aRead, label: "a", token: urls.token) == "00000"
        checks["combinedDomainRemovalPreservesOtherDomain"] =
            try await state(page, urls.bRead, label: "b", token: urls.token) == "11111"

        _ = try await loadCache(freshPage, urls.oldCache, key: "old", token: urls.token)
        let oldSeededHits = try await cacheHits(urls.cacheStats)
        _ = try await loadCache(freshPage, urls.oldCache, key: "old", token: urls.token)
        checks["recentOldDiskCacheSeedConfirmed"] =
            try await cacheHits(urls.cacheStats)["old"] == oldSeededHits["old"]
        try await Task.sleep(for: .seconds(2))
        let cutoff = Date()
        try await Task.sleep(for: .seconds(2))
        _ = try await loadCache(freshPage, urls.newCache, key: "new", token: urls.token)
        let newSeededHits = try await cacheHits(urls.cacheStats)
        _ = try await loadCache(freshPage, urls.newCache, key: "new", token: urls.token)
        checks["recentNewDiskCacheSeedConfirmed"] =
            try await cacheHits(urls.cacheStats)["new"] == newSeededHits["new"]
        let beforeRecentRemoval = try await cacheHits(urls.cacheStats)

        let invalidOperations: [() async throws -> Void] = [
            { try await context.removeWebsiteData(categories: .init(rawValue: 1 << 31)) },
            { try await context.removeWebsiteData(categories: .siteData,
                                                   for: "sub.cobble-a.test") },
            { try await context.removeWebsiteData(categories: .siteData, modifiedSince: cutoff) },
            { try await context.removeWebsiteData(categories: .cache,
                                                   modifiedSince: Date(timeIntervalSince1970: .infinity)) },
            { try await context.removeWebsiteData(categories: .cache,
                                                   modifiedSince: Date().addingTimeInterval(60)) },
            { try await privateContext.removeWebsiteData(categories: .siteData) },
        ]
        var rejected = 0
        for operation in invalidOperations {
            do { try await operation() } catch { rejected += 1 }
        }
        checks["invalidAndPrivateRemovalRejected"] = rejected == invalidOperations.count
        checks["rejectedRemovalDoesNotMutateOtherDomain"] =
            try await state(page, urls.bRead, label: "b", token: urls.token) == "11111"
        try await context.removeWebsiteData(categories: .siteData, for: "127.0.0.1")
        checks["canonicalIPAddressRemovalSupported"] =
            try await state(page, urls.ipRead, label: "ip", token: urls.token) == "00000"

        try await context.removeWebsiteData(categories: .cache, modifiedSince: cutoff)
        _ = try await loadCache(freshPage, urls.oldCache, key: "old", token: urls.token)
        _ = try await loadCache(freshPage, urls.newCache, key: "new", token: urls.token)
        let recentHits = try await cacheHits(urls.cacheStats)
        checks["recentCachePreservesOldDiskEntry"] =
            recentHits["old"] == beforeRecentRemoval["old"]
        checks["recentCacheEvictsNewDiskEntry"] =
            recentHits["new", default: 0] == beforeRecentRemoval["new", default: 0] + 1

        let beforeGlobalCacheRemoval =
            try await cacheHits(urls.cacheStats)["domain-b", default: 0]
        try await context.removeWebsiteData(categories: [.siteData, .cache])
        checks["globalAllTimeClearsOtherDomainSiteData"] =
            try await state(page, urls.bRead, label: "b", token: urls.token) == "00000"
        _ = try await loadCache(freshPage, urls.bCache, key: "domain-b", token: urls.token)
        checks["globalAllTimeEvictsHTTPDiskCache"] =
            try await cacheHits(urls.cacheStats)["domain-b", default: 0] ==
                beforeGlobalCacheRemoval + 1

        return checks
    }

    static func runCookieTransfer(context: ChromiumContext, privateContext: ChromiumContext,
                                  token: String) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let cookieHost = "cookie-transfer.test"
        let expires = floor(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let cookies = [
            ChromiumCookie(name: "host", value: token, domain: cookieHost,
                           path: "/", expires: nil, secure: true, httpOnly: true,
                           sameSite: .strict),
            ChromiumCookie(name: "domain", value: token,
                           domain: ".cookie-transfer.test", path: "/account",
                           expires: expires, secure: true, httpOnly: false,
                           sameSite: .lax),
        ]
        let seededCookies = try await context.replaceCookies(cookies, forHTTPSHost: cookieHost)
        let cookieSnapshot = try await context.cookies(forHTTPSHost: cookieHost)
        checks["cookieTransferPreservesHostOnlyDomainAndFields"] =
            seededCookies.imported == 2 && seededCookies.rejected == 0 &&
            cookieSnapshot.skipped == 0 && Set(cookieSnapshot.cookies.map(\.domain)) ==
                [cookieHost, ".cookie-transfer.test"] &&
            cookieSnapshot.cookies.contains(cookies[0]) &&
            cookieSnapshot.cookies.contains(cookies[1])
        do {
            _ = try await context.replaceCookies(
                [ChromiumCookie(name: "wrong", value: token, domain: "other.test",
                                path: "/", expires: nil, secure: true, httpOnly: true,
                                sameSite: .none)],
                forHTTPSHost: cookieHost)
            checks["cookieTransferRejectsWrongScopeBeforeMutation"] = false
        } catch {
            checks["cookieTransferRejectsWrongScopeBeforeMutation"] =
                try await context.cookies(forHTTPSHost: cookieHost) == cookieSnapshot
        }
        do {
            _ = try await privateContext.cookies(forHTTPSHost: cookieHost)
            checks["privateCookieTransferRejected"] = false
        } catch {
            checks["privateCookieTransferRejected"] = true
        }
        let clearedCookies = try await context.replaceCookies([], forHTTPSHost: cookieHost)
        let clearedSnapshot = try await context.cookies(forHTTPSHost: cookieHost)
        checks["emptyCookieReplacementPropagatesLogout"] =
            clearedCookies.deleted == 2 && clearedCookies.rejected == 0 &&
            clearedSnapshot.cookies.isEmpty
        return checks
    }

    private static func seed(_ page: ChromiumPage, _ url: URL, label: String,
                             token: String) async throws {
        let (navigationURL, navigation) = uniqueNavigation(url)
        try page.load(navigationURL)
        try await wait(page, title: "Cobble Website Data Ready \(label) \(token) \(navigation)")
    }

    private static func state(_ page: ChromiumPage, _ url: URL, label: String,
                              token: String) async throws -> String {
        let (navigationURL, navigation) = uniqueNavigation(url)
        try page.load(navigationURL)
        let prefix = "Cobble Website Data State "
        try await wait(page) {
            $0.urlString == navigationURL.absoluteString && !$0.isLoading &&
                $0.title.hasPrefix(prefix) && $0.title.hasSuffix(" \(label) \(token) \(navigation)")
        }
        return String(page.title.dropFirst(prefix.count).prefix(5))
    }

    private static func loadCache(_ freshPage: (URL) throws -> ChromiumPage, _ url: URL, key: String,
                                  token: String) async throws -> Int {
        let page = try freshPage(url)
        let prefix = "Cobble Disk Cache Loaded \(key) \(token) "
        try await wait(page) { $0.title.hasPrefix(prefix) && !$0.isLoading }
        guard let count = Int(page.title.dropFirst(prefix.count)) else {
            throw Failure("Website-data cache page returned an invalid server count.")
        }
        page.forceClose()
        guard await page.waitUntilClosed() else {
            throw Failure("Website-data cache page did not close.")
        }
        return count
    }

    private static func cacheHits(_ url: URL) async throws -> [String: Int] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("Website-data cache stats request failed.")
        }
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    private static func wait(_ page: ChromiumPage, title: String) async throws {
        try await wait(page) { $0.title == title && !$0.isLoading }
    }

    private static func wait(_ page: ChromiumPage,
                             condition: @escaping (ChromiumPage) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if page.isClosed { throw Failure("Website-data fixture page closed.") }
            if condition(page) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Timed out at \(page.urlString) with title \(page.title).")
    }

    private static func uniqueNavigation(_ url: URL) -> (URL, String) {
        let navigation = UUID().uuidString
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "navigation", value: navigation),
        ]
        return (components.url!, navigation)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
