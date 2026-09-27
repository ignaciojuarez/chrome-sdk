import Foundation
import CobbleChromium

@MainActor
enum HarnessIdentityValidation {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Snapshot: Decodable {
        let path: String
        let requestURL: String
        let requestID: Int
        let method: String
        let body: String
        let httpUA: String
        let httpPlatform: String?
        let httpMobile: String?
        let httpPlatformVersion: String?
        let httpModel: String?
        let httpFullVersionList: String?
        let jsUA: String
        let jsHref: String
        let jsPlatform: String?
        let jsMobile: Bool?
        let jsHighPlatform: String?
        let jsHighPlatformVersion: String?
        let jsHighModel: String?
        let width: Int
        let touchPoints: Int
        let iframeLoaded: Bool
        let popupUA: String?
        let pageShowCount: Int
        let latePageShowCount: Int
        let pageShowUA: String?
        let pageShowPlatform: String?
    }
    private struct Event: Decodable {
        let path: String
        let method: String
        let body: String
    }
    private struct BlankSnapshot: Decodable {
        let ua: String
        let platform: String?
        let href: String
    }

    static func run(runtime: ChromiumRuntime, base: URL, report: URL,
                    reserveHost: @escaping () -> UUID, showPage: @escaping (ChromiumPage) -> Void,
                    closeHost: (UUID) -> Void) async {
        var checks: [String: Bool] = [:]
        var contexts: [ChromiumContext] = []
        var pages: [ChromiumPage] = []
        var hosts: [UUID] = []
        var popup: ChromiumPage?
        var diagnostics: [String: Any] = [:]
        do {
            func route(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }
            func require(_ name: String, _ condition: Bool) throws {
                checks[name] = condition
                if !condition { throw Failure(message: name) }
            }
            func host() -> UUID {
                let id = reserveHost()
                hosts.append(id)
                return id
            }
            let normal = try await runtime.openContext(profileKey: "identity-normal")
            contexts.append(normal)
            normal.identityResolver = resolve
            let second = try await runtime.openContext(profileKey: "identity-second")
            contexts.append(second)
            second.identityResolver = { _ in .iPad }
            let privateContext = try await runtime.openContext(
                profileKey: "identity-normal", privateWindowKey: "identity-private")
            contexts.append(privateContext)
            privateContext.identityResolver = resolve
            runtime.popupPolicy = { _ in true }
            runtime.onPopup = { _, page in
                popup = page
                pages.append(page)
                let id = host()
                do { try page.move(toHostWindowID: id); showPage(page) }
                catch { page.forceClose() }
            }

            let first = try normal.makePage(url: route("/page?mode=android-phone&case=initial"),
                                            hostWindowID: host())
            pages.append(first)
            showPage(first)
            let baselineWidth = try await stableWidth(first)
            let phone = try await snapshot(first, query: "case=initial",
                satisfying: { abs(Double($0.width) - first.nativeView.bounds.width) < 2 })
            try require("initialPhoneUAAndHints", matches(phone, .androidPhone))
            let originalWidth = phone.width
            let originalTouch = phone.touchPoints
            try require("visiblePageGeometry", originalWidth > 100 &&
                abs(Double(originalWidth) - baselineWidth) < 2)

            try first.load(route("/page?mode=iphone&case=direct"))
            let iphone = try await snapshot(first, query: "case=direct")
            try require("nativeLoadIPhone", matches(iphone, .iPhone) &&
                iphone.httpPlatformVersion == nil && iphone.httpModel == nil &&
                iphone.httpFullVersionList == nil)
            try first.load(route("/page?mode=ipad&case=ipad-tablet"))
            let pad = try await snapshot(first, query: "case=ipad-tablet",
                satisfying: { abs(Double($0.width) - first.nativeView.bounds.width) < 2 })
            diagnostics["geometry"] = ["phoneWidth": originalWidth,
                "padWidth": pad.width, "phoneTouch": originalTouch,
                "padTouch": pad.touchPoints, "zoom": first.zoomFactor ?? -1,
                "nativeViewWidth": first.nativeView.bounds.width,
                "baselineNativeViewWidth": baselineWidth]
            diagnostics["ipadIdentity"] = ["httpUA": pad.httpUA,
                "jsUA": pad.jsUA, "httpPlatform": pad.httpPlatform ?? "<absent>",
                "jsPlatform": pad.jsPlatform ?? "<absent>",
                "jsHighPlatform": pad.jsHighPlatform ?? "<absent>",
                "httpMobile": pad.httpMobile ?? "<absent>"]
            try require("iPadWithoutDeviceEmulation", matches(pad, .iPad) &&
                abs(Double(pad.width) - first.nativeView.bounds.width) < 2 &&
                abs(first.nativeView.bounds.width - baselineWidth) < 2 &&
                pad.touchPoints == originalTouch &&
                (first.zoomFactor ?? 1) == 1)
            try first.load(route("/page?mode=android-tablet&case=android-tablet"))
            let androidTablet = try await snapshot(first, query: "case=android-tablet")
            try require("androidTabletUAAndHints", matches(androidTablet, .androidTablet) &&
                androidTablet.httpPlatformVersion == "\"\(androidTablet.jsHighPlatformVersion ?? "missing")\"" &&
                androidTablet.httpModel == "\"\(androidTablet.jsHighModel ?? "missing")\"" &&
                androidTablet.httpFullVersionList != nil &&
                androidTablet.jsHighPlatformVersion != nil)
            try first.load(route("/page?mode=default&case=reset"))
            let nativeDefault = try await snapshot(first, query: "case=reset")
            try require("unruledResetsMac", matches(nativeDefault, .standard))

            try first.load(route("/page?mode=iphone&case=iframe&action=iframe&next=android-phone"))
            try await waitEvent(base, containing: "case=frame-child")
            try require("iframeKeepsParentIdentity", matches(try await snapshot(first,
                query: "case=iframe", satisfying: { $0.iframeLoaded }), .iPhone))

            try first.load(route("/page?mode=default&case=popup-opener&action=popup&next=ipad"))
            try require("popupOpenerNative", matches(try await snapshot(first,
                query: "case=popup-opener"), .standard))
            try await waitPage { popup }
            if let popup {
                try require("popupSharesOpenerProfile", popup.context === normal)
                let child = try await snapshot(popup, query: "case=popup-result")
                try require("popupFirstRequestIdentity", matches(child, .iPad))
                let opener = try await snapshot(first, query: "case=popup-opener",
                    satisfying: { $0.popupUA != nil })
                try require("popupLeavesLiveOpenerIdentity", matches(opener, .standard) &&
                    opener.popupUA == child.jsUA)
            }
            try first.load(route("/page?mode=default&case=popup-reset"))
            try require("popupLeavesOpenerIdentity", matches(try await snapshot(first,
                query: "case=popup-reset"), .standard))

            popup = nil
            try first.load(route("/page?mode=iphone&case=blank-opener&action=blank-popup"))
            try require("blankOpenerIPhone", matches(try await snapshot(first,
                query: "case=blank-opener"), .iPhone))
            try await waitPage { popup }
            if let popup {
                let blank = try await blankSnapshot(popup)
                diagnostics["blankPopup"] = ["href": blank.href, "url": popup.urlString,
                    "ua": blank.ua, "platform": blank.platform ?? "<absent>",
                    "sameContext": popup.context === normal]
                try require("blankPopupUsesNativeDefault", popup.context === normal &&
                    blank.href == "about:blank" && blank.ua == nativeDefault.jsUA &&
                    blank.platform == nativeDefault.jsPlatform)
                try popup.load(route("/page?mode=default&case=blank-reset"))
                let reset = try await snapshot(popup, query: "case=blank-reset")
                try require("blankPopupResetsOnHTTP", matches(reset, .standard))
                let opener = try await snapshot(first, query: "case=blank-opener",
                    satisfying: { $0.popupUA != nil })
                try require("blankPopupDoesNotChangeOpener", matches(opener, .iPhone) &&
                    opener.popupUA == reset.jsUA)
            }

            try first.load(route("/page?mode=default&case=link&action=link&next=android-phone"))
            try require("rendererLink", matches(try await snapshot(first,
                query: "case=link-result"), .androidPhone))
            try first.load(route("/page?mode=default&case=script&action=script&next=iphone"))
            try require("rendererScript", matches(try await snapshot(first,
                query: "case=script-result"), .iPhone))
            try first.load(route("/page?mode=default&case=form&action=form&next=android-tablet"))
            let posted = try await snapshot(first, query: "case=form-result")
            try require("rendererPOSTBody", matches(posted, .androidTablet) &&
                posted.method == "POST" && posted.body == "identity=body-preserved")
            try first.load(route("/page?mode=default&case=redirect&action=redirect&next=ipad"))
            try require("redirectDestination", matches(try await snapshot(first,
                query: "case=redirect-result"), .iPad))
            try first.load(route("/page?mode=default&case=post307&action=post307&next=iphone"))
            let redirectPOST = try await snapshot(first, query: "case=post307-result")
            try require("redirect307PreservesBody", matches(redirectPOST, .iPhone) &&
                redirectPOST.method == "POST" && redirectPOST.body == "identity=body-preserved")
            try first.load(route("/page?mode=default&case=post308&action=post308&next=android-phone"))
            let redirect308 = try await snapshot(first, query: "case=post308-result")
            try require("redirect308PreservesBody", matches(redirect308, .androidPhone) &&
                redirect308.method == "POST" && redirect308.body == "identity=body-preserved")
            try first.load(route("/redirect?mode=android-phone&case=mobile-to-default&next=default&code=302"))
            try require("redirectMobileToDefault", matches(try await snapshot(first,
                query: "case=mobile-to-default-result"), .standard))
            try first.load(route("/redirect?mode=android-phone&case=mobile-to-other&next=ipad&code=302&cross=1"))
            try require("crossOriginRedirectMobileToIPad", matches(try await snapshot(first,
                query: "case=mobile-to-other-result"), .iPad))

            try first.load(route("/page?mode=iphone&case=history-start"))
            let historyStart = try await snapshot(first, query: "case=history-start")
            try require("historyStart", matches(historyStart, .iPhone))
            try first.load(route("/page?mode=default&case=history-end"))
            let historyEnd = try await snapshot(first, query: "case=history-end")
            try require("historyEnd", matches(historyEnd, .standard))
            first.goBack()
            let historyBack = try await snapshot(first, query: "case=history-start",
                satisfying: { ($0.requestID > historyStart.requestID ||
                    $0.pageShowCount > historyStart.pageShowCount) &&
                    $0.latePageShowCount == $0.pageShowCount })
            diagnostics["historyBack"] = ["httpUA": historyBack.httpUA,
                "jsUA": historyBack.jsUA,
                "httpPlatform": historyBack.httpPlatform ?? "<absent>",
                "jsPlatform": historyBack.jsPlatform ?? "<absent>",
                "jsHighPlatform": historyBack.jsHighPlatform ?? "<absent>",
                "requestID": historyBack.requestID,
                "url": first.urlString]
            try require("historyBack", matches(historyBack, .iPhone))
            first.goForward()
            try require("historyForward", matches(try await snapshot(first,
                query: "case=history-end", satisfying: {
                    ($0.requestID > historyEnd.requestID ||
                     $0.pageShowCount > historyEnd.pageShowCount) &&
                    $0.latePageShowCount == $0.pageShowCount
                }), .standard))
            let priorReloads = try await fetchEvents(base).filter {
                $0.path.contains("case=history-end")
            }.count
            try require("reloadAccepted", first.reload())
            try await waitEventCount(base, containing: "case=history-end", greaterThan: priorReloads)
            let reloaded = try await snapshot(first, query: "case=history-end",
                                              after: historyEnd.requestID)
            try require("reloadIdentity", matches(reloaded, .standard))

            try first.load(route("/page?mode=iphone&case=sameflag-start"))
            let sameStart = try await snapshot(first, query: "case=sameflag-start")
            try require("sameFlagStart", matches(sameStart, .iPhone))
            try first.load(route("/page?mode=ipad&case=sameflag-end"))
            let sameEnd = try await snapshot(first, query: "case=sameflag-end")
            try require("sameFlagEnd", matches(sameEnd, .iPad))
            first.goBack()
            try require("sameFlagHistoryBack", matches(try await snapshot(first,
                query: "case=sameflag-start", satisfying: {
                    ($0.requestID > sameStart.requestID ||
                     $0.pageShowCount > sameStart.pageShowCount) &&
                    $0.latePageShowCount == $0.pageShowCount
                }), .iPhone))
            first.goForward()
            try require("sameFlagHistoryForward", matches(try await snapshot(first,
                query: "case=sameflag-end", satisfying: {
                    ($0.requestID > sameEnd.requestID ||
                     $0.pageShowCount > sameEnd.pageShowCount) &&
                    $0.latePageShowCount == $0.pageShowCount
                }), .iPad))

            normal.identityResolver = { _ in .iPad }
            try first.load(route("/page?mode=default&case=edited-rule"))
            try require("editedResolverApplied", matches(try await snapshot(first,
                query: "case=edited-rule"), .iPad))
            normal.identityResolver = resolve
            try first.load(route("/page?mode=default&case=edited-reset"))
            try require("editedResolverReset", matches(try await snapshot(first,
                query: "case=edited-reset"), .standard))

            let sibling = try second.makePage(url: route("/page?mode=default&case=second"),
                                              hostWindowID: host())
            pages.append(sibling)
            showPage(sibling)
            try first.load(route("/page?mode=default&case=second"))
            try require("sameURLNormalProfile", matches(try await snapshot(first,
                query: "case=second"), .standard))
            try require("secondProfileIsolation", matches(try await snapshot(sibling,
                query: "case=second"), .iPad))
            let hidden = try privateContext.makePage(
                url: route("/page?mode=android-phone&case=private"), hostWindowID: host())
            pages.append(hidden)
            showPage(hidden)
            try require("privateUsesSavedRule", matches(try await snapshot(hidden,
                query: "case=private"), .androidPhone))
            try require("privateProfileIsolation", matches(try await snapshot(sibling,
                query: "case=second"), .iPad))
            let events = try await fetchEvents(base)
            try require("redirect302SawBothDestinations", events.contains {
                $0.path.contains("case=redirect") && $0.method == "GET"
            } && events.contains { $0.path.contains("case=redirect-result") })
            try require("redirect307NoDuplicateBody", events.filter {
                $0.path.contains("case=post307-result")
            }.count == 1 && events.filter {
                $0.path.hasPrefix("/redirect?") && $0.path.contains("case=post307&")
            }.count == 1 && events.contains {
                $0.path.hasPrefix("/redirect?") && $0.path.contains("case=post307&") &&
                $0.method == "POST" && $0.body == "identity=body-preserved"
            } && events.contains {
                $0.path.contains("case=post307-result") && $0.method == "POST" &&
                $0.body == "identity=body-preserved"
            })
            try require("redirect308NoDuplicateBody", events.filter {
                $0.path.contains("case=post308-result")
            }.count == 1 && events.filter {
                $0.path.hasPrefix("/redirect?") && $0.path.contains("case=post308&")
            }.count == 1 && events.contains {
                $0.path.hasPrefix("/redirect?") && $0.path.contains("case=post308&") &&
                $0.method == "POST" && $0.body == "identity=body-preserved"
            } && events.contains {
                $0.path.contains("case=post308-result") && $0.method == "POST" &&
                $0.body == "identity=body-preserved"
            })

            first.forceClose()
            _ = await first.waitUntilClosed()
            let restored = try normal.makePage(url: route("/page?mode=iphone&case=restored"),
                                               hostWindowID: host())
            pages.append(restored)
            showPage(restored)
            try require("restoredPageIdentity", matches(try await snapshot(restored,
                query: "case=restored"), .iPhone))
            write(report, status: "passed", checks: checks, error: nil,
                  diagnostics: diagnostics)
        } catch {
            write(report, status: "failed", checks: checks, error: error.localizedDescription,
                  diagnostics: diagnostics)
        }
        for page in pages where !page.isClosed { page.forceClose(); _ = await page.waitUntilClosed() }
        for id in hosts { closeHost(id) }
        runtime.onPopup = nil
        runtime.popupPolicy = nil
        for context in contexts.reversed() where !context.isClosed { _ = await context.close() }
        runtime.requestQuit()
    }

    private static func resolve(_ url: URL) -> ChromiumBrowserIdentity {
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "mode" }?.value
        switch mode {
        case "android-phone": return .androidPhone
        case "android-tablet": return .androidTablet
        case "iphone": return .iPhone
        case "ipad": return .iPad
        default: return .standard
        }
    }

    private static func snapshot(_ page: ChromiumPage, query: String,
                                 after priorID: Int = 0,
                                 satisfying predicate: (Snapshot) -> Bool = { _ in true }) async throws -> Snapshot {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if page.isClosed { throw Failure(message: "Page closed during \(query)") }
            if page.urlString.contains(query), !page.isLoading,
               page.title.hasPrefix("CobbleIdentity:") {
                let raw = String(page.title.dropFirst("CobbleIdentity:".count))
                if let bytes = Data(base64Encoded: raw),
                   let value = try? JSONDecoder().decode(Snapshot.self, from: bytes),
                   value.path == "/page", value.requestURL.contains(query),
                   value.jsHref == page.urlString, value.jsHref.contains(query),
                   value.requestID > priorID, predicate(value) { return value }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Timed out waiting for \(query): \(page.urlString) \(page.title)")
    }

    private static func stableWidth(_ page: ChromiumPage) async throws -> Double {
        let deadline = ContinuousClock.now + .seconds(12)
        var previous = 0.0
        var stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            let width = page.nativeView.bounds.width
            if page.nativeView.window != nil && width > 100 {
                if abs(width - previous) >= 1 {
                    previous = width
                    stableSince = ContinuousClock.now
                } else if ContinuousClock.now - stableSince >= .seconds(1) {
                    return width
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Native page width did not settle")
    }

    private static func blankSnapshot(_ page: ChromiumPage) async throws -> BlankSnapshot {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if page.isClosed { throw Failure(message: "Blank popup closed") }
            if page.title.hasPrefix("CobbleBlank:") {
                let raw = String(page.title.dropFirst("CobbleBlank:".count))
                if let bytes = Data(base64Encoded: raw),
                   let value = try? JSONDecoder().decode(BlankSnapshot.self, from: bytes) {
                    return value
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Blank popup identity unavailable: \(page.urlString)")
    }

    private static func matches(_ value: Snapshot, _ mode: ChromiumBrowserIdentity) -> Bool {
        guard value.httpUA == value.jsUA,
              value.pageShowUA == value.jsUA,
              value.pageShowPlatform == value.jsPlatform else { return false }
        switch mode {
        case .standard:
            return value.jsUA.contains("Macintosh") &&
                value.httpPlatform == "\"macOS\"" && value.jsHighPlatform == "macOS"
        case .androidPhone:
            return value.jsUA.contains("Android 10") && value.jsUA.contains("Mobile") &&
                value.httpPlatform == "\"Android\"" && value.jsHighPlatform == "Android" &&
                value.jsMobile == true && value.httpMobile == "?1"
        case .androidTablet:
            return value.jsUA.contains("Android 10") && !value.jsUA.contains("Mobile") &&
                value.httpPlatform == "\"Android\"" && value.jsHighPlatform == "Android" &&
                value.jsMobile == false && value.httpMobile == "?0"
        case .iPhone:
            return value.jsUA.contains("iPhone") && value.httpPlatform == nil &&
                (value.jsHighPlatform ?? "").isEmpty &&
                (value.jsPlatform ?? "").isEmpty && !value.jsUA.contains("Macintosh")
        case .iPad:
            return value.jsUA.contains("iPad") && value.httpPlatform == nil &&
                (value.jsHighPlatform ?? "").isEmpty &&
                (value.jsPlatform ?? "").isEmpty && !value.jsUA.contains("Macintosh")
        }
    }

    private static func fetchEvents(_ base: URL) async throws -> [Event] {
        let url = URL(string: "/events", relativeTo: base)!.absoluteURL
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Event].self, from: data)
    }

    private static func waitEvent(_ base: URL, containing needle: String) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if try await fetchEvents(base).contains(where: { $0.path.contains(needle) }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Missing request \(needle)")
    }

    private static func waitEventCount(_ base: URL, containing needle: String,
                                       greaterThan count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if try await fetchEvents(base).filter({ $0.path.contains(needle) }).count > count {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Missing new request \(needle)")
    }

    private static func waitPage(_ page: @escaping @MainActor () -> ChromiumPage?) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if page() != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Popup was not created")
    }

    private static func write(_ url: URL, status: String, checks: [String: Bool],
                              error: String?, diagnostics: [String: Any]) {
        let payload: [String: Any] = ["status": status, "checks": checks,
                                      "error": error.map { $0 as Any } ?? NSNull(),
                                      "diagnostics": diagnostics]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
