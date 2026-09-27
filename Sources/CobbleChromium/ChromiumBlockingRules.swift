import Foundation
import CoreFoundation

/// A deliberately bounded subset of Chromium's native declarative rules.
/// No scripts, host grants, redirects, or response/header interception are installed.
public enum ChromiumBlockingRules {
    public static let maximumBytes = 1_000_000
    public static let bundledJSON = #"""
    [
      {"id":1,"action":{"type":"block"},"condition":{"urlFilter":"||doubleclick.net^","domainType":"thirdParty"}},
      {"id":2,"action":{"type":"block"},"condition":{"urlFilter":"||googlesyndication.com^","domainType":"thirdParty"}},
      {"id":3,"action":{"type":"block"},"condition":{"urlFilter":"||google-analytics.com^","domainType":"thirdParty"}}
    ]
    """#

    public static func files(json: String, exceptions: [String]) throws -> [String: Data] {
        guard json.utf8.count <= maximumBytes,
              var rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
              rules.count <= 10_000, exceptions.count <= 512 else {
            throw invalid("Choose a JSON array with at most 10,000 rules and 1 MB of data.")
        }
        var identifiers = Set<Int>()
        for rule in rules {
            guard Set(rule.keys).isSubset(of: ["id", "priority", "action", "condition"]),
                  let identifier = integer(rule["id"]), (1...1_000_000_000).contains(identifier),
                  identifiers.insert(identifier).inserted,
                  let priority = integer(rule["priority"] ?? 1), (1...10_000).contains(priority),
                  let action = rule["action"] as? [String: Any], Set(action.keys) == ["type"],
                  let type = action["type"] as? String, ["block", "allow"].contains(type),
                  let condition = rule["condition"] as? [String: Any], !condition.isEmpty else {
                throw invalid("Rules require unique positive IDs, priorities up to 10,000, a block or allow action, and a condition.")
            }
            try validate(condition)
        }
        for (index, origin) in Set(exceptions).sorted().enumerated() {
            guard let url = URL(string: origin), ["http", "https"].contains(url.scheme),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty else {
                throw invalid("Blocker exceptions require an exact HTTP or HTTPS origin.")
            }
            // Only a top-level navigation grants the exemption to its descendants.
            // Anchoring the slash preserves scheme, host and port boundaries.
            rules.append([
                "id": 2_000_000_000 + index, "priority": 10_001,
                "action": ["type": "allowAllRequests"],
                "condition": ["regexFilter": "^" + NSRegularExpression.escapedPattern(for: origin) + "/",
                              "resourceTypes": ["main_frame"]]
            ])
        }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Cobble Content Rules", "version": "1.0",
            "description": "Native request blocking managed by Cobble content settings.",
            "permissions": ["declarativeNetRequest"], "incognito": "not_allowed",
            "declarative_net_request": ["rule_resources": [["id": "cobble", "enabled": true, "path": "rules.json"]]]
        ]
        return ["manifest.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
                "rules.json": try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])]
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(Int32.max) else { return nil }
        return number.intValue
    }

    private static func validate(_ condition: [String: Any]) throws {
        let domainKeys: Set<String> = ["requestDomains", "excludedRequestDomains", "initiatorDomains", "excludedInitiatorDomains"]
        let resourceKeys: Set<String> = ["resourceTypes", "excludedResourceTypes"]
        let allowed = domainKeys.union(resourceKeys).union(["urlFilter", "domainType", "isUrlFilterCaseSensitive"])
        guard Set(condition.keys).isSubset(of: allowed),
              condition["resourceTypes"] == nil || condition["excludedResourceTypes"] == nil else {
            throw invalid("Unsupported rule condition. Use URL filters, domains, resource types or first/third-party matching.")
        }
        if let value = condition["urlFilter"] {
            guard let filter = value as? String, !filter.isEmpty, filter.utf8.count <= 2_048,
                  filter.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
                throw invalid("URL filters must contain 1–2,048 printable ASCII bytes.")
            }
        }
        if let value = condition["domainType"] {
            guard let type = value as? String, ["firstParty", "thirdParty"].contains(type) else {
                throw invalid("Domain type must be firstParty or thirdParty.")
            }
        }
        if let value = condition["isUrlFilterCaseSensitive"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw invalid("isUrlFilterCaseSensitive must be a Boolean.")
            }
        }
        for key in domainKeys where condition[key] != nil {
            guard let domains = condition[key] as? [String], !domains.isEmpty,
                  domains.allSatisfy({ domain in
                      domain.utf8.count <= 253 && !domain.isEmpty && !domain.hasPrefix(".") && !domain.hasSuffix(".")
                          && domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                              !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                                  && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                          }
                  }) else { throw invalid("Rule domains must be ASCII hostnames, without schemes, wildcards or ports.") }
        }
        let resources: Set<String> = ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"]
        for key in resourceKeys where condition[key] != nil {
            guard let values = condition[key] as? [String], !values.isEmpty, Set(values).isSubset(of: resources) else {
                throw invalid("Rule resource types are invalid.")
            }
        }
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "CobbleChromium.BlockingRules", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
