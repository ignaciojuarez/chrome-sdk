import CCobbleChromium
import Foundation

public enum ChromiumExtensionSource: String, Codable, Sendable {
    case store, unpacked, component, policy, other

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

public struct ChromiumExtension: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, name, version, enabled, source, userManageable, disableReasons
        case hasAction, path, requestedOrigins, allowedOrigins, deniedPermissions
    }
    public let id: String
    public let name: String
    public let version: String
    public let enabled: Bool
    public let source: ChromiumExtensionSource
    public let userManageable: Bool
    /// Chromium's DisableReason bitset, including permission increases and policy blocks.
    public let disableReasons: UInt32
    public let hasAction: Bool
    /// Canonical path from Chromium's installed extension registry. Cobble
    /// compares it with its managed copy before exposing the extension.
    public let path: String
    public let requestedOrigins: [String]
    public let allowedOrigins: [String]
    /// Permissions Cobble deliberately does not provide, such as native
    /// messaging. This is metadata only; callers must not treat it as a grant.
    public let deniedPermissions: [String]

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        source = try values.decode(ChromiumExtensionSource.self, forKey: .source)
        userManageable = try values.decode(Bool.self, forKey: .userManageable)
            && (source == .store || source == .unpacked)
        disableReasons = try values.decode(UInt32.self, forKey: .disableReasons)
        hasAction = try values.decode(Bool.self, forKey: .hasAction)
        path = try values.decode(String.self, forKey: .path)
        requestedOrigins = try values.decode([String].self, forKey: .requestedOrigins)
        allowedOrigins = try values.decode([String].self, forKey: .allowedOrigins)
        deniedPermissions = try values.decode([String].self, forKey: .deniedPermissions)
    }
}

public enum ChromiumExtensionError: LocalizedError {
    case privateContext
    case hostPermissionWithholdingRequired
    case unsupportedSurface(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .privateContext:
            "Extensions are unavailable in private Chromium contexts."
        case .hostPermissionWithholdingRequired:
            "Extension installation requires Chromium host-permission withholding."
        case .unsupportedSurface(let detail):
            detail
        case .operationFailed(let detail):
            detail
        }
    }
}

@MainActor public extension ChromiumRuntime {
    /// Lists extensions installed for this normal Chromium profile. Private
    /// contexts deliberately never expose the profile's extension registry.
    func installedExtensions(in context: ChromiumContext) async throws -> [ChromiumExtension] {
        try requireNormalExtensionContext(context)
        let json = try await extensionReply { data, callback in
            self.api.extension_list?(context.handle, data, callback)
        }
        return try decodeExtensionJSON(json)
    }

    /// Installs an unpacked source directory. Chromium refuses this operation
    /// unless its host-permission-withholding feature is enabled, so installs
    /// cannot begin with broad site access.
    func installUnpackedExtension(at sourceDirectory: URL,
                                  in context: ChromiumContext) async throws -> String {
        try requireNormalExtensionContext(context)
        guard sourceDirectory.isFileURL, sourceDirectory.path.hasPrefix("/"),
              !sourceDirectory.path.utf8.contains(0) else {
            throw ChromiumExtensionError.operationFailed(
                "The extension source directory must be an absolute file URL.")
        }
        let json = try await extensionReply { data, callback in
            sourceDirectory.path.withCString { source in
                self.api.extension_install_unpacked?(context.handle, source, data, callback)
            }
        }
        struct Result: Decodable { let id: String }
        let result: Result = try decodeExtensionJSON(json)
        return result.id
    }

    func setExtension(_ id: String,
                      enabled: Bool,
                      in context: ChromiumContext) async throws {
        try requireNormalExtensionContext(context)
        try requireExtensionIdentifier(id)
        _ = try await extensionReply { data, callback in
            id.withCString { identifier in
                self.api.extension_set_enabled?(context.handle, identifier,
                                                enabled ? 1 : 0, data, callback)
            }
        }
    }

    func removeExtension(_ id: String, from context: ChromiumContext) async throws {
        try requireNormalExtensionContext(context)
        try requireExtensionIdentifier(id)
        _ = try await extensionReply { data, callback in
            id.withCString { identifier in
                self.api.extension_remove?(context.handle, identifier, data, callback)
            }
        }
    }

    /// Grants or revokes this extension's access at an HTTP(S) site. Access
    /// remains withheld for every other site.
    func setExtension(_ id: String,
                      siteAccessAt url: URL,
                      allowed: Bool,
                      in context: ChromiumContext) async throws {
        try requireNormalExtensionContext(context)
        try requireExtensionIdentifier(id)
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ChromiumExtensionError.operationFailed("Site access requires an HTTP(S) URL.")
        }
        _ = try await extensionReply { data, callback in
            id.withCString { identifier in
                url.absoluteString.withCString { origin in
                    self.api.extension_set_site_access?(context.handle, identifier, origin,
                                                        allowed ? 1 : 0, data, callback)
                }
            }
        }
    }

    /// Runs a non-popup extension action. Popup and side-panel actions throw
    /// until Cobble supplies a native extension surface.
    func performExtensionAction(_ id: String,
                                on page: ChromiumPage,
                                in context: ChromiumContext) async throws {
        try requireNormalExtensionContext(context)
        try requireExtensionIdentifier(id)
        guard !page.isClosed, !page.isClosing else { throw ChromiumError.closed }
        guard page.context === context else {
            throw ChromiumExtensionError.operationFailed(
                "The extension action page does not belong to this context.")
        }
        _ = try await extensionReply { data, callback in
            id.withCString { identifier in
                self.api.extension_perform_action?(context.handle, page.handle,
                                                   identifier, data, callback)
            }
        }
    }
}

@MainActor private extension ChromiumRuntime {
    func requireExtensionIdentifier(_ id: String) throws {
        guard !id.utf8.contains(0) else {
            throw ChromiumExtensionError.operationFailed("An extension identifier cannot contain a null character.")
        }
    }

    func requireNormalExtensionContext(_ context: ChromiumContext) throws {
        guard context.runtime === self else {
            throw ChromiumExtensionError.operationFailed("The extension context belongs to another runtime.")
        }
        guard isReady, !context.isClosed, !context.isClosing else {
            throw ChromiumError.notReady
        }
        guard context.privateWindowKey == nil else {
            throw ChromiumExtensionError.privateContext
        }
    }

    func extensionReply(
        _ invoke: @escaping (UnsafeMutableRawPointer, CCSExtensionStringCallback) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = ExtensionRequest(continuation: continuation)
            let callback: CCSExtensionStringCallback = { data, value, error in
                MainActor.assumeIsolated {
                    guard let data else { return }
                    Unmanaged<ExtensionRequest>.fromOpaque(data).takeRetainedValue()
                        .finish(value: value, error: error)
                }
            }
            invoke(Unmanaged.passRetained(request).toOpaque(), callback)
        }
    }
}

@MainActor private final class ExtensionRequest {
    let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(value: UnsafePointer<CChar>?, error: UnsafePointer<CChar>?) {
        if let error {
            continuation.resume(throwing: extensionError(String(cString: error)))
        } else if let value {
            continuation.resume(returning: String(cString: value))
        } else {
            continuation.resume(throwing: ChromiumExtensionError.operationFailed(
                "Chromium returned an empty extension response."))
        }
    }
}

private func decodeExtensionJSON<T: Decodable>(_ json: String) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    } catch {
        throw ChromiumExtensionError.operationFailed("Chromium returned invalid extension data.")
    }
}

private func extensionError(_ detail: String) -> ChromiumExtensionError {
    if detail == "Extensions are unavailable in private contexts." {
        return .privateContext
    }
    if detail.contains("AllowWithholdingExtensionPermissionsOnInstall") {
        return .hostPermissionWithholdingRequired
    }
    if detail.contains("popups are not supported") || detail.contains("side panels are not supported") {
        return .unsupportedSurface(detail)
    }
    return .operationFailed(detail)
}
