import Foundation
import XCTest
@testable import CobbleChromium

final class BlockingRulesTests: XCTestCase {
    func testBundledRulesProduceBoundedNormalWindowExtension() throws {
        let files = try ChromiumBlockingRules.files(
            json: ChromiumBlockingRules.bundledJSON, exceptions: [])
        XCTAssertEqual(Set(files.keys), ["manifest.json", "rules.json"])
        XCTAssertLessThanOrEqual(files["rules.json"]!.count, ChromiumBlockingRules.maximumBytes)
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: files["manifest.json"]!) as? [String: Any])
        XCTAssertEqual(manifest["incognito"] as? String, "not_allowed")
        XCTAssertEqual(manifest["permissions"] as? [String], ["declarativeNetRequest"])
        XCTAssertEqual(try rules(files).count, 3)
    }

    func testRejectsMalformedRuleShape() {
        for json in [
            #"[{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"x"}},{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"y"}}]"#,
            #"[{"id":true,"action":{"type":"block"},"condition":{"urlFilter":"x"}}]"#,
            #"[{"id":1,"action":{"type":"redirect"},"condition":{"urlFilter":"x"}}]"#,
            #"[{"id":1,"action":{"type":"block"},"condition":{"regexFilter":"x"}}]"#,
        ] {
            XCTAssertThrowsError(try ChromiumBlockingRules.files(json: json, exceptions: []), json)
        }
    }

    func testExceptionMatchesOnlyExactOriginBoundary() throws {
        let origin = "https://example.test:8443"
        let exception = try XCTUnwrap(try rules(ChromiumBlockingRules.files(
            json: "[]", exceptions: [origin])).first)
        XCTAssertEqual((exception["action"] as? [String: String])?["type"], "allowAllRequests")
        let condition = try XCTUnwrap(exception["condition"] as? [String: Any])
        let expression = try NSRegularExpression(pattern: try XCTUnwrap(condition["regexFilter"] as? String))
        let matches = { (value: String) in
            expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        XCTAssertTrue(matches("https://example.test:8443/page"))
        XCTAssertFalse(matches("http://example.test:8443/page"))
        XCTAssertFalse(matches("https://example.test/page"))
        XCTAssertFalse(matches("https://sub.example.test:8443/page"))
        XCTAssertFalse(matches("https://example.test.evil:8443/page"))
        XCTAssertThrowsError(try ChromiumBlockingRules.files(json: "[]", exceptions: [origin + "/path"]))
    }

    private func rules(_ files: [String: Data]) throws -> [[String: Any]] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: files["rules.json"]!) as? [[String: Any]])
    }
}
