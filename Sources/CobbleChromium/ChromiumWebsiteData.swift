import CCobbleChromium
import Foundation

public struct ChromiumWebsiteDataCategories: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let siteData = Self(rawValue: UInt32(CCS_WEBSITE_DATA_SITE_DATA.rawValue))
    public static let cache = Self(rawValue: UInt32(CCS_WEBSITE_DATA_CACHE.rawValue))
}

public struct ChromiumCookie: Codable, Sendable, Equatable {
    public enum SameSite: String, Codable, Sendable {
        case unspecified, none, lax, strict
    }

    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expires: Double?
    public let secure: Bool
    public let httpOnly: Bool
    public let sameSite: SameSite

    public init(name: String, value: String, domain: String, path: String,
                expires: Double?, secure: Bool, httpOnly: Bool, sameSite: SameSite) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    private enum CodingKeys: String, CodingKey {
        case name, value, domain, path, expiry, secure, httpOnly, sameSite
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
        domain = try values.decode(String.self, forKey: .domain)
        path = try values.decode(String.self, forKey: .path)
        expires = try values.decodeIfPresent(Double.self, forKey: .expiry)
        secure = try values.decode(Bool.self, forKey: .secure)
        httpOnly = try values.decode(Bool.self, forKey: .httpOnly)
        sameSite = try values.decode(SameSite.self, forKey: .sameSite)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(value, forKey: .value)
        try values.encode(domain, forKey: .domain)
        try values.encode(path, forKey: .path)
        if let expires { try values.encode(expires, forKey: .expiry) }
        else { try values.encodeNil(forKey: .expiry) }
        try values.encode(secure, forKey: .secure)
        try values.encode(httpOnly, forKey: .httpOnly)
        try values.encode(sameSite, forKey: .sameSite)
    }
}

public struct ChromiumCookieSnapshot: Codable, Sendable, Equatable {
    public let cookies: [ChromiumCookie]
    public let skipped: Int
}

public struct ChromiumCookieReplacement: Codable, Sendable, Equatable {
    public let deleted: Int
    public let imported: Int
    public let rejected: Int
}

@MainActor public extension ChromiumContext {
    func cookies(forHTTPSHost host: String) async throws -> ChromiumCookieSnapshot {
        guard runtime.isReady, !isClosed, !isClosing else { throw ChromiumError.notReady }
        guard privateWindowKey == nil else { throw privateDataError }
        guard !host.utf8.contains(0), let export = runtime.api.cookies_export else {
            throw ChromiumError.operationFailed("Choose a canonical HTTPS host.")
        }
        let json: String = try await withCheckedThrowingContinuation { continuation in
            let request = WebsiteDataValueRequest(continuation: continuation)
            host.withCString {
                export(handle, $0, Unmanaged.passRetained(request).toOpaque(), websiteDataCallback)
            }
        }
        do {
            return try JSONDecoder().decode(ChromiumCookieSnapshot.self, from: Data(json.utf8))
        } catch {
            throw ChromiumError.operationFailed("Chromium returned invalid cookies.")
        }
    }

    func replaceCookies(_ cookies: [ChromiumCookie], forHTTPSHost host: String) async throws
        -> ChromiumCookieReplacement {
        guard runtime.isReady, !isClosed, !isClosing else { throw ChromiumError.notReady }
        guard privateWindowKey == nil else { throw privateDataError }
        guard !host.utf8.contains(0), let replace = runtime.api.cookies_replace else {
            throw ChromiumError.operationFailed("Choose a canonical HTTPS host.")
        }
        let payload: Data
        do { payload = try JSONEncoder().encode(cookies) }
        catch { throw ChromiumError.operationFailed("Choose valid HTTPS cookies.") }
        guard let json = String(data: payload, encoding: .utf8) else {
            throw ChromiumError.operationFailed("Choose valid HTTPS cookies.")
        }
        let result: String = try await withCheckedThrowingContinuation { continuation in
            let request = WebsiteDataValueRequest(continuation: continuation)
            host.withCString { hostPointer in
                json.withCString { jsonPointer in
                    replace(handle, hostPointer, jsonPointer,
                            Unmanaged.passRetained(request).toOpaque(), websiteDataCallback)
                }
            }
        }
        do {
            return try JSONDecoder().decode(ChromiumCookieReplacement.self,
                                            from: Data(result.utf8))
        } catch {
            throw ChromiumError.operationFailed("Chromium returned an invalid cookie result.")
        }
    }

    /// Lists canonical site keys for modeled stored data: registrable domains,
    /// IP addresses, and internal hostnames. Pure HTTP-cache entries may not
    /// appear. Registrable domains include subdomains when removed; IP and
    /// internal-host keys match only themselves.
    func websiteDataSites() async throws -> [String] {
        guard runtime.isReady, !isClosed, !isClosing else { throw ChromiumError.notReady }
        guard privateWindowKey == nil else { throw privateDataError }
        guard let list = runtime.api.website_data_list_sites else { throw ChromiumError.notReady }
        let json: String = try await withCheckedThrowingContinuation { continuation in
            let request = WebsiteDataValueRequest(continuation: continuation)
            list(handle, Unmanaged.passRetained(request).toOpaque(), websiteDataCallback)
        }
        do {
            return try JSONDecoder().decode([String].self, from: Data(json.utf8))
        } catch {
            throw ChromiumError.operationFailed("Chromium returned invalid website data.")
        }
    }

    /// Removes selected unprotected web data globally or for one canonical
    /// registrable domain, IP address, or internal hostname. Registrable domains
    /// include subdomains; IP and internal hosts match only themselves. A cutoff
    /// supports cache only.
    /// CacheStorage is site data. Cached resources are Chromium's separate
    /// network/browser cache category. Domain removal filters network and
    /// storage-key caches, may clear shared GPU/connection cache state, and
    /// leaves some process-wide renderer/code caches for an all-profile clear.
    /// A cutoff may clear renderer and in-memory caches more broadly.
    func removeWebsiteData(
        categories: ChromiumWebsiteDataCategories,
        for domain: String? = nil,
        modifiedSince: Date? = nil
    ) async throws {
        guard runtime.isReady, !isClosed, !isClosing else { throw ChromiumError.notReady }
        guard privateWindowKey == nil else { throw privateDataError }
        guard domain?.utf8.contains(0) != true else {
            throw ChromiumError.operationFailed("Choose a valid website-data domain.")
        }
        guard let remove = runtime.api.website_data_remove else { throw ChromiumError.notReady }
        let contextHandle = handle

        let _: String = try await withCheckedThrowingContinuation { continuation in
            let request = WebsiteDataValueRequest(continuation: continuation)
            func start(_ domainPointer: UnsafePointer<CChar>?) {
                var removal = CCSWebsiteDataRemovalV1(
                    struct_size: UInt32(MemoryLayout<CCSWebsiteDataRemovalV1>.size),
                    category_mask: categories.rawValue,
                    registrable_domain_utf8: domainPointer,
                    modified_since_unix_seconds: modifiedSince?.timeIntervalSince1970 ?? 0,
                    all_time: modifiedSince == nil ? 1 : 0)
                remove(contextHandle, &removal, Unmanaged.passRetained(request).toOpaque(),
                       websiteDataCallback)
            }
            if let domain {
                domain.withCString { start($0) }
            } else {
                start(nil)
            }
        }
    }

    /// Removes cookies, storage, and domain-filterable cached resources for one
    /// listed site key. Registrable domains include subdomains; IP and internal
    /// hosts match only themselves. Shared cache state may also be cleared; some
    /// process-wide caches remain until an all-profile clear.
    func removeWebsiteData(for domain: String) async throws {
        try await removeWebsiteData(categories: [.siteData, .cache], for: domain)
    }

    /// Clears cached web resources for this normal profile while preserving
    /// cookies and persistent website storage.
    func clearCache() async throws {
        try await removeWebsiteData(categories: .cache)
    }

    private var privateDataError: ChromiumError {
        .operationFailed("Website data controls are unavailable in private contexts.")
    }
}

@MainActor private final class WebsiteDataValueRequest {
    let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(value: String?, error: String?) {
        if let error {
            continuation.resume(throwing: ChromiumError.operationFailed(error))
        } else if let value {
            continuation.resume(returning: value)
        } else {
            continuation.resume(throwing: ChromiumError.operationFailed(
                "Chromium returned an empty website-data response."))
        }
    }
}

private let websiteDataCallback: CCSWebsiteDataStringCallback = { data, value, error in
    guard let data else { return }
    let address = UInt(bitPattern: data)
    let value = value.map(String.init(cString:))
    let error = error.map(String.init(cString:))
    MainActor.assumeIsolated {
        guard let data = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<WebsiteDataValueRequest>.fromOpaque(data)
            .takeRetainedValue().finish(value: value, error: error)
    }
}
