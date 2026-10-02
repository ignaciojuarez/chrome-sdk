import Foundation
import Darwin
import AppKit
import CobbleChromium

/// An opt-in native smoke check for permission withholding and Chromium-owned
/// website data. `scripts/smoke.mjs` supplies a fresh loopback fixture and
/// checks the report before starting its separate CDP rendering work.
@MainActor
enum HarnessValidation {
    static func startIfConfigured(runtime: ChromiumRuntime,
                                  reserveHost: (() -> UUID)? = nil,
                                  showPage: ((ChromiumPage) -> Void)? = nil,
                                  showDevTools: ((ChromiumDevToolsSession, UUID) -> Bool)? = nil,
                                  closeHost: ((UUID) -> Void)? = nil,
                                  reserveReentrantHost: ((ChromiumPage) -> UUID)? = nil) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["COBBLE_CHROMIUM_IDENTITY_REPORT"],
           path.hasPrefix("/"), !path.utf8.contains(0),
           let address = environment["COBBLE_CHROMIUM_HARNESS_URL"],
           let base = URL(string: address), base.scheme == "http",
           base.host == "127.0.0.1", base.port != nil,
           let reserveHost, let showPage, let closeHost {
            Task { @MainActor in
                await HarnessIdentityValidation.run(runtime: runtime, base: base,
                    report: URL(fileURLWithPath: path), reserveHost: reserveHost,
                    showPage: showPage, closeHost: closeHost)
            }
            return
        }
        if let reportPath = environment["COBBLE_CHROMIUM_EXTENSION_REGISTRY_REPORT"],
           reportPath.hasPrefix("/"), !reportPath.utf8.contains(0) {
            Task { @MainActor in
                await validateExtensionRegistry(runtime: runtime, report: URL(fileURLWithPath: reportPath))
            }
            return
        }
        if let reportPath = environment["COBBLE_CHROMIUM_COOKIE_TRANSFER_REPORT"],
           reportPath.hasPrefix("/"), !reportPath.utf8.contains(0) {
            Task { @MainActor in
                let report = URL(fileURLWithPath: reportPath)
                var normal: ChromiumContext?
                var privateContext: ChromiumContext?
                do {
                    let opened = try await runtime.openContext(profileKey: "harness-cookie-transfer")
                    normal = opened
                    let openedPrivate = try await runtime.openContext(
                        profileKey: "harness-cookie-transfer", privateWindowKey: "private")
                    privateContext = openedPrivate
                    let checks = try await HarnessWebsiteDataValidation.runCookieTransfer(
                        context: opened, privateContext: openedPrivate,
                        token: UUID().uuidString)
                    let passed = checks.values.allSatisfy { $0 }
                    write(Report(status: passed ? "passed" : "failed", checks: checks,
                                 error: passed ? nil : "Cookie transfer checks failed."),
                          to: report)
                } catch {
                    write(Report(status: "failed", checks: [:], error: error.localizedDescription),
                          to: report)
                }
                if let privateContext { _ = await privateContext.close() }
                if let normal { _ = await normal.close() }
                runtime.requestQuit()
            }
            return
        }
        if let reportPath = environment["COBBLE_CHROMIUM_CLIENT_CERT_EMPTY_REPORT"],
           reportPath.hasPrefix("/"), !reportPath.utf8.contains(0),
           let caseName = environment["COBBLE_CHROMIUM_CLIENT_CERT_EMPTY_CASE"],
           ["missing", "relative", "directory"].contains(caseName),
           let baselineString = environment["COBBLE_CHROMIUM_HARNESS_URL"],
           let baseline = URL(string: baselineString), baseline.scheme == "http",
           baseline.host == "127.0.0.1", baseline.port != nil,
           let targetString = environment["COBBLE_CHROMIUM_CLIENT_CERT_EMPTY_URL"],
           let target = URL(string: targetString), target.scheme == "https",
           target.host == "127.0.0.1", target.port != nil,
           let reserveHost, let showPage {
            Task { @MainActor in
                let report = URL(fileURLWithPath: reportPath)
                var context: ChromiumContext?
                var page: ChromiumPage?
                var host: UUID?
                do {
                    let opened = try await runtime.openContext(
                        profileKey: "harness-client-certificate-empty-\(caseName)")
                    context = opened
                    let reserved = reserveHost()
                    host = reserved
                    let openedPage = try opened.makePage(url: baseline, hostWindowID: reserved)
                    page = openedPage
                    showPage(openedPage)
                    try await wait(for: openedPage, url: baseline, title: "Cobble Smoke A")
                    var callbackCount = 0
                    var navigationObserved = false
                    runtime.onClientCertificateRequest = { request in
                        callbackCount += 1
                        request.cancel()
                    }
                    openedPage.onChange = { navigationObserved = true }
                    try openedPage.load(target)
                    try await waitForCondition("empty client-certificate navigation") {
                        navigationObserved && !openedPage.isLoading
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    let passed = callbackCount == 0 && !openedPage.hasPendingPrompt
                    write(Report(status: passed ? "passed" : "failed", checks: [
                        "\(caseName)ClientCertificateStoreYieldsNoChoices": passed,
                    ], error: passed ? nil :
                        "Restricted empty store published a client-certificate request."),
                    to: report)
                } catch {
                    write(Report(status: "failed", checks: [:], error: error.localizedDescription),
                          to: report)
                }
                if let page, !page.isClosed { page.forceClose(); _ = await page.waitUntilClosed() }
                if let context, !context.isClosed { _ = await context.close() }
                if let host { closeHost?(host) }
                runtime.requestQuit()
            }
            return
        }
        if let reportPath = environment["COBBLE_CHROMIUM_DEVTOOLS_SHUTDOWN_REPORT"],
           let fixtureString = environment["COBBLE_CHROMIUM_HARNESS_URL"],
           let fixture = URL(string: fixtureString), fixture.scheme == "http",
           fixture.host == "127.0.0.1", fixture.port != nil,
           let reserveHost, let showPage, let showDevTools {
            Task { @MainActor in
                let report = URL(fileURLWithPath: reportPath)
                do {
                    let context = try await runtime.openContext(profileKey: "harness-devtools-shutdown")
                    let pageHost = reserveHost()
                    let page = try context.makePage(url: fixture, hostWindowID: pageHost)
                    showPage(page)
                    try await wait(for: page, url: fixture, title: "Cobble Smoke A")
                    let toolsHost = reserveHost()
                    let session = try page.openDevTools(hostWindowID: toolsHost)
                    guard showDevTools(session, toolsHost) else {
                        throw ValidationError("DevTools shutdown frontend did not attach.")
                    }
                    var closeCount = 0
                    session.onClose = {
                        closeCount += 1
                        write(Report(status: "passed", checks: [
                            "runtimeQuitClosesDevToolsOnce": closeCount == 1 && session.isClosed &&
                                !session.close(),
                        ], error: nil), to: report)
                    }
                    runtime.requestQuit()
                } catch {
                    write(Report(status: "failed", checks: [:], error: error.localizedDescription),
                          to: report)
                    runtime.requestQuit()
                }
            }
            return
        }
        if let reportPath = environment["COBBLE_CHROMIUM_EXTERNAL_SHUTDOWN_REPORT"],
           let markerPath = environment["COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_MARKER"],
           let activatedPath = environment["COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_ACTIVATED"],
           let fixtureString = environment["COBBLE_CHROMIUM_HARNESS_URL"],
           let fixture = URL(string: fixtureString), fixture.scheme == "http",
           fixture.host == "127.0.0.1", fixture.port != nil {
            Task { @MainActor in
                let report = URL(fileURLWithPath: reportPath)
                let progress = environment["COBBLE_CHROMIUM_EXTERNAL_SHUTDOWN_PROGRESS"]
                    .map { URL(fileURLWithPath: $0) }
                var progressValues: [String] = []
                let recordProgress = { (value: String) in
                    progressValues.append(value)
                    if let progress {
                        try? Data((progressValues.joined(separator: "\n") + "\n").utf8)
                            .write(to: progress, options: .atomic)
                    }
                }
                do {
                    var components = URLComponents(
                        url: fixture.deletingLastPathComponent()
                            .appendingPathComponent("external-protocol").absoluteURL,
                        resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "case", value: "shutdown")]
                    let target = components.url!
                    let context = try await runtime.openContext(profileKey: "harness-shutdown")
                    let page = try context.makePage(url: target, hostWindowID: UUID())
                    try await wait(for: page, url: target,
                                   title: "Cobble External Ready shutdown \(fixture.pathComponents.dropLast().last!)")
                    recordProgress("page-ready")
                    var cancellationCount = 0
                    runtime.onExternalProtocolRequest = { request in
                        request.onCancel = {
                            recordProgress("cancel-callback")
                            cancellationCount += 1
                            write(Report(status: "passed", checks: [
                                "shutdownExternalProtocolCancelledOnce":
                                    cancellationCount == 1 && !request.isPending && !request.deny(),
                            ], error: nil), to: report)
                            Task { @MainActor in
                                recordProgress("cleanup-task-start pageClosed=\(page.isClosed) " +
                                    "contextClosed=\(context.isClosed)")
                                if !page.isClosed {
                                    recordProgress("before-force-close")
                                    page.forceClose()
                                    let closed = await page.waitUntilClosed()
                                    recordProgress("after-page-close-\(closed)")
                                }
                                if !context.isClosed {
                                    recordProgress("before-context-close")
                                    let closed = await context.close()
                                    recordProgress("after-context-close-\(closed)")
                                }
                                try? await Task.sleep(for: .seconds(1))
                                recordProgress("before-second-request-quit")
                                runtime.requestQuit()
                                recordProgress("after-second-request-quit")
                            }
                        }
                    }
                    try JSONSerialization.data(withJSONObject: [
                        "url": target.absoluteString, "sequence": 1, "frame": false,
                    ]).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
                    try await waitForCondition("trusted shutdown external protocol action") {
                        (try? String(contentsOfFile: activatedPath, encoding: .utf8)) == "1\n"
                    }
                    try await waitForCondition("pending external protocol before shutdown") {
                        page.hasPendingPrompt
                    }
                    recordProgress("before-first-request-quit")
                    runtime.requestQuit()
                    recordProgress("after-first-request-quit")
                } catch {
                    write(Report(status: "failed", checks: [:], error: error.localizedDescription),
                          to: report)
                    runtime.requestQuit()
                }
            }
            return
        }
        if let reportPath = environment["COBBLE_CHROMIUM_PROFILE_RESTART_REPORT"],
           reportPath.hasPrefix("/"), !reportPath.utf8.contains(0),
           let userDataPath = environment["COBBLE_CHROMIUM_VALIDATION_USER_DATA_DIR"],
           userDataPath.hasPrefix("/"), !userDataPath.utf8.contains(0) {
            Task { @MainActor in
                let report = URL(fileURLWithPath: reportPath)
                let userData = URL(fileURLWithPath: userDataPath, isDirectory: true)
                let keys = ["harness-validation", "harness-delete-failure"]
                do {
                    let absentBefore = keys.allSatisfy {
                        pathIsAbsent(userData.appendingPathComponent("Cobble-\($0)"))
                    }
                    for key in keys {
                        try await runtime.preflightProfileDeletion(key: key)
                        try await runtime.scheduleProfileDeletion(key: key)
                    }
                    let absentAfter = keys.allSatisfy {
                        pathIsAbsent(userData.appendingPathComponent("Cobble-\($0)"))
                    }
                    write(Report(status: "passed", checks: [
                        "profilesAbsentAfterRestart": absentBefore,
                        "absentDeletionRetriedAfterRestart": absentAfter,
                    ], error: nil), to: report)
                } catch {
                    write(Report(status: "failed", checks: [:],
                                 error: error.localizedDescription), to: report)
                }
                runtime.requestQuit()
            }
            return
        }
        guard let reportPath = environment["COBBLE_CHROMIUM_VALIDATION_REPORT"],
              reportPath.hasPrefix("/"), !reportPath.utf8.contains(0)
        else { return }
        let report = URL(fileURLWithPath: reportPath)
        guard let configuration = Configuration.load(report: report) else {
            write(Report(status: "failed", checks: [:],
                         error: "Native validation requires the exact tokenized 127.0.0.1 harness URL."),
                  to: report)
            return
        }
        Task { @MainActor in
            await run(runtime: runtime, configuration: configuration,
                      reserveHost: reserveHost, showPage: showPage,
                      showDevTools: showDevTools, closeHost: closeHost,
                      reserveReentrantHost: reserveReentrantHost)
        }
    }

    private static func validateExtensionRegistry(runtime: ChromiumRuntime, report: URL) async {
        var checks: [String: Bool] = [:]
        var context: ChromiumContext?
        var privateContext: ChromiumContext?
        var directory: URL?
        var installedID: String?
        do {
            let source = try makeExtensionDirectory(token: UUID().uuidString)
            directory = source
            let opened = try await runtime.openContext(profileKey: "harness-extension-registry")
            context = opened
            let privateOpened = try await runtime.openContext(
                profileKey: "harness-extension-registry", privateWindowKey: "isolated")
            privateContext = privateOpened
            var events = 0
            var privateEvents = 0
            opened.onExtensionsChanged = { events += 1 }
            privateOpened.onExtensionsChanged = { privateEvents += 1 }
            let id = try await runtime.installUnpackedExtension(at: source, in: opened)
            installedID = id
            try await waitForCondition("extension installation notification") { events > 0 }
            let installed = try await runtime.installedExtensions(in: opened)
            checks["unpackedSourceMetadata"] = installed.contains {
                $0.id == id && $0.source == .unpacked && $0.userManageable && $0.enabled && $0.disableReasons == 0
            }
            checks["internalExtensionsNotManageable"] = installed.filter {
                $0.source == .component || $0.source == .policy || $0.source == .other
            }.allSatisfy { !$0.userManageable }
            let beforeDisable = events
            try await runtime.setExtension(id, enabled: false, in: opened)
            try await waitForCondition("extension disable notification") { events > beforeDisable }
            checks["disableReasonReported"] = try await runtime.installedExtensions(in: opened)
                .contains { $0.id == id && !$0.enabled && $0.disableReasons != 0 }
            let beforeEnable = events
            try await runtime.setExtension(id, enabled: true, in: opened)
            try await waitForCondition("extension enable notification") { events > beforeEnable }
            checks["enableNotification"] = true
            let beforeRemove = events
            try await runtime.removeExtension(id, from: opened)
            installedID = nil
            try await waitForCondition("extension removal notification") { events > beforeRemove }
            let afterRemoval = try await runtime.installedExtensions(in: opened)
            checks["removalReconciled"] = !afterRemoval.contains { $0.id == id }
            checks["privateObserverIsolated"] = privateEvents == 0
            _ = await privateOpened.close()
            privateContext = nil
            opened.onExtensionsChanged = nil
            let unsubscribedCount = events
            let secondID = try await runtime.installUnpackedExtension(at: source, in: opened)
            installedID = secondID
            try await runtime.removeExtension(secondID, from: opened)
            installedID = nil
            try await Task.sleep(for: .milliseconds(100))
            checks["observerUnsubscribed"] = events == unsubscribedCount && privateEvents == 0
            for (kind, extra) in [
                ("theme", ["theme": ["colors": ["frame": [255, 0, 0]]]] as [String: Any]),
                ("app", ["app": ["launch": ["web_url": "https://example.invalid/"],
                                  "urls": ["https://example.invalid/"]]] as [String: Any]),
            ] {
                var manifest: [String: Any] = ["manifest_version": 2, "name": "Rejected " + kind, "version": "1.0"]
                manifest.merge(extra) { _, value in value }
                try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
                do {
                    installedID = try await runtime.installUnpackedExtension(at: source, in: opened)
                    checks[kind + "Rejected"] = false
                    if let installedID { try await runtime.removeExtension(installedID, from: opened) }
                    installedID = nil
                } catch {
                    checks[kind + "Rejected"] = true
                    if kind == "theme" {
                        checks["themeRejectedByNativePolicy"] = error.localizedDescription.contains("does not support themes or Chrome Apps")
                    }
                }
            }
            let passed = checks.values.allSatisfy { $0 }
            write(Report(status: passed ? "passed" : "failed", checks: checks,
                         error: passed ? nil : "Extension registry checks failed."), to: report)
        } catch {
            write(Report(status: "failed", checks: checks, error: error.localizedDescription), to: report)
        }
        if let context, let installedID { try? await runtime.removeExtension(installedID, from: context) }
        if let privateContext { _ = await privateContext.close() }
        if let context { _ = await context.close() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        runtime.requestQuit()
    }

    private static func run(runtime: ChromiumRuntime, configuration: Configuration,
                            reserveHost: (() -> UUID)?,
                            showPage: ((ChromiumPage) -> Void)?,
                            showDevTools: ((ChromiumDevToolsSession, UUID) -> Bool)?,
                            closeHost: ((UUID) -> Void)?,
                            reserveReentrantHost: ((ChromiumPage) -> UUID)?) async {
        var checks: [String: Bool] = [:]
        var context: ChromiumContext?
        var page: ChromiumPage?
        var extensionID: String?
        var extensionDirectory: URL?
        var blockingExtensionID: String?
        var blockingDirectory: URL?
        var auxiliaryContexts: [ChromiumContext] = []
        var auxiliaryPages: [ChromiumPage] = []

        do {
            guard runtime.isReady else { throw ValidationError("Chromium was not ready.") }
            let runtimeInfo = try runtime.runtimeInfo()
            checks["runtimeVersionAvailable"] = runtimeInfo.abiVersion == 18 &&
                runtimeInfo.chromiumVersion == Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String &&
                !runtimeInfo.chromiumRevision.isEmpty
            checks["emptyPrivateWindowKeyRejected"] = await rejectsOperation {
                _ = try await runtime.openContext(profileKey: "harness-validation", privateWindowKey: "")
            }
            checks["nulProfileKeyRejected"] = await rejectsProfileKey {
                _ = try await runtime.openContext(profileKey: "harness\u{0}alias")
            }
            checks["nulPrivateWindowKeyRejected"] = await rejectsProfileKey {
                _ = try await runtime.openContext(profileKey: "harness-validation",
                                                  privateWindowKey: "private\u{0}alias")
            }
            guard checks["nulProfileKeyRejected"] == true,
                  checks["nulPrivateWindowKeyRejected"] == true else {
                throw ValidationError("Chromium accepted a NUL-containing context key.")
            }
            let directory = try makeExtensionDirectory(token: configuration.token)
            extensionDirectory = directory
            let openedContext = try await runtime.openContext(profileKey: "harness-validation")
            context = openedContext
            let rulesJSON = """
            [
              {"id":1,"action":{"type":"block"},"condition":{"urlFilter":"/blocked.js","resourceTypes":["script"]}},
              {"id":2,"action":{"type":"block"},"condition":{"urlFilter":"/blocked.png","resourceTypes":["image"]}}
            ]
            """
            let blockerDirectory = try makeBlockingDirectory(json: rulesJSON, exceptions: [])
            blockingDirectory = blockerDirectory
            let blockerID = try await runtime.installUnpackedExtension(at: blockerDirectory, in: openedContext)
            blockingExtensionID = blockerID
            let blockingPage = try openedContext.makePage(
                url: configuration.blockingPage, hostWindowID: UUID())
            auxiliaryPages.append(blockingPage)
            try await wait(for: blockingPage, url: configuration.blockingPage,
                           title: configuration.blockedTitle)
            checks["nativeRulesBlockScriptAndImage"] = true
            try await runtime.removeExtension(blockerID, from: openedContext)
            blockingExtensionID = nil
            let reinstalledBlockerID = try await runtime.installUnpackedExtension(
                at: blockerDirectory, in: openedContext)
            blockingExtensionID = reinstalledBlockerID
            blockingPage.reload()
            try await wait(for: blockingPage, url: configuration.blockingPage,
                           title: configuration.blockedTitle)
            checks["nativeRulesFreshReinstallBlocksImmediately"] = true
            try await runtime.setExtension(reinstalledBlockerID, enabled: false, in: openedContext)
            blockingPage.reload()
            try await wait(for: blockingPage, url: configuration.blockingPage,
                           title: configuration.allowedTitle)
            checks["nativeRulesDisableAllowsRequests"] = true
            try await runtime.setExtension(reinstalledBlockerID, enabled: true, in: openedContext)
            blockingPage.reload()
            try await wait(for: blockingPage, url: configuration.blockingPage,
                           title: configuration.blockedTitle)
            checks["nativeRulesReenableBlocksRequests"] = true
            try await runtime.setExtension(reinstalledBlockerID, enabled: true, in: openedContext)
            blockingPage.reload()
            try await wait(for: blockingPage, url: configuration.blockingPage,
                           title: configuration.blockedTitle)
            checks["nativeRulesAlreadyEnabledCallbackReady"] = true
            try await runtime.removeExtension(reinstalledBlockerID, from: openedContext)
            blockingExtensionID = nil
            try replaceBlockingFiles(in: blockerDirectory, json: rulesJSON,
                                     exceptions: [configuration.secureOriginString])
            let exceptionBlockerID = try await runtime.installUnpackedExtension(
                at: blockerDirectory, in: openedContext)
            blockingExtensionID = exceptionBlockerID
            blockingPage.reload()
            try await wait(for: blockingPage, url: configuration.blockingPage,
                           title: configuration.allowedTitle)
            checks["nativeRulesExactOriginExceptionAllowsRequests"] = true
            try await runtime.removeExtension(exceptionBlockerID, from: openedContext)
            blockingExtensionID = nil
            blockingPage.forceClose()
            guard await blockingPage.waitUntilClosed() else {
                throw ValidationError("Blocking-rules validation page did not close.")
            }
            let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cobble-missing-extension-\(UUID().uuidString)", isDirectory: true)
            do {
                _ = try await runtime.installUnpackedExtension(at: missingDirectory, in: openedContext)
                checks["missingExtensionDirectoryRejected"] = false
            } catch ChromiumExtensionError.operationFailed(let message) {
                checks["missingExtensionDirectoryRejected"] = !message.isEmpty
            } catch {
                checks["missingExtensionDirectoryRejected"] = false
            }
            guard checks["missingExtensionDirectoryRejected"] == true else {
                throw ValidationError("Chromium accepted a nonexistent extension directory.")
            }
            let installedID = try await runtime.installUnpackedExtension(
                at: directory, in: openedContext)
            extensionID = installedID
            checks["extensionListed"] = try await runtime.installedExtensions(in: openedContext)
                .contains(where: { $0.id == installedID })
            guard checks["extensionListed"] == true else {
                throw ValidationError("Installed extension was absent from the native extension registry.")
            }
            checks["extensionEnabledAfterInstall"] = try await runtime.installedExtensions(in: openedContext)
                .contains { $0.id == installedID && $0.enabled }
            guard checks["extensionEnabledAfterInstall"] == true else {
                throw ValidationError("The unpacked extension was installed but is disabled.")
            }
            checks["nulExtensionIdentifierRejected"] = await rejectsExtensionIdentifier {
                try await runtime.setExtension("\(installedID)\u{0}alias", enabled: true, in: openedContext)
            }
            guard checks["nulExtensionIdentifierRejected"] == true else {
                throw ValidationError("Chromium accepted a NUL-containing extension identifier.")
            }

            let validationPage = try openedContext.makePage(
                url: configuration.extensionTarget, hostWindowID: reserveHost?() ?? UUID())
            page = validationPage
            showPage?(validationPage)
            try await waitForStableTitle(for: validationPage, url: configuration.extensionTarget,
                                         title: configuration.baselineTitle)
            checks.merge(try await HarnessPageValidation.run(page: validationPage,
                baseline: configuration.extensionTarget)) { _, new in new }
            checks["withheldBeforeGrant"] = validationPage.title == configuration.baselineTitle
            try await waitForCondition("native HTTP connection state") {
                validationPage.connection == .insecure
            }
            checks["httpConnectionReported"] = !validationPage.securityCertificateError &&
                !validationPage.securityErrorPage
            guard let httpDetails = try await validationPage.connectionDetails() else {
                throw ValidationError("HTTP connection details were unavailable.")
            }
            checks["httpConnectionDetails"] = httpDetails.url == configuration.extensionTarget.absoluteURL &&
                httpDetails.connection == .insecure && httpDetails.certificate == nil &&
                httpDetails.certificateChain.isEmpty && !httpDetails.certificateChainTruncated &&
                httpDetails.certificateErrorCodes.isEmpty &&
                !httpDetails.mixedContent.displayed && !httpDetails.mixedContent.ran &&
                !httpDetails.mixedContent.containedForm &&
                !httpDetails.mixedContent.displayedWithCertificateErrors &&
                !httpDetails.mixedContent.ranWithCertificateErrors

            guard let reserveHost, let showValidationPage = showPage else {
                throw ValidationError("Client-certificate validation requires registered native hosts.")
            }
            stage("client-certificate", configuration)
            checks.merge(try await HarnessClientCertificateValidation.run(
                runtime: runtime, token: configuration.token,
                baseline: configuration.extensionTarget,
                selectURL: configuration.clientCertificateSelect,
                cancelURL: configuration.clientCertificateCancel,
                unhandledURL: configuration.clientCertificateUnhandled,
                staleURL: configuration.clientCertificateStale,
                closeURL: configuration.clientCertificateClose,
                reentrantURL: configuration.clientCertificateReentrant,
                documentPageURL: configuration.clientCertificateDocumentPage,
                documentResourceURL: configuration.clientCertificateDocumentResource,
                expectedSubject: configuration.clientCertificateSubject,
                expectedIssuer: configuration.clientCertificateIssuer,
                expectedSerial: configuration.clientCertificateSerial,
                reserveHost: reserveHost, showPage: showValidationPage,
                closeHost: closeHost)) { _, new in new }

            guard let showDevTools else {
                throw ValidationError("DevTools validation requires registered native hosts.")
            }
            stage("devtools", configuration)
            checks["devToolsUnknownHostRejected"] = devToolsOpenIsRejected(
                validationPage, hostWindowID: UUID())
            let earlyDevToolsHost = reserveHost()
            let earlyDevTools = try validationPage.openDevTools(hostWindowID: earlyDevToolsHost)
            var earlyDevToolsCloseCount = 0
            earlyDevTools.onClose = { earlyDevToolsCloseCount += 1 }
            checks["devToolsImmediateCloseAccepted"] = earlyDevTools.close()
            try await waitForCondition("immediate DevTools close") {
                earlyDevTools.isClosed && earlyDevToolsCloseCount == 1
            }
            closeHost?(earlyDevToolsHost)
            let devToolsHost = reserveHost()
            let devTools = try validationPage.openDevTools(hostWindowID: devToolsHost)
            let devToolsView = devTools.nativeView
            var devToolsCloseCount = 0
            devTools.onClose = { devToolsCloseCount += 1 }
            checks["devToolsFrontendAttached"] = showDevTools(devTools, devToolsHost) &&
                devTools.nativeView === devToolsView && devTools.nativeView.window != nil
            if !configuration.skipDevToolsFrontendProbe {
                do {
                    try await waitForCondition("active DevTools host window") {
                        NSApp.isActive && devTools.nativeView.window?.isVisible == true &&
                            devTools.nativeView.window?.isKeyWindow == true &&
                            devTools.nativeView.window?.occlusionState.contains(.visible) == true
                    }
                } catch {
                    let window = devTools.nativeView.window
                    throw ValidationError("Active DevTools host unavailable: appActive=\(NSApp.isActive) " +
                        "attached=\(window != nil) visible=\(window?.isVisible ?? false) " +
                        "key=\(window?.isKeyWindow ?? false) " +
                        "occlusion=\(window?.occlusionState.rawValue ?? 0) " +
                        "frame=\(window.map { NSStringFromRect($0.frame) } ?? "nil") " +
                        "screen=\(window?.screen.map { NSStringFromRect($0.visibleFrame) } ?? "nil").")
                }
            }
            checks["devToolsImmediateCloseRebindsNewHost"] =
                earlyDevToolsHost != devToolsHost && devTools.nativeView.window != nil
            let duplicateDevToolsHost = reserveHost()
            checks["devToolsDuplicateRejected"] = devToolsOpenIsRejected(
                validationPage, hostWindowID: duplicateDevToolsHost)
            closeHost?(duplicateDevToolsHost)
            let devToolsWindow = devTools.nativeView.window
            let devToolsWindowFrame = devToolsWindow.map { NSStringFromRect($0.frame) } ?? ""
            let devToolsScreenFrame = devToolsWindow?.screen.map {
                NSStringFromRect($0.visibleFrame)
            } ?? ""
            if !configuration.skipDevToolsFrontendProbe {
                try JSONSerialization.data(withJSONObject: [
                "sequence": 1, "inspectedURL": configuration.extensionTarget.absoluteString,
                "escapeURL": configuration.phased(
                    configuration.extensionTarget, "devtools-escape").absoluteString,
                "hostState": [
                    "appActive": NSApp.isActive,
                    "viewAttached": devToolsWindow != nil,
                    "windowVisible": devToolsWindow?.isVisible ?? false,
                    "windowKey": devToolsWindow?.isKeyWindow ?? false,
                    "occlusionVisible": devToolsWindow?.occlusionState.contains(.visible) ?? false,
                    "windowOcclusion": devToolsWindow?.occlusionState.rawValue ?? 0,
                    "windowFrame": devToolsWindowFrame,
                    "screenVisibleFrame": devToolsScreenFrame,
                ],
                ]).write(to: configuration.devToolsMarker, options: .atomic)
                try await waitForCondition("DevTools frontend inspected target") {
                guard let data = try? Data(contentsOf: configuration.devToolsAction),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return false }
                return value["sequence"] as? Int == 1 && value["ready"] as? Bool == true &&
                    value["inspectedURL"] as? String == configuration.extensionTarget.absoluteString &&
                    value["value"] as? String ==
                        "\(configuration.token):\(configuration.extensionTarget.absoluteString)" &&
                    value["visibility"] as? String == "visible" &&
                    value["focused"] as? Bool == true &&
                    value["dockOutcome"] as? String == "callback" &&
                    value["escapeDenied"] as? Bool == true
                }
                checks["devToolsFrontendReadyAndInspectsExactTarget"] = true
                checks["devToolsNewTabEscapeDenied"] = true
                try await Task.sleep(for: .milliseconds(250))
                checks["devToolsDockingDenied"] = !devTools.isClosed &&
                    devTools.nativeView === devToolsView && devTools.nativeView.window != nil
            }
            let originalPageHost = validationPage.hostWindowID
            let movedPageHost = reserveHost()
            try validationPage.move(toHostWindowID: movedPageHost)
            let movedSessionStable = !devTools.isClosed && devTools.nativeView === devToolsView
            try validationPage.load(configuration.storageRead)
            try await wait(for: validationPage, url: configuration.storageRead,
                           title: configuration.emptyTitle)
            let navigatedSessionStable = !devTools.isClosed && devTools.nativeView === devToolsView
            try validationPage.move(toHostWindowID: originalPageHost)
            try validationPage.load(configuration.extensionTarget)
            try await waitForStableTitle(for: validationPage, url: configuration.extensionTarget,
                                         title: configuration.baselineTitle)
            checks["devToolsSurvivesTargetNavigationAndMove"] =
                movedSessionStable && navigatedSessionStable && !devTools.isClosed
            checks["devToolsExplicitCloseAccepted"] = devTools.close()
            try await waitForCondition("explicit DevTools close") {
                devTools.isClosed && devToolsCloseCount == 1
            }
            checks["devToolsExplicitCloseExactlyOnce"] = !devTools.close() &&
                devToolsCloseCount == 1
            let inspectedDOMAfterToolsClose = try await validationPage.currentDOM()
            checks["devToolsCloseLeavesInspectedPageAlive"] =
                !validationPage.isClosed && inspectedDOMAfterToolsClose.contains(configuration.token)
            closeHost?(devToolsHost)

            if !configuration.skipDevToolsFrontendProbe {
                let frontendCrashHost = reserveHost()
                let frontendCrashSession = try validationPage.openDevTools(
                    hostWindowID: frontendCrashHost)
                var frontendCrashCloseCount = 0
                frontendCrashSession.onClose = { frontendCrashCloseCount += 1 }
                guard showDevTools(frontendCrashSession, frontendCrashHost) else {
                    throw ValidationError("Crash-test DevTools frontend did not attach.")
                }
                try JSONSerialization.data(withJSONObject: ["sequence": 2])
                    .write(to: configuration.devToolsMarker, options: .atomic)
                try await waitForCondition("DevTools frontend crash retirement") {
                    frontendCrashSession.isClosed && frontendCrashCloseCount == 1
                }
                checks["devToolsFrontendCrashClosesOnce"] =
                    frontendCrashSession.isClosed && !frontendCrashSession.close() &&
                    frontendCrashCloseCount == 1 && !validationPage.isClosed
                closeHost?(frontendCrashHost)
                let reopenedDevToolsHost = reserveHost()
                let reopenedDevTools = try validationPage.openDevTools(
                    hostWindowID: reopenedDevToolsHost)
                checks["devToolsReopensAfterFrontendCrash"] =
                    showDevTools(reopenedDevTools, reopenedDevToolsHost) && reopenedDevTools.close()
                try await waitForCondition("reopened DevTools close") { reopenedDevTools.isClosed }
                closeHost?(reopenedDevToolsHost)
            }

            let windowCloseToolsHost = reserveHost()
            let windowCloseTools = try validationPage.openDevTools(
                hostWindowID: windowCloseToolsHost)
            var windowCloseToolsCount = 0
            windowCloseTools.onClose = { windowCloseToolsCount += 1 }
            guard showDevTools(windowCloseTools, windowCloseToolsHost) else {
                throw ValidationError("Window-close DevTools frontend did not attach.")
            }
            let windowCloseAccepted = windowCloseTools.close()
            closeHost?(windowCloseToolsHost)
            try await waitForCondition("host window closes DevTools") {
                windowCloseTools.isClosed && windowCloseToolsCount == 1
            }
            checks["devToolsHostWindowCloseExactlyOnce"] = windowCloseAccepted &&
                !windowCloseTools.close() && windowCloseToolsCount == 1

            if let reserveReentrantHost {
                let handoffPage = try openedContext.makePage(
                    url: configuration.extensionTarget, hostWindowID: reserveHost())
                auxiliaryPages.append(handoffPage)
                try await wait(for: handoffPage, url: configuration.extensionTarget,
                               title: configuration.baselineTitle)
                let handoffHost = reserveReentrantHost(handoffPage)
                checks["devToolsTargetCloseDuringOpenRejected"] =
                    devToolsOpenIsRejected(handoffPage, hostWindowID: handoffHost)
                try await waitForCondition("DevTools handoff target close") { handoffPage.isClosed }
                closeHost?(handoffHost)
            }

            validationPage.nativeView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
            let firstPNG = try await validationPage.snapshotPNG()
            let firstSize = try pngSize(firstPNG)
            checks["nativeSnapshotPNG"] = firstSize.width >= 320 && firstSize.height >= 180 &&
                firstSize.width <= 1_280 && firstSize.height <= 720
            validationPage.nativeView.frame.size = NSSize(width: 480, height: 270)
            let resizedPNG = try await validationPage.snapshotPNG()
            let resizedSize = try pngSize(resizedPNG)
            checks["nativeSnapshotResize"] = resizedSize.width > firstSize.width &&
                resizedSize.height > firstSize.height && resizedSize.width <= 1_920 &&
                resizedSize.height <= 1_080
            let cancelledCapture = Task { try await validationPage.snapshotPNG() }
            cancelledCapture.cancel()
            let cancelledSize = try pngSize(try await cancelledCapture.value)
            checks["nativeSnapshotTaskCancellationSafe"] =
                pngSizeIsWithinNativeBounds(cancelledSize)

            let initialSecurePage = configuration.phased(configuration.securePage, "initial")
            try validationPage.load(initialSecurePage)
            try await wait(for: validationPage, url: initialSecurePage,
                           title: configuration.secureTitle)
            try await waitForCondition("native secure connection state") {
                validationPage.connection == .secure
            }
            checks["secureConnectionReported"] = !validationPage.securityErrorPage &&
                !validationPage.securityCertificateError &&
                !validationPage.securityDisplayedMixedContent && !validationPage.securityRanMixedContent
            guard let secureDetails = try await validationPage.connectionDetails(),
                  let certificate = secureDetails.certificate else {
                throw ValidationError("Valid TLS connection details omitted the certificate.")
            }
            checks["secureConnectionDetails"] = secureDetails.url == initialSecurePage &&
                secureDetails.connection == .secure && !certificate.subject.isEmpty &&
                !certificate.issuer.isEmpty && certificate.validFrom != nil &&
                certificate.validUntil != nil && secureDetails.certificateErrorCodes.isEmpty
            checks["secureCertificateChain"] = secureDetails.certificateChain.count == 2 &&
                secureDetails.certificateChain[0].subject.contains("Cobble Fixture Leaf") &&
                secureDetails.certificateChain[0].issuer.contains("Cobble Fixture Intermediate") &&
                secureDetails.certificateChain[1].subject.contains("Cobble Fixture Intermediate") &&
                !secureDetails.certificateChainTruncated
            let navigatedPNG = try await validationPage.snapshotPNG()
            let navigatedSize = try pngSize(navigatedPNG)
            checks["nativeSnapshotNavigation"] = pngSizeIsWithinNativeBounds(navigatedSize) &&
                navigatedPNG != resizedPNG
            let backingScale = validationPage.nativeView.window?.backingScaleFactor ?? 0
            let snapshotMetrics = "snapshot pixels first=\(firstSize.width)x\(firstSize.height) " +
                "resized=\(resizedSize.width)x\(resizedSize.height) " +
                "cancelled=\(cancelledSize.width)x\(cancelledSize.height) " +
                "navigated=\(navigatedSize.width)x\(navigatedSize.height) " +
                "backingScale=\(backingScale)\n"
            FileHandle.standardError.write(Data(snapshotMetrics.utf8))

            try validationPage.load(configuration.mixedPage)
            try await wait(for: validationPage, url: configuration.mixedPage,
                           title: configuration.mixedTitle)
            try await waitForCondition("native mixed-content connection state") {
                validationPage.connection == .mixed
            }
            checks["mixedConnectionReported"] = validationPage.securityDisplayedMixedContent ||
                validationPage.securityRanMixedContent
            guard let mixedDetails = try await validationPage.connectionDetails() else {
                throw ValidationError("Mixed-content connection details were unavailable.")
            }
            checks["mixedConnectionDetails"] = mixedDetails.url == configuration.mixedPage &&
                mixedDetails.connection == .mixed && mixedDetails.certificateChain.count == 2 &&
                !mixedDetails.certificateChainTruncated && !mixedDetails.mixedContent.displayed &&
                mixedDetails.mixedContent.ran && !mixedDetails.mixedContent.containedForm &&
                !mixedDetails.mixedContent.displayedWithCertificateErrors &&
                !mixedDetails.mixedContent.ranWithCertificateErrors

            try validationPage.load(configuration.sameHostAfterMixedPage)
            try await wait(for: validationPage, url: configuration.sameHostAfterMixedPage,
                           title: configuration.secureTitle)
            try await waitForCondition("same-host mixed-content taint") {
                validationPage.connection == .mixed && validationPage.securityRanMixedContent
            }
            checks["sameHostMixedTaintRetained"] = true

            try validationPage.load(configuration.invalidSecurePage)
            try await waitForCondition("native invalid-TLS error state") {
                validationPage.urlString == configuration.invalidSecurePage.absoluteString &&
                    !validationPage.isLoading && validationPage.securityErrorPage
            }
            checks["invalidTLSReported"] = validationPage.connection == .insecure &&
                validationPage.securityCertificateError
            guard let invalidDetails = try await validationPage.connectionDetails() else {
                throw ValidationError("Invalid TLS connection details were unavailable.")
            }
            checks["invalidTLSConnectionDetails"] =
                invalidDetails.url == configuration.invalidSecurePage &&
                invalidDetails.connection == .insecure && invalidDetails.certificate != nil &&
                !invalidDetails.certificateChain.isEmpty &&
                !invalidDetails.certificateChainTruncated &&
                invalidDetails.certificateErrorCodes.contains("authorityInvalid")

            let recoveredSecurePage = configuration.secureRecoveryPage
            try validationPage.load(recoveredSecurePage)
            try await wait(for: validationPage, url: recoveredSecurePage,
                           title: configuration.secureTitle)
            do {
                try await waitForCondition("secure connection recovery") {
                    validationPage.connection == .secure
                }
            } catch {
                throw ValidationError("Timed out waiting for secure connection recovery; " +
                    "connection=\(validationPage.connection), " +
                    "errorPage=\(validationPage.securityErrorPage), " +
                    "certificateError=\(validationPage.securityCertificateError), " +
                    "displayedMixed=\(validationPage.securityDisplayedMixedContent), " +
                    "ranMixed=\(validationPage.securityRanMixedContent).")
            }
            checks["connectionRecoveredAfterError"] = !validationPage.securityErrorPage &&
                !validationPage.securityCertificateError

            runtime.onMediaPermissionRequest = nil
            let unhandledMedia = configuration.phased(configuration.mediaPage, "unhandled")
            try validationPage.load(unhandledMedia)
            try await wait(for: validationPage, url: unhandledMedia,
                           title: configuration.mediaDeniedTitle)
            checks["unhandledMediaDenied"] = !validationPage.isCapturingMicrophone &&
                !validationPage.isCapturingCamera

            var allowedRequest: ChromiumMediaPermissionRequest?
            runtime.onMediaPermissionRequest = { allowedRequest = $0 }
            let allowedMedia = configuration.phased(configuration.mediaPage, "allowed")
            try validationPage.load(allowedMedia)
            try await waitForCondition("pending combined media request") {
                allowedRequest?.isPending == true
            }
            checks["mediaPromptMoveRejected"] = moveIsRejectedWhilePending(validationPage)
            checks["mediaPromptDevToolsRejected"] = devToolsOpenIsRejectedWithTemporaryHost(
                validationPage, reserveHost: reserveHost, closeHost: closeHost)
            guard allowedRequest?.allow() == true else {
                throw ValidationError("Native combined media permission request was not accepted.")
            }
            try await wait(for: validationPage, url: allowedMedia,
                           title: configuration.mediaGrantedTitle)
            guard let allowedRequest else {
                throw ValidationError("Native combined media permission request was not delivered.")
            }
            checks["combinedMediaRequestMetadata"] = allowedRequest.page === validationPage &&
                allowedRequest.kinds.contains(.microphone) && allowedRequest.kinds.contains(.camera) &&
                allowedRequest.requestingOrigin.absoluteString == configuration.secureOriginString &&
                allowedRequest.embeddingOrigin.absoluteString == configuration.secureOriginString &&
                !allowedRequest.userGesture && allowedRequest.frameProcessID >= 0 &&
                allowedRequest.frameRoutingID >= 0 && !allowedRequest.frameToken.isEmpty
            checks["mediaAllowExactlyOnce"] = !allowedRequest.isPending && !allowedRequest.deny()
            try await waitForCondition("native media capture state") {
                validationPage.isCapturingMicrophone && validationPage.isCapturingCamera
            }
            checks["mediaCaptureStateReported"] = true
            checks["mediaMoveAfterResolution"] = try await moveRoundTrips(validationPage)
            guard validationPage.stopMediaCapture() else {
                throw ValidationError("Native media capture stop was rejected.")
            }
            try await waitForCondition("native media capture stop") {
                !validationPage.isCapturingMicrophone && !validationPage.isCapturingCamera
            }
            checks["mediaCaptureStopped"] = true

            var navigatedRequest: ChromiumMediaPermissionRequest?
            var navigationCancelled = false
            runtime.onMediaPermissionRequest = { request in
                navigatedRequest = request
                request.onCancel = { navigationCancelled = true }
            }
            let navigatingMedia = configuration.phased(configuration.mediaPage, "navigate-away")
            try validationPage.load(navigatingMedia)
            try await waitForCondition("pending media request before navigation") {
                navigatedRequest?.isPending == true
            }
            try validationPage.load(configuration.securePage)
            try await wait(for: validationPage, url: configuration.securePage,
                           title: configuration.secureTitle)
            try await waitForCondition("media request cancellation after navigation") {
                navigationCancelled && navigatedRequest?.isPending == false
            }
            checks["navigatedMediaRequestCancelled"] = navigatedRequest?.allow() == false

            var closedRequest: ChromiumMediaPermissionRequest?
            var closeCancelled = false
            runtime.onMediaPermissionRequest = { request in
                closedRequest = request
                request.onCancel = { closeCancelled = true }
            }
            let closingMedia = configuration.phased(configuration.mediaPage, "close")
            let mediaPage = try openedContext.makePage(url: closingMedia, hostWindowID: UUID())
            auxiliaryPages.append(mediaPage)
            try await waitForCondition("pending media request before close") {
                closedRequest?.page === mediaPage && closedRequest?.isPending == true
            }
            mediaPage.forceClose()
            guard await mediaPage.waitUntilClosed() else {
                throw ValidationError("Media permission validation page did not close.")
            }
            try await waitForCondition("media request cancellation after close") {
                closeCancelled && closedRequest?.isPending == false
            }
            checks["closedMediaRequestCancelled"] = closedRequest?.deny() == false

            var reentrantRequest: ChromiumMediaPermissionRequest?
            var reentrantCancellations = 0
            runtime.onMediaPermissionRequest = { request in
                reentrantRequest = request
                request.onCancel = { reentrantCancellations += 1 }
                request.page.forceClose()
            }
            let reentrantMedia = configuration.phased(configuration.mediaPage, "reentrant-close")
            let reentrantMediaPage = try openedContext.makePage(
                url: reentrantMedia, hostWindowID: UUID())
            auxiliaryPages.append(reentrantMediaPage)
            try await waitForCondition("reentrant media request delivery") {
                reentrantRequest?.page === reentrantMediaPage &&
                    (reentrantMediaPage.isClosing || reentrantMediaPage.isClosed)
            }
            guard await reentrantMediaPage.waitUntilClosed() else {
                throw ValidationError("Reentrant media permission page did not close.")
            }
            try await waitForCondition("reentrant media request cancellation") {
                reentrantCancellations == 1 && reentrantRequest?.isPending == false
            }
            checks["reentrantMediaCloseCancelledOnce"] = reentrantRequest?.allow() == false
            runtime.onMediaPermissionRequest = nil

            runtime.onJavaScriptDialog = nil
            try validationPage.load(configuration.javascriptConfirm)
            try await wait(for: validationPage, url: configuration.javascriptConfirm,
                           title: configuration.javascriptDeniedTitle)
            checks["unhandledJavaScriptDialogDenied"] = !validationPage.hasPendingPrompt

            var promptRequest: ChromiumJavaScriptDialogRequest?
            runtime.onJavaScriptDialog = { promptRequest = $0 }
            try validationPage.load(configuration.javascriptPrompt)
            try await waitForCondition("pending JavaScript prompt") {
                promptRequest?.isPending == true && validationPage.hasPendingPrompt
            }
            guard let promptRequest else {
                throw ValidationError("Native JavaScript prompt was not delivered.")
            }
            checks["javaScriptPromptMetadata"] = promptRequest.page === validationPage &&
                promptRequest.kind == .prompt &&
                promptRequest.message == "Cobble prompt \(configuration.token)" &&
                promptRequest.defaultText == "fixture-default" &&
                !promptRequest.requestingOrigin.isEmpty && !promptRequest.topLevelOrigin.isEmpty &&
                promptRequest.frameProcessID >= 0 && promptRequest.frameRoutingID >= 0 &&
                !promptRequest.frameToken.isEmpty && !promptRequest.isReload
            checks["javaScriptPromptMoveRejected"] = moveIsRejectedWhilePending(validationPage)
            checks["javaScriptPromptDevToolsRejected"] = devToolsOpenIsRejectedWithTemporaryHost(
                validationPage, reserveHost: reserveHost, closeHost: closeHost)
            checks["javaScriptPromptExactlyOnce"] =
                promptRequest.accept(promptText: configuration.token) && !promptRequest.cancel()
            try await wait(for: validationPage, url: configuration.javascriptPrompt,
                           title: configuration.javascriptAcceptedTitle)
            checks["javaScriptMoveAfterResolution"] = try await moveRoundTrips(validationPage)

            var staleDialog: ChromiumJavaScriptDialogRequest?
            var staleDialogCancellations = 0
            runtime.onJavaScriptDialog = { request in
                staleDialog = request
                request.onCancel = { staleDialogCancellations += 1 }
            }
            try validationPage.load(configuration.javascriptConfirm)
            try await waitForCondition("pending JavaScript dialog before navigation") {
                staleDialog?.isPending == true
            }
            try validationPage.load(configuration.domPage)
            try await waitForCondition("JavaScript dialog navigation cancellation") {
                staleDialogCancellations == 1 && staleDialog?.isPending == false
            }
            checks["javaScriptDialogNavigationCancelledOnce"] = staleDialog?.accept() == false

            var beforeUnload: ChromiumJavaScriptDialogRequest?
            stage("beforeunload-page", configuration)
            runtime.onJavaScriptDialog = {
                beforeUnload = $0
                stage("beforeunload-callback-\($0.kind)", configuration)
            }
            try validationPage.load(configuration.beforeUnloadPage)
            try await wait(for: validationPage, url: configuration.beforeUnloadPage,
                           title: configuration.beforeUnloadReadyTitle)
            try JSONEncoder().encode([
                "url": configuration.beforeUnloadPage.absoluteString
            ]).write(to: configuration.beforeUnloadMarker, options: .atomic)
            try await waitForCondition("trusted beforeunload activation") {
                FileManager.default.fileExists(atPath: configuration.beforeUnloadActivated.path)
            }
            stage("beforeunload-load-call", configuration)
            try validationPage.load(configuration.beforeUnloadTarget)
            stage("beforeunload-load-returned", configuration)
            try await waitForCondition("cross-origin beforeunload prompt") {
                beforeUnload?.isPending == true && validationPage.hasPendingPrompt
            }
            guard let beforeUnload else {
                throw ValidationError("Cross-origin beforeunload request was not delivered.")
            }
            checks["crossOriginBeforeUnloadMetadata"] = beforeUnload.page === validationPage &&
                beforeUnload.kind == .beforeUnload && !beforeUnload.isReload &&
                !beforeUnload.requestingOrigin.isEmpty && !beforeUnload.topLevelOrigin.isEmpty
            checks["crossOriginBeforeUnloadAccepted"] = beforeUnload.accept() && !beforeUnload.cancel()
            try await wait(for: validationPage, url: configuration.beforeUnloadTarget,
                           title: configuration.domTitle)
            runtime.onJavaScriptDialog = nil

            stage("http-auth", configuration)
            var directAuthRequest: ChromiumHTTPAuthRequest?
            runtime.onHTTPAuthRequest = { directAuthRequest = $0 }
            let directAuthPage = try openedContext.makePage(
                url: configuration.httpAuthDirect, hostWindowID: UUID())
            auxiliaryPages.append(directAuthPage)
            try await waitForCondition("fresh-page HTTP authentication request") {
                directAuthRequest?.page === directAuthPage && directAuthRequest?.isPending == true
            }
            guard let directAuthRequest else {
                throw ValidationError("Fresh-page HTTP authentication request was not delivered.")
            }
            checks["freshPageHTTPAuthMetadata"] =
                directAuthRequest.requestURL == configuration.httpAuthDirect &&
                directAuthRequest.primaryMainFrameNavigation && directAuthRequest.navigation &&
                directAuthRequest.firstAttempt && !directAuthRequest.isProxy
            checks["httpAuthPromptMoveRejected"] = moveIsRejectedWhilePending(directAuthPage)
            checks["httpAuthPromptDevToolsRejected"] = devToolsOpenIsRejectedWithTemporaryHost(
                directAuthPage, reserveHost: reserveHost, closeHost: closeHost)
            checks["freshPageHTTPAuthSubmit"] = directAuthRequest.submit(
                username: "cobble", password: configuration.token)
            try await wait(for: directAuthPage, url: configuration.httpAuthDirect,
                           title: configuration.authGrantedTitle)
            checks["httpAuthMoveAfterResolution"] = try await moveRoundTrips(directAuthPage)
            directAuthPage.forceClose()
            guard await directAuthPage.waitUntilClosed() else {
                throw ValidationError("Fresh-page authentication fixture did not close.")
            }

            var authRequest: ChromiumHTTPAuthRequest?
            runtime.onHTTPAuthRequest = { authRequest = $0 }
            try validationPage.load(configuration.httpAuth)
            try await waitForCondition("pending HTTP authentication request") {
                authRequest?.isPending == true && validationPage.hasPendingPrompt
            }
            guard let authRequest else {
                throw ValidationError("Native HTTP authentication request was not delivered.")
            }
            checks["httpAuthMetadata"] = authRequest.page === validationPage &&
                authRequest.requestURL == configuration.httpAuth &&
                authRequest.scheme.lowercased() == "basic" &&
                authRequest.realm == "Cobble Fixture \(configuration.token)" &&
                !authRequest.challengerOrigin.isEmpty && !authRequest.topLevelOrigin.isEmpty &&
                !authRequest.isProxy && authRequest.firstAttempt &&
                authRequest.primaryMainFrameNavigation && authRequest.navigation
            checks["httpAuthSubmitExactlyOnce"] =
                authRequest.submit(username: "cobble", password: configuration.token) &&
                !authRequest.cancel()
            try await wait(for: validationPage, url: configuration.httpAuth,
                           title: configuration.authGrantedTitle)

            var subresourceAuth: ChromiumHTTPAuthRequest?
            runtime.onHTTPAuthRequest = { subresourceAuth = $0 }
            try validationPage.load(configuration.httpAuthSubresourcePage)
            try await waitForCondition("subresource HTTP authentication request") {
                subresourceAuth?.isPending == true
            }
            guard let subresourceAuth else {
                throw ValidationError("Subresource HTTP authentication request was not delivered.")
            }
            checks["subresourceHTTPAuthMetadata"] =
                subresourceAuth.requestURL?.host == "cobble-auth-subresource.test" &&
                !subresourceAuth.primaryMainFrameNavigation && !subresourceAuth.navigation &&
                subresourceAuth.topLevelOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                    configuration.origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            checks["subresourceHTTPAuthSubmit"] = subresourceAuth.submit(
                username: "cobble", password: configuration.token)
            try await wait(for: validationPage, url: configuration.httpAuthSubresourcePage,
                           title: configuration.authSubresourceGrantedTitle)

            var cancelledAuth: ChromiumHTTPAuthRequest?
            var authCancellations = 0
            runtime.onHTTPAuthRequest = { request in
                cancelledAuth = request
                request.onCancel = { authCancellations += 1 }
            }
            try validationPage.load(configuration.httpAuthCancellation)
            try await waitForCondition("pending HTTP authentication before navigation") {
                cancelledAuth?.isPending == true
            }
            try validationPage.load(configuration.domPage)
            try await waitForCondition("HTTP authentication navigation cancellation") {
                authCancellations == 1 && cancelledAuth?.isPending == false
            }
            checks["httpAuthNavigationCancelledOnce"] = cancelledAuth?.cancel() == false
            runtime.onHTTPAuthRequest = nil

            stage("file-chooser", configuration)
            let selectedFile = configuration.userDataDirectory
                .appendingPathComponent("chooser-\(configuration.token).txt")
            try Data("selected \(configuration.token)".utf8).write(to: selectedFile)
            var chooserRequest: ChromiumFileChooserRequest?
            runtime.onFileChooserRequest = { chooserRequest = $0 }
            try validationPage.load(configuration.fileChooser)
            try await wait(for: validationPage, url: configuration.fileChooser,
                           title: configuration.filePendingTitle)
            try JSONSerialization.data(withJSONObject: [
                "url": configuration.fileChooser.absoluteString,
                "sequence": 1,
                "removeFrame": false,
            ]).write(to: configuration.fileChooserMarker, options: .atomic)
            try await waitForCondition("pending file chooser") {
                chooserRequest?.isPending == true && validationPage.hasPendingPrompt
            }
            guard let chooserRequest else {
                throw ValidationError("Native file chooser request was not delivered.")
            }
            checks["fileChooserMetadata"] = chooserRequest.page === validationPage &&
                chooserRequest.mode == .open && !chooserRequest.requestingOrigin.isEmpty &&
                !chooserRequest.topLevelOrigin.isEmpty && chooserRequest.frameProcessID >= 0 &&
                chooserRequest.frameRoutingID >= 0 && !chooserRequest.frameToken.isEmpty &&
                chooserRequest.acceptedTypes.contains("text/plain")
            checks["fileChooserPromptMoveRejected"] = moveIsRejectedWhilePending(validationPage)
            checks["fileChooserPromptDevToolsRejected"] = devToolsOpenIsRejectedWithTemporaryHost(
                validationPage, reserveHost: reserveHost, closeHost: closeHost)
            checks["fileChooserSelectExactlyOnce"] =
                chooserRequest.select([selectedFile]) && !chooserRequest.cancel()
            try await wait(for: validationPage, url: configuration.fileChooser,
                           title: configuration.fileSelectedTitle)
            checks["fileChooserMoveAfterResolution"] = try await moveRoundTrips(validationPage)

            var frameChooser: ChromiumFileChooserRequest?
            var frameChooserCancellations = 0
            runtime.onFileChooserRequest = { request in
                frameChooser = request
                request.onCancel = { frameChooserCancellations += 1 }
            }
            try validationPage.load(configuration.fileFrameParent)
            try await wait(for: validationPage, url: configuration.fileFrameParent,
                           title: configuration.fileFrameTitle)
            try JSONSerialization.data(withJSONObject: [
                "url": configuration.fileFrameParent.absoluteString,
                "sequence": 2,
                "removeFrame": true,
            ]).write(to: configuration.fileChooserMarker, options: .atomic)
            try await waitForCondition("iframe file chooser request") {
                frameChooser?.isPending == true
            }
            try await waitForCondition("removed iframe file chooser cancellation") {
                frameChooserCancellations == 1 && frameChooser?.isPending == false
            }
            checks["removedFrameFileChooserCancelledOnce"] = frameChooser?.cancel() == false &&
                !validationPage.hasPendingPrompt

            var crashChooser: ChromiumFileChooserRequest?
            var crashChooserCancellations = 0
            runtime.onFileChooserRequest = { request in
                crashChooser = request
                request.onCancel = { crashChooserCancellations += 1 }
            }
            let crashPage = try openedContext.makePage(
                url: configuration.crashFileChooser, hostWindowID: UUID())
            auxiliaryPages.append(crashPage)
            try await wait(for: crashPage, url: configuration.crashFileChooser,
                           title: configuration.filePendingTitle)
            let targetCrashToolsHost = reserveHost()
            let targetCrashTools = try crashPage.openDevTools(hostWindowID: targetCrashToolsHost)
            var targetCrashToolsCloseCount = 0
            targetCrashTools.onClose = { targetCrashToolsCloseCount += 1 }
            guard showDevTools(targetCrashTools, targetCrashToolsHost) else {
                throw ValidationError("Target-crash DevTools frontend did not attach.")
            }
            try JSONSerialization.data(withJSONObject: [
                "url": configuration.crashFileChooser.absoluteString,
                "sequence": 3,
                "removeFrame": false,
            ]).write(to: configuration.fileChooserMarker, options: .atomic)
            try await waitForCondition("file chooser before renderer crash") {
                crashChooser?.page === crashPage && crashChooser?.isPending == true
            }
            try JSONEncoder().encode([
                "url": configuration.crashFileChooser.absoluteString
            ]).write(to: configuration.promptCrashMarker, options: .atomic)
            try await waitForCondition("renderer crash prompt cancellation") {
                crashPage.isCrashed && crashChooserCancellations == 1 &&
                    crashChooser?.isPending == false
            }
            try await waitForCondition("inspected target crash closes DevTools") {
                targetCrashTools.isClosed && targetCrashToolsCloseCount == 1
            }
            checks["rendererTerminationReasonAvailable"] =
                crashPage.rendererTerminationStatus != nil && !crashPage.isDocumentReady &&
                !crashPage.isUnresponsive
            checks["rendererCrashFileChooserCancelledOnce"] =
                crashChooser?.select([selectedFile]) == false
            checks["devToolsTargetCrashClosesOnce"] = targetCrashTools.isClosed &&
                !targetCrashTools.close() && targetCrashToolsCloseCount == 1
            closeHost?(targetCrashToolsHost)
            checks["crashedConnectionDetailsUnavailable"] =
                try await crashPage.connectionDetails() == nil
            crashPage.forceClose()
            guard await crashPage.waitUntilClosed() else {
                throw ValidationError("Renderer crash prompt fixture did not close.")
            }
            let selectedFolder = configuration.userDataDirectory
                .appendingPathComponent("chooser-folder-\(configuration.token)", isDirectory: true)
            let nestedFolder = selectedFolder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedFolder,
                                                    withIntermediateDirectories: true)
            try Data("top \(configuration.token)".utf8)
                .write(to: selectedFolder.appendingPathComponent("a.txt"))
            try Data("nested \(configuration.token)".utf8)
                .write(to: nestedFolder.appendingPathComponent("b.txt"))
            var folderChooserRequest: ChromiumFileChooserRequest?
            runtime.onFileChooserRequest = { folderChooserRequest = $0 }
            try validationPage.load(configuration.fileFolder)
            try await wait(for: validationPage, url: configuration.fileFolder,
                           title: configuration.folderPendingTitle)
            try JSONSerialization.data(withJSONObject: [
                "url": configuration.fileFolder.absoluteString,
                "sequence": 4,
                "removeFrame": false,
            ]).write(to: configuration.fileChooserMarker, options: .atomic)
            try await waitForCondition("pending folder upload chooser") {
                folderChooserRequest?.isPending == true
            }
            guard let folderRequest = folderChooserRequest, folderRequest.mode == .uploadFolder,
                  folderRequest.select([selectedFolder]) else {
                throw ValidationError("Native folder upload selection was rejected.")
            }
            try await wait(for: validationPage, url: configuration.fileFolder,
                           title: configuration.folderSelectedTitle)
            checks["folderUploadEnumeratesNestedRelativePaths"] = true

            stage("exclusive-access", configuration)
            try validationPage.load(configuration.exclusiveAccess)
            try await wait(for: validationPage, url: configuration.exclusiveAccess,
                           title: configuration.exclusiveReadyTitle)
            let exclusiveWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
            try JSONSerialization.data(withJSONObject: [
                "url": configuration.exclusiveAccess.absoluteString,
            ]).write(to: configuration.exclusiveAccessMarker, options: .atomic)
            for capability in ["pip", "documentPip", "displayMedia", "bluetooth",
                               "usb", "serial", "hid", "payment"] {
                try await waitForCondition("exclusive \(capability) result") {
                    guard let data = try? Data(contentsOf: configuration.exclusiveAccessOutcome),
                          let value = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
                          let outcomes = value["containment"] as? [String: Any]
                    else { return false }
                    return outcomes[capability] != nil
                }
            }
            try await wait(for: validationPage, url: configuration.exclusiveAccess,
                           title: configuration.exclusiveDeniedTitle, timeout: .seconds(32))
            let exclusiveDOM = try await validationPage.currentDOM()
            let capabilityOutcomes = ["bluetooth", "usb", "serial", "hid", "payment"].map {
                "\($0)=\(attribute(named: $0, in: exclusiveDOM) ?? "missing")"
            }.joined(separator: " ")
            FileHandle.standardError.write(Data("exclusive capabilities \(capabilityOutcomes)\n".utf8))
            checks["exclusivePageVisible"] = validationPage.nativeView.window != nil &&
                exclusiveDOM.contains("data-visibility=\"visible\"") &&
                exclusiveDOM.contains("data-focused=\"true\"") &&
                exclusiveDOM.contains("data-viewport=\"true\"") &&
                exclusiveDOM.contains("data-fullscreen-enabled=\"true\"")
            checks["fullscreenDenied"] = exclusiveDOM.contains("data-fullscreen-denied=\"true\"")
            checks["pointerLockDenied"] = exclusiveDOM.contains("data-pointer-denied=\"true\"")
            checks["keyboardLockDeniedWithoutKeyCapture"] =
                exclusiveDOM.contains("data-keyboard-denied=\"true\"") &&
                exclusiveDOM.contains("data-key-delivered=\"true\"")
            checks["deviceAndPaymentRequestsSettleDenied"] =
                ["bluetooth", "usb", "serial", "hid", "payment"].allSatisfy {
                    exclusiveDOM.contains("data-\($0)=\"rejected\"") ||
                        exclusiveDOM.contains("data-\($0)=\"empty\"") ||
                        exclusiveDOM.contains("data-\($0)=\"unavailable\"")
                }
            let noCapabilityWindowEscaped = Set(NSApp.windows.map(ObjectIdentifier.init)) ==
                exclusiveWindowIDs
            checks["pictureInPictureDeniedNoWindow"] =
                exclusiveDOM.contains("data-pip=\"rejected\"") &&
                exclusiveDOM.contains("data-pip-activation=\"true\"") &&
                exclusiveDOM.contains("data-pip-video-ready=\"true\"") &&
                noCapabilityWindowEscaped
            checks["documentPictureInPictureDeniedNoWindow"] =
                (exclusiveDOM.contains("data-document-pip=\"rejected\"") ||
                    exclusiveDOM.contains("data-document-pip=\"unavailable\"")) &&
                (exclusiveDOM.contains("data-document-pip=\"unavailable\"") ||
                    exclusiveDOM.contains("data-document-pip-activation=\"true\"")) &&
                noCapabilityWindowEscaped
            checks["displayMediaDeniedNoPicker"] =
                exclusiveDOM.contains("data-display-media=\"rejected\"") &&
                exclusiveDOM.contains("data-display-media-activation=\"true\"") &&
                noCapabilityWindowEscaped

            runtime.onFileChooserRequest = nil

            stage("external-protocol", configuration)
            runtime.onExternalProtocolRequest = nil
            try validationPage.load(configuration.externalProtocol("unhandled"))
            try await wait(for: validationPage, url: configuration.externalProtocol("unhandled"),
                           title: configuration.externalProtocolTitle("unhandled"))
            try await activateExternalProtocol(on: validationPage, sequence: 1,
                                               configuration: configuration)
            try await Task.sleep(for: .milliseconds(500))
            checks["unhandledExternalProtocolDenied"] = !validationPage.hasPendingPrompt

            var externalRequest: ChromiumExternalProtocolRequest?
            runtime.onExternalProtocolRequest = { externalRequest = $0 }
            try validationPage.load(configuration.externalProtocol("allow"))
            try await wait(for: validationPage, url: configuration.externalProtocol("allow"),
                           title: configuration.externalProtocolTitle("allow"))
            try await activateExternalProtocol(on: validationPage, sequence: 2,
                                               configuration: configuration)
            try await waitForCondition("pending external protocol allow request") {
                externalRequest?.isPending == true && validationPage.hasPendingPrompt
            }
            guard let allowedExternal = externalRequest else {
                throw ValidationError("External protocol allow request was not delivered.")
            }
            checks["externalProtocolMetadata"] = allowedExternal.page === validationPage &&
                allowedExternal.targetURL.absoluteString ==
                    "cobble-fixture:allow-\(configuration.token)" &&
                !allowedExternal.requestingOrigin.isEmpty &&
                allowedExternal.topLevelOrigin == allowedExternal.requestingOrigin &&
                allowedExternal.frameProcessID >= 0 && allowedExternal.frameRoutingID >= 0 &&
                !allowedExternal.frameToken.isEmpty && allowedExternal.userGesture &&
                allowedExternal.isPrimaryMainFrame && !allowedExternal.isFencedFrame
            checks["externalProtocolPromptMoveRejected"] =
                moveIsRejectedWhilePending(validationPage)
            checks["externalProtocolPromptDevToolsRejected"] =
                devToolsOpenIsRejectedWithTemporaryHost(
                    validationPage, reserveHost: reserveHost, closeHost: closeHost)
            checks["externalProtocolAllowExactlyOnce"] =
                allowedExternal.allow() && !allowedExternal.deny() &&
                !validationPage.hasPendingPrompt
            checks["externalProtocolMoveAfterResolution"] = try await moveRoundTrips(validationPage)

            externalRequest = nil
            try validationPage.load(configuration.externalProtocol("deny"))
            try await wait(for: validationPage, url: configuration.externalProtocol("deny"),
                           title: configuration.externalProtocolTitle("deny"))
            try await activateExternalProtocol(on: validationPage, sequence: 3,
                                               configuration: configuration)
            try await waitForCondition("pending external protocol deny request") {
                externalRequest?.isPending == true
            }
            checks["externalProtocolDenyExactlyOnce"] =
                externalRequest?.deny() == true && externalRequest?.allow() == false

            var staleExternal: ChromiumExternalProtocolRequest?
            var staleExternalCancellations = 0
            runtime.onExternalProtocolRequest = { request in
                staleExternal = request
                request.onCancel = { staleExternalCancellations += 1 }
            }
            try validationPage.load(configuration.externalProtocol("navigate"))
            try await wait(for: validationPage, url: configuration.externalProtocol("navigate"),
                           title: configuration.externalProtocolTitle("navigate"))
            try await activateExternalProtocol(on: validationPage, sequence: 4,
                                               configuration: configuration)
            try await waitForCondition("pending external protocol before navigation") {
                staleExternal?.isPending == true
            }
            try validationPage.load(configuration.domPage)
            try await waitForCondition("external protocol navigation cancellation") {
                staleExternalCancellations == 1 && staleExternal?.isPending == false
            }
            checks["externalProtocolNavigationCancelledOnce"] = staleExternal?.deny() == false

            var rejectedExternalDeliveries = 0
            runtime.onExternalProtocolRequest = { request in
                rejectedExternalDeliveries += 1
                request.deny()
            }
            try validationPage.load(configuration.externalProtocol("iframe"))
            try await wait(for: validationPage, url: configuration.externalProtocol("iframe"),
                           title: configuration.externalProtocolTitle("iframe"))
            try await activateExternalProtocol(on: validationPage, sequence: 5, frame: true,
                                               configuration: configuration)
            try await Task.sleep(for: .milliseconds(750))
            checks["iframeExternalProtocolNotPublished"] =
                rejectedExternalDeliveries == 0 && !validationPage.hasPendingPrompt
            try validationPage.load(configuration.externalProtocol("automatic"))
            try await wait(for: validationPage, url: configuration.externalProtocol("automatic"),
                           title: configuration.externalProtocolTitle("automatic"))
            try await Task.sleep(for: .milliseconds(750))
            checks["gesturelessExternalProtocolNotPublished"] =
                rejectedExternalDeliveries == 0 && !validationPage.hasPendingPrompt

            var closedExternal: ChromiumExternalProtocolRequest?
            var closedExternalCancellations = 0
            runtime.onExternalProtocolRequest = { request in
                closedExternal = request
                request.onCancel = { closedExternalCancellations += 1 }
            }
            let externalClosePage = try openedContext.makePage(
                url: configuration.externalProtocol("close"), hostWindowID: UUID())
            auxiliaryPages.append(externalClosePage)
            try await wait(for: externalClosePage, url: configuration.externalProtocol("close"),
                           title: configuration.externalProtocolTitle("close"))
            try await activateExternalProtocol(on: externalClosePage, sequence: 6,
                                               configuration: configuration)
            try await waitForCondition("pending external protocol before close") {
                closedExternal?.page === externalClosePage && closedExternal?.isPending == true
            }
            externalClosePage.forceClose()
            guard await externalClosePage.waitUntilClosed() else {
                throw ValidationError("External protocol close fixture did not close.")
            }
            try await waitForCondition("external protocol close cancellation") {
                closedExternalCancellations == 1 && closedExternal?.isPending == false
            }
            checks["externalProtocolCloseCancelledOnce"] = closedExternal?.allow() == false
            runtime.onExternalProtocolRequest = nil

            let pageCloseTargetHost = reserveHost()
            let pageCloseTarget = try openedContext.makePage(
                url: configuration.extensionTarget, hostWindowID: pageCloseTargetHost)
            auxiliaryPages.append(pageCloseTarget)
            try await wait(for: pageCloseTarget, url: configuration.extensionTarget,
                           title: configuration.baselineTitle)
            let pageCloseToolsHost = reserveHost()
            let pageCloseTools = try pageCloseTarget.openDevTools(hostWindowID: pageCloseToolsHost)
            var pageCloseToolsCount = 0
            pageCloseTools.onClose = { pageCloseToolsCount += 1 }
            guard showDevTools(pageCloseTools, pageCloseToolsHost) else {
                throw ValidationError("Page-close DevTools frontend did not attach.")
            }
            pageCloseTarget.forceClose()
            guard await pageCloseTarget.waitUntilClosed() else {
                throw ValidationError("DevTools inspected page did not close.")
            }
            try await waitForCondition("inspected page close retires DevTools") {
                pageCloseTools.isClosed && pageCloseToolsCount == 1
            }
            checks["devToolsPageCloseClosesOnce"] = !pageCloseTools.close() &&
                pageCloseToolsCount == 1
            closeHost?(pageCloseToolsHost)
            closeHost?(pageCloseTargetHost)

            let toolsContext = try await runtime.openContext(profileKey: "harness-devtools-context")
            auxiliaryContexts.append(toolsContext)
            let contextTargetHost = reserveHost()
            let contextTarget = try toolsContext.makePage(
                url: configuration.extensionTarget, hostWindowID: contextTargetHost)
            auxiliaryPages.append(contextTarget)
            try await wait(for: contextTarget, url: configuration.extensionTarget,
                           title: configuration.baselineTitle)
            let contextToolsHost = reserveHost()
            let contextTools = try contextTarget.openDevTools(hostWindowID: contextToolsHost)
            var contextToolsCloseCount = 0
            contextTools.onClose = { contextToolsCloseCount += 1 }
            guard showDevTools(contextTools, contextToolsHost) else {
                throw ValidationError("Context-close DevTools frontend did not attach.")
            }
            guard await toolsContext.close() else {
                throw ValidationError("DevTools context refused close.")
            }
            try await waitForCondition("context close retires DevTools") {
                contextTools.isClosed && contextToolsCloseCount == 1
            }
            checks["devToolsContextCloseClosesOnce"] = !contextTools.close() &&
                contextToolsCloseCount == 1
            closeHost?(contextToolsHost)
            closeHost?(contextTargetHost)
            try await runtime.scheduleProfileDeletion(key: "harness-devtools-context")
            checks["devToolsProfileDeletableAfterClose"] = pathIsAbsent(
                configuration.profileDirectory(key: "harness-devtools-context"))

            let privateToolsContext = try await runtime.openContext(
                profileKey: "harness-validation", privateWindowKey: "devtools-private")
            auxiliaryContexts.append(privateToolsContext)
            let privateTargetHost = reserveHost()
            let privateTarget = try privateToolsContext.makePage(
                url: configuration.extensionTarget, hostWindowID: privateTargetHost)
            auxiliaryPages.append(privateTarget)
            try await wait(for: privateTarget, url: configuration.extensionTarget,
                           title: configuration.baselineTitle)
            let privateToolsHost = reserveHost()
            var privateTools: ChromiumDevToolsSession? = try privateTarget.openDevTools(
                hostWindowID: privateToolsHost)
            var privateToolsCloseCount = 0
            privateTools?.onClose = {
                privateToolsCloseCount += 1
                privateTools = nil
            }
            guard let mountedPrivateTools = privateTools,
                  showDevTools(mountedPrivateTools, privateToolsHost) else {
                throw ValidationError("Private DevTools frontend did not attach.")
            }
            let privateToolsCloseAccepted = mountedPrivateTools.close()
            guard privateToolsCloseAccepted else {
                throw ValidationError("Private DevTools frontend did not open and close.")
            }
            try await waitForCondition("private DevTools release from close callback") {
                privateToolsCloseCount == 1
            }
            checks["devToolsCloseCallbackCanReleaseSession"] =
                privateTools == nil && privateToolsCloseCount == 1
            guard await privateToolsContext.close() else {
                throw ValidationError("Private DevTools context refused close.")
            }
            checks["devToolsPrivateContextClosesWithoutRetention"] =
                privateToolsContext.isClosed && privateTarget.isClosed
            closeHost?(privateToolsHost)
            closeHost?(privateTargetHost)

            stage("reload-dom-archive", configuration)
            try validationPage.load(configuration.reloadGET)
            try await wait(for: validationPage, url: configuration.reloadGET,
                           title: configuration.reloadGETTitle(1))
            guard validationPage.reload() else {
                throw ValidationError("Native GET reload was refused.")
            }
            try await wait(for: validationPage, url: configuration.reloadGET,
                           title: configuration.reloadGETTitle(2))
            checks["getReloadAccepted"] = true

            try validationPage.load(configuration.reloadPOSTStart)
            try await wait(for: validationPage, url: configuration.reloadPOSTTarget,
                           title: configuration.reloadPOSTTitle(1))
            let postDOM = try await validationPage.currentDOM()
            checks["initialPOSTBodyDelivered"] = postDOM.contains("token=\(configuration.token)")
            checks["postReloadDefaultDenied"] = validationPage.reload()
            try await Task.sleep(for: .milliseconds(500))
            checks["postReloadPreservedBodyAndHitCount"] =
                validationPage.urlString == configuration.reloadPOSTTarget.absoluteString &&
                validationPage.title == configuration.reloadPOSTTitle(1)
            try JSONSerialization.data(withJSONObject: [
                "url": configuration.reloadPOSTTarget.absoluteString,
            ]).write(to: configuration.postReloadMarker, options: .atomic)
            try await waitForCondition("renderer POST reload activation") {
                (try? String(contentsOf: configuration.postReloadActivated,
                             encoding: .utf8)) == "1\n"
            }
            try await Task.sleep(for: .milliseconds(750))
            checks["rendererPOSTReloadDenied"] =
                validationPage.urlString == configuration.reloadPOSTTarget.absoluteString &&
                validationPage.title == configuration.reloadPOSTTitle(1) &&
                !validationPage.hasPendingPrompt

            guard let showPage else {
                throw ValidationError("Native validation requires a page host.")
            }
            if !configuration.skipRepostValidation {
                stage("repost", configuration)
                checks.merge(try await HarnessRepostValidation.run(
                    runtime: runtime, token: configuration.token, origin: configuration.origin,
                    baseline: configuration.extensionTarget, reserveHost: reserveHost,
                    showPage: showPage, closeHost: closeHost,
                    activateBeforeUnload: { repostPage in
                        try JSONSerialization.data(withJSONObject: ["url": repostPage.urlString])
                            .write(to: configuration.repostBeforeUnloadMarker, options: .atomic)
                        try await waitForCondition("trusted repost before-unload activation") {
                            (try? String(contentsOf: configuration.repostBeforeUnloadActivated,
                                         encoding: .utf8)) == "activated\n"
                        }
                    })) { _, new in new }
            }

            try validationPage.load(configuration.domPage)
            try await wait(for: validationPage, url: configuration.domPage,
                           title: configuration.domTitle)
            let dom = try await validationPage.currentDOM()
            checks["currentDOMIncludesLiveMutation"] = dom.contains("mutated-\(configuration.token)") &&
                dom.contains("id=\"live\"")
            let archive = try await validationPage.webArchive()
            let archiveText = String(decoding: archive, as: UTF8.self).lowercased()
            checks["nativeMHTMLArchive"] = archive.count > 256 && archive.count < 16_000_000 &&
                archiveText.contains("mime-version:") && archiveText.contains("multipart/related") &&
                archiveText.contains("content-location: \(configuration.domPage.absoluteString.lowercased())")

            var sameDocument = URLComponents(url: configuration.domPage,
                                             resolvingAgainstBaseURL: false)!
            sameDocument.fragment = "same-document"
            let sameDocumentDOM = Task { try await validationPage.currentDOM() }
            await Task.yield()
            try validationPage.load(sameDocument.url!)
            let sameDOM = try await sameDocumentDOM.value
            checks["sameDocumentNavigationPreservesDOMRequest"] =
                sameDOM.contains("mutated-\(configuration.token)")

            let staleArchive = Task { try await validationPage.webArchive() }
            await Task.yield()
            try validationPage.load(configuration.securePage)
            checks["navigationCancelsStaleArchive"] = await rejectsPageData(staleArchive)
            try await wait(for: validationPage, url: configuration.securePage,
                           title: configuration.secureTitle)

            let closingDOMPage = try openedContext.makePage(
                url: configuration.domPage, hostWindowID: UUID())
            auxiliaryPages.append(closingDOMPage)
            try await wait(for: closingDOMPage, url: configuration.domPage,
                           title: configuration.domTitle)
            let closingDOM = Task { try await closingDOMPage.currentDOM() }
            await Task.yield()
            closingDOMPage.forceClose()
            checks["closeCancelsOutstandingDOM"] = await rejectsPageData(closingDOM)
            guard await closingDOMPage.waitUntilClosed() else {
                throw ValidationError("DOM cancellation validation page did not close.")
            }

            try validationPage.load(configuration.extensionTarget)
            try await waitForStableTitle(for: validationPage, url: configuration.extensionTarget,
                                         title: configuration.baselineTitle)

            var audioStateEvents = 0
            validationPage.onChange = { audioStateEvents += 1 }
            try validationPage.setAudioMuted(true)
            try await waitForCondition("native tab mute state event") {
                validationPage.isAudioMuted && audioStateEvents > 0
            }
            checks["tabOutputMuteReported"] = true
            audioStateEvents = 0
            try validationPage.setAudioMuted(false)
            try await waitForCondition("native tab unmute state event") {
                !validationPage.isAudioMuted && audioStateEvents > 0
            }
            checks["tabOutputUnmuteReported"] = true
            validationPage.onChange = nil

            var undeclaredRejected = false
            do {
                try await runtime.setExtension(installedID, siteAccessAt: configuration.undeclaredOrigin,
                                               allowed: true, in: openedContext)
            } catch {
                undeclaredRejected = true
            }
            checks["undeclaredGrantRejected"] = undeclaredRejected
            guard undeclaredRejected else {
                throw ValidationError("Chromium accepted access for an undeclared localhost origin.")
            }

            try await runtime.setExtension(installedID, siteAccessAt: configuration.origin,
                                           allowed: true, in: openedContext)
            validationPage.reload()
            try await wait(for: validationPage, url: configuration.extensionTarget,
                           title: configuration.activeTitle)
            checks["declaredGrantInjected"] = validationPage.title == configuration.activeTitle

            try await runtime.setExtension(installedID, siteAccessAt: configuration.origin,
                                           allowed: false, in: openedContext)
            validationPage.reload()
            try await waitForStableTitle(for: validationPage, url: configuration.extensionTarget,
                                         title: configuration.baselineTitle)
            checks["revocationRemovedInjection"] = validationPage.title == configuration.baselineTitle

            var committedVisits: [(URL, String)] = []
            validationPage.onNavigationCommitted = { committedVisits.append(($0, $1)) }
            try validationPage.load(configuration.delayedTitle)
            try await wait(for: validationPage, url: configuration.delayedTitle,
                           title: configuration.delayedTitleValue)
            try await waitForCondition("one settled navigation callback") {
                committedVisits.count == 1
            }
            checks["navigationCallbackUsesSettledTitle"] =
                committedVisits.count == 1 &&
                committedVisits[0].0.absoluteString == configuration.delayedTitle.absoluteString &&
                committedVisits[0].1 == configuration.delayedTitleValue
            guard checks["navigationCallbackUsesSettledTitle"] == true else {
                throw ValidationError("Navigation callback did not use the settled document title exactly once.")
            }

            committedVisits.removeAll()
            try validationPage.load(configuration.streamedHistoryTitle)
            try await wait(for: validationPage, url: configuration.streamedHistoryAfter,
                           title: configuration.delayedTitleValue)
            try await waitForCondition("three ordered streamed navigation callbacks") {
                committedVisits.count == 3
            }
            checks["sameDocumentNavigationCallbacksPreserveOrder"] =
                committedVisits.map { $0.0.absoluteString } ==
                    [configuration.streamedHistoryTitle, configuration.streamedHistoryDuring,
                     configuration.streamedHistoryAfter].map(\.absoluteString) &&
                committedVisits.map(\.1) == [configuration.interimTitleValue,
                                               configuration.interimTitleValue,
                                               configuration.delayedTitleValue]
            validationPage.onNavigationCommitted = nil
            guard checks["sameDocumentNavigationCallbacksPreserveOrder"] == true else {
                throw ValidationError("Same-document callbacks did not preserve commit order and titles.")
            }

            try validationPage.load(configuration.storageWrite)
            try await wait(for: validationPage, url: configuration.storageWrite,
                           title: configuration.writtenTitle)
            let sites = try await openedContext.websiteDataSites()
            checks["websiteDataListed"] = sites.contains("127.0.0.1")
            guard checks["websiteDataListed"] == true else {
                throw ValidationError("Loopback cookie and local storage did not appear in native website data.")
            }
            try await openedContext.removeWebsiteData(for: "127.0.0.1")
            try validationPage.load(configuration.storageRead)
            try await wait(for: validationPage, url: configuration.storageRead,
                           title: configuration.emptyTitle)
            checks["websiteDataRemoved"] = validationPage.title == configuration.emptyTitle

            try validationPage.load(configuration.phased(configuration.storageWrite, "normal-write"))
            try await wait(for: validationPage,
                           url: configuration.phased(configuration.storageWrite, "normal-write"),
                           title: configuration.writtenTitle)

            let privateA = try await runtime.openContext(
                profileKey: "harness-validation", privateWindowKey: "isolation-a")
            auxiliaryContexts.append(privateA)
            let privateAPage = try privateA.makePage(
                url: configuration.phased(configuration.storageRead, "private-a-empty"),
                hostWindowID: UUID())
            auxiliaryPages.append(privateAPage)
            try await wait(for: privateAPage,
                           url: configuration.phased(configuration.storageRead, "private-a-empty"),
                           title: configuration.emptyTitle)
            checks["privateIsolatedFromNormal"] = true
            try privateAPage.load(configuration.phased(configuration.storageWrite, "private-a-write"))
            try await wait(for: privateAPage,
                           url: configuration.phased(configuration.storageWrite, "private-a-write"),
                           title: configuration.writtenTitle)

            let privateB = try await runtime.openContext(
                profileKey: "harness-validation", privateWindowKey: "isolation-b")
            auxiliaryContexts.append(privateB)
            let privateBPage = try privateB.makePage(
                url: configuration.phased(configuration.storageRead, "private-b-empty"),
                hostWindowID: UUID())
            auxiliaryPages.append(privateBPage)
            try await wait(for: privateBPage,
                           url: configuration.phased(configuration.storageRead, "private-b-empty"),
                           title: configuration.emptyTitle)
            checks["privateWindowsIsolated"] = true

            let otherNormal = try await runtime.openContext(profileKey: "harness-validation-other")
            auxiliaryContexts.append(otherNormal)
            let otherNormalPage = try otherNormal.makePage(
                url: configuration.phased(configuration.storageRead, "other-normal-empty"),
                hostWindowID: UUID())
            auxiliaryPages.append(otherNormalPage)
            try await wait(for: otherNormalPage,
                           url: configuration.phased(configuration.storageRead, "other-normal-empty"),
                           title: configuration.emptyTitle)
            checks["normalProfilesIsolated"] = true

            for isolatedPage in [privateAPage, privateBPage] {
                isolatedPage.forceClose()
                guard await isolatedPage.waitUntilClosed() else {
                    throw ValidationError("Private isolation page did not close.")
                }
            }
            guard await privateA.close(), await privateB.close() else {
                throw ValidationError("Private isolation context did not close.")
            }
            try validationPage.load(configuration.phased(configuration.storageRead, "normal-survives"))
            try await wait(for: validationPage,
                           url: configuration.phased(configuration.storageRead, "normal-survives"),
                           title: configuration.presentTitle)
            checks["normalSurvivesPrivateClosure"] = true

            try await Task.sleep(for: .milliseconds(750))
            let reopenedPrivateA = try await runtime.openContext(
                profileKey: "harness-validation", privateWindowKey: "isolation-a")
            auxiliaryContexts.append(reopenedPrivateA)
            let reopenedPrivatePage = try reopenedPrivateA.makePage(
                url: configuration.phased(configuration.storageRead, "private-a-reopened"),
                hostWindowID: UUID())
            auxiliaryPages.append(reopenedPrivatePage)
            try await wait(for: reopenedPrivatePage,
                           url: configuration.phased(configuration.storageRead, "private-a-reopened"),
                           title: configuration.emptyTitle)
            checks["privateKeyReopensEmpty"] = true

            for auxiliaryPage in [reopenedPrivatePage, otherNormalPage] {
                auxiliaryPage.forceClose()
                guard await auxiliaryPage.waitUntilClosed() else {
                    throw ValidationError("Auxiliary isolation page did not close.")
                }
            }
            guard await reopenedPrivateA.close(), await otherNormal.close() else {
                throw ValidationError("Auxiliary isolation context did not close.")
            }

            let extensionStorageWrite = URL(string:
                "chrome-extension://\(installedID)/storage.html?mode=write&token=\(configuration.token)")!
            let extensionStoragePage = try openedContext.makePage(
                url: extensionStorageWrite, hostWindowID: UUID())
            auxiliaryPages.append(extensionStoragePage)
            try await wait(for: extensionStoragePage, url: extensionStorageWrite,
                           title: "Cobble extension storage written")
            extensionStoragePage.forceClose()
            guard await extensionStoragePage.waitUntilClosed() else {
                throw ValidationError("Extension storage seed page did not close.")
            }
            let websiteDataPrivate = try await runtime.openContext(
                profileKey: "harness-validation", privateWindowKey: "website-data")
            auxiliaryContexts.append(websiteDataPrivate)
            let websiteChecks = try await HarnessWebsiteDataValidation.run(
                context: openedContext,
                privateContext: websiteDataPrivate,
                page: validationPage,
                urls: configuration.websiteData,
                freshPage: { url in
                    let fresh = try openedContext.makePage(url: url, hostWindowID: UUID())
                    auxiliaryPages.append(fresh)
                    return fresh
                })
            checks.merge(websiteChecks) { _, new in new }
            guard websiteChecks.values.allSatisfy({ $0 }) else {
                throw ValidationError("ABI13 website-data category validation failed.")
            }
            guard await websiteDataPrivate.close() else {
                throw ValidationError("Website-data private context did not close.")
            }
            let extensionStorageRead = URL(string:
                "chrome-extension://\(installedID)/storage.html?mode=read&token=\(configuration.token)")!
            let extensionStorageReadPage = try openedContext.makePage(
                url: extensionStorageRead, hostWindowID: UUID())
            auxiliaryPages.append(extensionStorageReadPage)
            try await wait(for: extensionStorageReadPage, url: extensionStorageRead,
                           title: "Cobble extension storage present")
            checks["websiteDataRemovalPreservesExtensionStorage"] = true
            extensionStorageReadPage.forceClose()
            guard await extensionStorageReadPage.waitUntilClosed() else {
                throw ValidationError("Extension storage read page did not close.")
            }

            try await openedContext.removeWebsiteData(for: "127.0.0.1")
            try validationPage.load(configuration.phased(configuration.storageRead, "normal-cleared"))
            try await wait(for: validationPage,
                           url: configuration.phased(configuration.storageRead, "normal-cleared"),
                           title: configuration.emptyTitle)

            let sharedHost = UUID()
            let separateHost = UUID()
            let topologyBase = "chrome-extension://\(installedID)/topology.html?token=\(configuration.token)&slot="
            guard let topologyA = URL(string: topologyBase + "a"),
                  let topologyB = URL(string: topologyBase + "b"),
                  let topologyC = URL(string: topologyBase + "c"),
                  let activatedB = URL(string: topologyBase + "b&phase=activated"),
                  let survivingB = URL(string: topologyBase + "b&phase=after-close") else {
                throw ValidationError("Could not form extension topology URLs.")
            }
            let groupedA = try openedContext.makePage(url: topologyA, hostWindowID: sharedHost)
            let groupedB = try openedContext.makePage(url: topologyB, hostWindowID: sharedHost)
            let separate = try openedContext.makePage(url: topologyC, hostWindowID: separateHost)
            try await wait(for: groupedB, url: topologyB, title: "Cobble topology initial passed")
            checks["hostWindowGroupingMatchesExtensions"] = true
            try groupedB.move(toHostWindowID: separateHost)
            try await wait(for: groupedB, url: topologyB, title: "Cobble topology move-to-c passed")
            checks["hostWindowMoveMatchesExtensions"] = groupedB.hostWindowID == separateHost
            try groupedB.move(toHostWindowID: sharedHost)
            try await wait(for: groupedB, url: topologyB, title: "Cobble topology move-back passed")
            checks["hostWindowMoveRoundTripPreservesPageState"] = groupedB.hostWindowID == sharedHost
            var groupedAActivated = false
            groupedA.onActivate = { groupedAActivated = true }
            groupedA.focus()
            try await waitForCondition("native tab activation callback") { groupedAActivated }
            groupedA.onActivate = nil
            try groupedB.load(activatedB)
            try await wait(for: groupedB, url: activatedB, title: "Cobble topology activated passed")
            checks["nativeTabActivationReported"] = true
            groupedA.forceClose()
            guard await groupedA.waitUntilClosed() else {
                throw ValidationError("Grouped validation page did not close.")
            }
            try groupedB.load(survivingB)
            try await wait(for: groupedB, url: survivingB, title: "Cobble topology after-close passed")
            checks["groupSurvivesSiblingClose"] = true
            groupedB.forceClose()
            separate.forceClose()
            guard await groupedB.waitUntilClosed(), await separate.waitUntilClosed() else {
                throw ValidationError("Topology validation pages did not close.")
            }

            validationPage.forceClose()
            guard await validationPage.waitUntilClosed() else {
                throw ValidationError("Validation page did not close.")
            }
            checks["closedPageActionRejected"] = await rejectsClosedPageAction {
                try await runtime.performExtensionAction(installedID, on: validationPage, in: openedContext)
            }
            checks["closedSnapshotRejected"] = await rejectsClosedPageAction {
                _ = try await validationPage.snapshotPNG()
            }
            checks["closedPrintRejected"] = rejectsClosedPageAction {
                try validationPage.printPage()
            }
            checks["closedConnectionDetailsRejected"] = await rejectsClosedPageAction {
                _ = try await validationPage.connectionDetails()
            }
            guard checks["closedPageActionRejected"] == true else {
                throw ValidationError("Extension action accepted a closed page wrapper.")
            }

            // Let the last Browser finish destruction before reusing its
            // context. Chromium normally unloads profiles with no windows.
            try await Task.sleep(for: .milliseconds(750))
            let replacement = try openedContext.makePage(
                url: configuration.storageRead, hostWindowID: UUID())
            page = replacement
            try await wait(for: replacement, url: configuration.storageRead,
                           title: configuration.emptyTitle)
            checks["contextSurvivesLastPageClosed"] = true
            replacement.forceClose()
            guard await replacement.waitUntilClosed(), await openedContext.close() else {
                throw ValidationError("Replacement page or context did not close.")
            }
            page = nil
            context = nil
            try await Task.sleep(for: .milliseconds(750))
            let reopened = try await runtime.openContext(profileKey: "harness-validation")
            context = reopened
            let reopenedPage = try reopened.makePage(
                url: configuration.storageRead, hostWindowID: UUID())
            page = reopenedPage
            try await wait(for: reopenedPage, url: configuration.storageRead,
                           title: configuration.emptyTitle)
            checks["profileReopenedAfterContextClosed"] =
                try await runtime.installedExtensions(in: reopened).contains { $0.id == installedID }
            checks["activeProfileDeletionRejected"] = await rejectsOperation {
                try await runtime.scheduleProfileDeletion(key: "harness-validation")
            }
            try await runtime.removeExtension(installedID, from: reopened)
            extensionID = nil
            reopenedPage.forceClose()
            guard await reopenedPage.waitUntilClosed(), await reopened.close() else {
                throw ValidationError("Profile deletion validation page or context did not close.")
            }
            page = nil
            context = nil
            try await runtime.scheduleProfileDeletion(key: "harness-validation")
            let deletedProfile = configuration.profileDirectory(key: "harness-validation")
            checks["profilePhysicallyAbsentAtCallback"] = pathIsAbsent(deletedProfile)
            try await runtime.preflightProfileDeletion(key: "harness-validation")
            try await runtime.scheduleProfileDeletion(key: "harness-validation")
            checks["absentProfileDeletionIsIdempotent"] = pathIsAbsent(deletedProfile)

            stage("interrupted-download-release", configuration)
            let releaseProfileKey = "harness-download-release"
            let releaseContext = try await runtime.openContext(profileKey: releaseProfileKey)
            auxiliaryContexts.append(releaseContext)
            let releaseHost = reserveHost()
            let releasePage = try releaseContext.makePage(
                url: configuration.extensionTarget, hostWindowID: releaseHost)
            auxiliaryPages.append(releasePage)
            showPage(releasePage)
            try await waitForStableTitle(for: releasePage, url: configuration.extensionTarget,
                                         title: configuration.baselineTitle)
            try releasePage.load(configuration.interruptedReleaseDownload)
            let releaseMarker = configuration.downloadDirectory.appendingPathComponent(
                ".released-interrupted-\(configuration.interruptedReleaseDownload.lastPathComponent)")
            try await waitForCondition("interrupted download release") {
                (try? String(contentsOf: releaseMarker, encoding: .utf8)) == "true"
            }
            checks["interruptedDownloadReleaseRejectsStaleResume"] = true
            releasePage.forceClose()
            guard await releasePage.waitUntilClosed(), await releaseContext.close() else {
                throw ValidationError("Interrupted download release profile did not close.")
            }
            closeHost?(releaseHost)
            try await runtime.scheduleProfileDeletion(key: releaseProfileKey)
            checks["interruptedDownloadReleaseUnblocksProfileDeletion"] =
                pathIsAbsent(configuration.profileDirectory(key: releaseProfileKey))

            if !configuration.skipLocalFileValidation {
                stage("local-file", configuration)
                checks.merge(try await HarnessLocalFileValidation.run(
                    runtime: runtime, token: configuration.token, origin: configuration.origin,
                    baseline: configuration.origin.appendingPathComponent(
                        "fixture/\(configuration.token)/page-a"),
                    reserveHost: reserveHost, showPage: showPage, closeHost: closeHost)) { _, new in new }
            }

            stage("profile-filesystem-failure", configuration)
            let failingProfile = configuration.profileDirectory(key: "harness-delete-failure")
            try FileManager.default.createDirectory(at: failingProfile,
                                                    withIntermediateDirectories: true)
            let pinnedFile = failingProfile.appendingPathComponent("pinned")
            try Data("fixture".utf8).write(to: pinnedFile)
            try FileManager.default.setAttributes([.immutable: true],
                                                  ofItemAtPath: pinnedFile.path)
            defer {
                try? FileManager.default.setAttributes([.immutable: false],
                                                       ofItemAtPath: pinnedFile.path)
            }
            checks["profileFilesystemFailureReported"] = await rejectsOperation {
                try await runtime.scheduleProfileDeletion(key: "harness-delete-failure")
            }
            try FileManager.default.setAttributes([.immutable: false],
                                                  ofItemAtPath: pinnedFile.path)
            try await runtime.scheduleProfileDeletion(key: "harness-delete-failure")
            checks["profileFilesystemFailureRetryCompleted"] = pathIsAbsent(failingProfile)
            guard checks.values.allSatisfy({ $0 }) else {
                throw ValidationError("One or more native validation checks did not pass.")
            }

            await cleanup(runtime: runtime, context: context, page: page,
                          auxiliaryContexts: auxiliaryContexts, auxiliaryPages: auxiliaryPages,
                          extensionID: extensionID, extensionDirectory: extensionDirectory,
                          blockingExtensionID: blockingExtensionID, blockingDirectory: blockingDirectory)
            write(Report(status: "passed", checks: checks, error: nil), to: configuration.report)
        } catch {
            // Preserve the triggering failure even if native teardown crashes.
            write(Report(status: "failed", checks: checks, error: error.localizedDescription),
                  to: configuration.report)
            await cleanup(runtime: runtime, context: context, page: page,
                          auxiliaryContexts: auxiliaryContexts, auxiliaryPages: auxiliaryPages,
                          extensionID: extensionID, extensionDirectory: extensionDirectory,
                          blockingExtensionID: blockingExtensionID, blockingDirectory: blockingDirectory)
        }
    }

    private static func cleanup(runtime: ChromiumRuntime, context: ChromiumContext?, page: ChromiumPage?,
                                auxiliaryContexts: [ChromiumContext], auxiliaryPages: [ChromiumPage],
                                extensionID: String?, extensionDirectory: URL?,
                                blockingExtensionID: String?, blockingDirectory: URL?) async {
        if let blockingExtensionID, let context {
            try? await runtime.removeExtension(blockingExtensionID, from: context)
        }
        if let extensionID, let context {
            try? await runtime.removeExtension(extensionID, from: context)
        }
        runtime.onMediaPermissionRequest = nil
        if let page, !page.isClosed {
            page.forceClose()
            _ = await page.waitUntilClosed()
        }
        for auxiliaryPage in auxiliaryPages where !auxiliaryPage.isClosed {
            auxiliaryPage.forceClose()
            _ = await auxiliaryPage.waitUntilClosed()
        }
        for auxiliaryContext in auxiliaryContexts where !auxiliaryContext.isClosed {
            _ = await auxiliaryContext.close()
        }
        if let context, !context.isClosed {
            _ = await context.close()
        }
        if let extensionDirectory {
            try? FileManager.default.removeItem(at: extensionDirectory)
        }
        if let blockingDirectory {
            try? FileManager.default.removeItem(at: blockingDirectory)
        }
    }

    private static func makeExtensionDirectory(token: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: directory.path)
            let manifest: [String: Any] = [
                "manifest_version": 3,
                "name": "Cobble Native Validation \(token)",
                "version": "1.0",
                "host_permissions": ["http://127.0.0.1/*"],
                "permissions": ["tabs"],
                "content_scripts": [[
                    "matches": ["http://127.0.0.1/*"],
                    "js": ["content.js"],
                    "run_at": "document_idle",
                ]],
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                            options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            // `token` was accepted only as a UUID while parsing the loopback
            // fixture URL, so it is safe to embed in this generated JavaScript.
            let script = "document.title = \"Cobble Extension Active \(token)\";\n"
            try Data(script.utf8).write(to: directory.appendingPathComponent("content.js"), options: .atomic)
            let topologyHTML = "<title>Cobble topology pending</title><script src=\"topology.js\"></script>\n"
            try Data(topologyHTML.utf8).write(
                to: directory.appendingPathComponent("topology.html"), options: .atomic)
            try Data("<title>Cobble extension storage pending</title><script src=\"storage.js\"></script>\n".utf8)
                .write(to: directory.appendingPathComponent("storage.html"), options: .atomic)
            let storageScript = """
            const parameters = new URL(location.href).searchParams;
            const key = "cobble-website-data-survival";
            if (parameters.get("mode") === "write") {
              localStorage.setItem(key, parameters.get("token"));
              document.title = "Cobble extension storage written";
            } else {
              document.title = localStorage.getItem(key) === parameters.get("token")
                ? "Cobble extension storage present" : "Cobble extension storage missing";
            }
            """
            try Data(storageScript.utf8).write(
                to: directory.appendingPathComponent("storage.js"), options: .atomic)
            let topologyScript = """
            const own = new URL(location.href);
            const token = own.searchParams.get("token");
            const phase = own.searchParams.get("phase") || "initial";
            let movePhase = "initial";
            const check = async () => {
              const windows = await chrome.windows.getAll({populate: true});
              const tabs = windows.flatMap(window => window.tabs || []);
              const slots = new Map();
              let matchedTabs = 0;
              for (const tab of tabs) {
                if (!tab.url) continue;
                const url = new URL(tab.url);
                if (url.pathname !== "/topology.html" || url.searchParams.get("token") !== token) continue;
                matchedTabs++;
                slots.set(url.searchParams.get("slot"), tab);
              }
              const topologyWindows = new Set([...slots.values()].map(tab => tab.windowId));
              const a = slots.get("a"), b = slots.get("b"), c = slots.get("c");
              if (phase === "initial" && own.searchParams.get("slot") === "b") {
                const initial = matchedTabs === 3 && slots.size === 3 && a && b && c &&
                  a.windowId === b.windowId && b.windowId !== c.windowId && b.active && c.active;
                const movedToC = matchedTabs === 3 && slots.size === 3 && a && b && c &&
                  a.windowId !== b.windowId && b.windowId === c.windowId && a.active && b.active && !c.active;
                if (movePhase === "initial" && initial) {
                  movePhase = "moved-to-c";
                  document.title = "Cobble topology initial passed";
                } else if (movePhase === "moved-to-c" && movedToC) {
                  movePhase = "moved-back";
                  document.title = "Cobble topology move-to-c passed";
                } else if (movePhase === "moved-back" && initial) {
                  document.title = "Cobble topology move-back passed";
                  return;
                } else {
                  document.title = `Cobble topology move pending a=${a?.id}@${a?.windowId} b=${b?.id}@${b?.windowId} c=${c?.id}@${c?.windowId}`;
                }
                setTimeout(check, 50);
                return;
              }
              const topology = phase === "after-close"
                ? matchedTabs === 2 && slots.size === 2 && !a && b && c && b.active && c.active
                : matchedTabs === 3 && slots.size === 3 && a && b && c &&
                  a.windowId === b.windowId && c.active &&
                  (phase === "activated" ? a.active && !b.active : !a.active && b.active);
              if (topology && topologyWindows.size === 2 && b.windowId !== c.windowId) {
                document.title = `Cobble topology ${phase} passed`;
              } else {
                setTimeout(check, 50);
              }
            };
            check();
            """
            try Data(topologyScript.utf8).write(
                to: directory.appendingPathComponent("topology.js"), options: .atomic)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func makeBlockingDirectory(json: String, exceptions: [String]) throws -> URL {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true)
        do {
            try replaceBlockingFiles(in: directory, json: json, exceptions: exceptions)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func replaceBlockingFiles(in directory: URL, json: String,
                                             exceptions: [String]) throws {
        for (name, data) in try ChromiumBlockingRules.files(json: json, exceptions: exceptions) {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    private static func wait(for page: ChromiumPage, url: URL, title: String,
                             timeout: Duration = .seconds(12)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if page.isClosed { throw ValidationError("Validation page closed unexpectedly.") }
            if page.urlString == url.absoluteString, !page.isLoading, page.title == title { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ValidationError("Timed out waiting for \(url.path) with title \"\(title)\"; got \"\(page.title)\".")
    }

    private static func waitForCondition(
        _ description: String, condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ValidationError("Timed out waiting for \(description).")
    }

    private static func activateExternalProtocol(
        on page: ChromiumPage, sequence: Int, frame: Bool = false,
        configuration: Configuration
    ) async throws {
        try JSONSerialization.data(withJSONObject: [
            "url": page.urlString,
            "sequence": sequence,
            "frame": frame,
        ]).write(to: configuration.externalProtocolMarker, options: .atomic)
        try await waitForCondition("trusted external protocol action \(sequence)") {
            (try? String(contentsOf: configuration.externalProtocolActivated,
                         encoding: .utf8)) == "\(sequence)\n"
        }
    }

    private static func moveIsRejectedWhilePending(_ page: ChromiumPage) -> Bool {
        let original = page.hostWindowID
        do { try page.move(toHostWindowID: UUID()); return false }
        catch { return page.hostWindowID == original }
    }

    private static func devToolsOpenIsRejected(_ page: ChromiumPage,
                                                hostWindowID: UUID) -> Bool {
        do {
            let session = try page.openDevTools(hostWindowID: hostWindowID)
            session.close()
            return false
        } catch {
            return true
        }
    }

    private static func devToolsOpenIsRejectedWithTemporaryHost(
        _ page: ChromiumPage,
        reserveHost: (() -> UUID)?,
        closeHost: ((UUID) -> Void)?
    ) -> Bool {
        guard let reserveHost else { return false }
        let hostID = reserveHost()
        defer { closeHost?(hostID) }
        return devToolsOpenIsRejected(page, hostWindowID: hostID)
    }

    private static func moveRoundTrips(_ page: ChromiumPage) async throws -> Bool {
        let original = page.hostWindowID
        let before = try await page.currentDOM()
        try page.move(toHostWindowID: UUID())
        try page.move(toHostWindowID: original)
        let after = try await page.currentDOM()
        return page.hostWindowID == original && after == before
    }

    private static func rejectsProfileKey(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch ChromiumError.operationFailed(let message) {
            return message == "Chromium profile keys cannot contain NUL bytes."
        } catch {
            return false
        }
    }

    private static func rejectsOperation(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch ChromiumError.operationFailed {
            return true
        } catch {
            return false
        }
    }

    private static func pathIsAbsent(_ url: URL) -> Bool {
        var status = stat()
        errno = 0
        return url.path.withCString { lstat($0, &status) } != 0 && errno == ENOENT
    }

    private static func rejectsExtensionIdentifier(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch ChromiumExtensionError.operationFailed(let message) {
            return message == "An extension identifier cannot contain a null character."
        } catch {
            return false
        }
    }

    private static func rejectsClosedPageAction(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch ChromiumError.closed {
            return true
        } catch {
            return false
        }
    }

    private static func rejectsClosedPageAction(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return false
        } catch ChromiumError.closed {
            return true
        } catch {
            return false
        }
    }

    private static func rejectsPageData<T>(_ task: Task<T, Error>) async -> Bool {
        do {
            _ = try await task.value
            return false
        } catch {
            return true
        }
    }

    private static func pngSize(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24,
              data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
              data[12..<16].elementsEqual(Data("IHDR".utf8)) else {
            throw ValidationError("Native viewport capture was not a PNG with an IHDR header.")
        }
        let value = { (offset: Int) in
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let size = (width: value(16), height: value(20))
        guard size.width > 0, size.height > 0 else {
            throw ValidationError("Native viewport capture had empty pixel bounds.")
        }
        return size
    }

    private static func pngSizeIsWithinNativeBounds(_ size: (width: Int, height: Int)) -> Bool {
        size.width <= 16_384 && size.height <= 16_384 &&
            size.width * size.height <= 64 * 1_024 * 1_024
    }

    /// A withheld or revoked document must remain unmodified long enough for
    /// the extension's `document_idle` script to run if it were still allowed.
    private static func waitForStableTitle(for page: ChromiumPage, url: URL, title: String) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        var stableSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if page.isClosed { throw ValidationError("Validation page closed unexpectedly.") }
            if page.urlString == url.absoluteString, !page.isLoading, page.title == title {
                if stableSince == nil { stableSince = .now }
                if let stableSince, ContinuousClock.now - stableSince >= .milliseconds(750) { return }
            } else {
                stableSince = nil
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ValidationError("Timed out waiting for stable title \"\(title)\"; got \"\(page.title)\".")
    }

    private static func write(_ report: Report, to url: URL) {
        do {
            let data = try JSONEncoder().encode(report)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "Could not write native validation report: \(error.localizedDescription)\n".utf8))
        }
    }

    private static func stage(_ value: String, _ configuration: Configuration) {
        try? Data("\(value)\n".utf8).write(to: configuration.stage, options: .atomic)
    }

    private static func attribute(named name: String, in html: String) -> String? {
        let prefix = "data-\(name)=\""
        guard let start = html.range(of: prefix)?.upperBound,
              let end = html[start...].firstIndex(of: "\"") else { return nil }
        return String(html[start..<end])
    }
}

private extension HarnessValidation {
    struct Configuration {
        let report: URL
        let origin: URL
        let undeclaredOrigin: URL
        let extensionTarget: URL
        let storageWrite: URL
        let storageRead: URL
        let websiteData: HarnessWebsiteDataValidation.URLs
        let delayedTitle: URL
        let streamedHistoryTitle: URL
        let securePage: URL
        let mixedPage: URL
        let invalidSecurePage: URL
        let mediaPage: URL
        let clientCertificateSelect: URL
        let clientCertificateCancel: URL
        let clientCertificateUnhandled: URL
        let clientCertificateStale: URL
        let clientCertificateClose: URL
        let clientCertificateReentrant: URL
        let clientCertificateDocumentPage: URL
        let clientCertificateDocumentResource: URL
        let clientCertificateSubject: String
        let clientCertificateIssuer: String
        let clientCertificateSerial: String
        let interruptedReleaseDownload: URL
        let userDataDirectory: URL
        let downloadDirectory: URL
        let promptCrashMarker: URL
        let beforeUnloadMarker: URL
        let beforeUnloadActivated: URL
        let repostBeforeUnloadMarker: URL
        let repostBeforeUnloadActivated: URL
        let fileChooserMarker: URL
        let exclusiveAccessMarker: URL
        let exclusiveAccessOutcome: URL
        let postReloadMarker: URL
        let postReloadActivated: URL
        let externalProtocolMarker: URL
        let externalProtocolActivated: URL
        let devToolsMarker: URL
        let devToolsAction: URL
        let stage: URL
        let skipDevToolsFrontendProbe: Bool
        let skipLocalFileValidation: Bool
        let skipRepostValidation: Bool
        let token: String

        var baselineTitle: String { "Cobble Extension Baseline \(token)" }
        var activeTitle: String { "Cobble Extension Active \(token)" }
        var writtenTitle: String { "Cobble Validation Written \(token)" }
        var presentTitle: String { "Cobble Validation Present \(token)" }
        var emptyTitle: String { "Cobble Validation Empty \(token)" }
        var delayedTitleValue: String { "Cobble Validation Settled \(token)" }
        var interimTitleValue: String { "Cobble Validation Interim \(token)" }
        var secureTitle: String { "Cobble TLS Secure \(token)" }
        var mixedTitle: String { "Cobble TLS Mixed \(token)" }
        var mediaGrantedTitle: String { "Cobble Media Granted \(token)" }
        var mediaDeniedTitle: String { "Cobble Media Denied \(token)" }
        var javascriptDeniedTitle: String { "Cobble JS Result false \(token)" }
        var javascriptAcceptedTitle: String { "Cobble JS Result \(token) \(token)" }
        var authGrantedTitle: String { "Cobble Auth Granted \(token)" }
        var authSubresourceGrantedTitle: String { "Cobble Auth Subresource Granted \(token)" }
        var fileSelectedTitle: String { "Cobble File Selected chooser-\(token).txt \(token)" }
        var filePendingTitle: String { "Cobble File Pending \(token)" }
        var folderPendingTitle: String { "Cobble Folder Pending \(token)" }
        var folderSelectedTitle: String {
            "Cobble Folder Selected 2 chooser-folder-\(token)/a.txt," +
                "chooser-folder-\(token)/nested/b.txt \(token)"
        }
        var exclusiveReadyTitle: String { "Cobble Exclusive Ready \(token)" }
        var exclusiveDeniedTitle: String { "Cobble Exclusive Denied \(token)" }
        var fileFrameTitle: String { "Cobble File Frame \(token)" }
        func externalProtocolTitle(_ value: String) -> String {
            "Cobble External Ready \(value) \(token)"
        }
        var beforeUnloadReadyTitle: String { "Cobble BeforeUnload Ready \(token)" }
        var blockedTitle: String { "Cobble Blocking Blocked \(token)" }
        var allowedTitle: String { "Cobble Blocking Allowed \(token)" }
        var secureOriginString: String {
            var components = URLComponents(url: securePage, resolvingAgainstBaseURL: false)!
            components.path = ""
            return components.string!
        }
        var blockingPage: URL {
            securePage.deletingLastPathComponent().appendingPathComponent("blocking")
        }
        var secureRecoveryPage: URL {
            var components = URLComponents(
                url: securePage.deletingLastPathComponent()
                    .appendingPathComponent("secure-recovery"),
                resolvingAgainstBaseURL: false)!
            components.host = "cobble-recovery.test"
            return components.url!
        }
        var sameHostAfterMixedPage: URL {
            securePage.deletingLastPathComponent().appendingPathComponent("secure-after-mixed")
        }
        var javascriptConfirm: URL {
            phased(fixtureDirectory.appendingPathComponent("js-dialog"), "confirm", name: "mode")
        }
        var javascriptPrompt: URL {
            phased(fixtureDirectory.appendingPathComponent("js-dialog"), "prompt", name: "mode")
        }
        var httpAuth: URL {
            var components = URLComponents(
                url: fixtureDirectory.appendingPathComponent("http-auth").absoluteURL,
                resolvingAgainstBaseURL: false)!
            components.host = "cobble-auth.test"
            return components.url!
        }
        var httpAuthDirect: URL {
            var components = URLComponents(url: httpAuth, resolvingAgainstBaseURL: false)!
            components.host = "cobble-auth-direct.test"
            return components.url!
        }
        var httpAuthCancellation: URL {
            var components = URLComponents(url: httpAuth, resolvingAgainstBaseURL: false)!
            components.host = "cobble-auth-cancel.test"
            return components.url!
        }
        var httpAuthSubresourcePage: URL {
            fixtureDirectory.appendingPathComponent("auth-subresource")
        }
        var fileChooser: URL { fixtureDirectory.appendingPathComponent("file-chooser") }
        var fileFolder: URL { fixtureDirectory.appendingPathComponent("file-folder") }
        var exclusiveAccess: URL { fixtureDirectory.appendingPathComponent("exclusive-access") }
        var fileFrameParent: URL { fixtureDirectory.appendingPathComponent("file-frame-parent") }
        func externalProtocol(_ value: String) -> URL {
            phased(fixtureDirectory.appendingPathComponent("external-protocol"), value, name: "case")
        }
        var crashFileChooser: URL {
            var components = URLComponents(url: fileChooser.absoluteURL, resolvingAgainstBaseURL: false)!
            components.host = "cobble-crash.test"
            return components.url!
        }
        var beforeUnloadPage: URL { fixtureDirectory.appendingPathComponent("beforeunload") }
        var beforeUnloadTarget: URL {
            var components = URLComponents(url: domPage.absoluteURL, resolvingAgainstBaseURL: false)!
            components.host = "cobble-beforeunload.test"
            return components.url!
        }
        func profileDirectory(key: String) -> URL {
            userDataDirectory.appendingPathComponent("Cobble-\(key)", isDirectory: true)
        }
        var fixtureDirectory: URL { extensionTarget.deletingLastPathComponent() }
        var domPage: URL { fixtureDirectory.appendingPathComponent("dom") }
        var reloadGET: URL { fixtureDirectory.appendingPathComponent("reload-get") }
        var reloadPOSTStart: URL { fixtureDirectory.appendingPathComponent("reload-post-start") }
        var reloadPOSTTarget: URL { fixtureDirectory.appendingPathComponent("reload-post") }
        var domTitle: String { "Cobble DOM Mutated \(token)" }
        func reloadGETTitle(_ count: Int) -> String { "Cobble Reload GET \(count) \(token)" }
        func reloadPOSTTitle(_ count: Int) -> String { "Cobble Reload POST \(count) \(token)" }
        var streamedHistoryDuring: URL { phased(streamedHistoryTitle, "during") }
        var streamedHistoryAfter: URL {
            var components = URLComponents(url: phased(streamedHistoryTitle, "after"),
                                           resolvingAgainstBaseURL: true)!
            components.fragment = "settled"
            return components.url!
        }

        func phased(_ url: URL, _ phase: String) -> URL {
            phased(url, phase, name: "phase")
        }

        func phased(_ url: URL, _ phase: String, name: String) -> URL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
            components.queryItems = [URLQueryItem(name: name, value: phase)]
            return components.url!
        }

        static func load(report: URL) -> Self? {
            let environment = ProcessInfo.processInfo.environment
            guard let fixtureString = environment["COBBLE_CHROMIUM_HARNESS_URL"],
                  let fixture = URL(string: fixtureString),
                  fixture.scheme == "http", fixture.host?.lowercased() == "127.0.0.1",
                  fixture.port != nil, fixture.query == nil, fixture.fragment == nil
            else { return nil }
            let components = fixture.path.split(separator: "/").map(String.init)
            guard components.count == 3, components[0] == "fixture", components[2] == "page-a",
                  UUID(uuidString: components[1]) != nil,
                  let origin = URL(string: "http://127.0.0.1:\(fixture.port!)"),
                  let undeclaredOrigin = URL(string: "http://localhost:\(fixture.port!)/"),
                  let prefix = URL(string: "/fixture/\(components[1])/", relativeTo: origin),
                  let extensionTarget = URL(string: "extension-target", relativeTo: prefix),
                  let storageWrite = URL(string: "validation-write", relativeTo: prefix),
                  let storageRead = URL(string: "validation-read", relativeTo: prefix),
                  let websiteData = HarnessWebsiteDataValidation.URLs.load(from: environment),
                  let delayedTitle = URL(string: "delayed-title", relativeTo: prefix),
                  let streamedHistoryTitle = URL(string: "streamed-history-title", relativeTo: prefix),
                  let securePage = validationURL(environment["COBBLE_CHROMIUM_VALIDATION_SECURE_URL"],
                                                 token: components[1]),
                  let mixedPage = validationURL(environment["COBBLE_CHROMIUM_VALIDATION_MIXED_URL"],
                                                token: components[1]),
                  let invalidSecurePage = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_INVALID_TLS_URL"], token: components[1]),
                  let mediaPage = validationURL(environment["COBBLE_CHROMIUM_VALIDATION_MEDIA_URL"],
                                                token: components[1]),
                  let clientCertificateSelect = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_SELECT_URL"],
                    token: components[1]),
                  let clientCertificateCancel = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_CANCEL_URL"],
                    token: components[1]),
                  let clientCertificateUnhandled = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_UNHANDLED_URL"],
                    token: components[1]),
                  let clientCertificateStale = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_STALE_URL"],
                    token: components[1]),
                  let clientCertificateClose = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_CLOSE_URL"],
                    token: components[1]),
                  let clientCertificateReentrant = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_REENTRANT_URL"],
                    token: components[1]),
                  let clientCertificateDocumentPage = URL(
                    string: environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_DOCUMENT_PAGE"] ?? ""),
                  clientCertificateDocumentPage.scheme == "http",
                  clientCertificateDocumentPage.host == "127.0.0.1",
                  clientCertificateDocumentPage.port == fixture.port,
                  clientCertificateDocumentPage.path ==
                    "/fixture/\(components[1])/client-certificate-document",
                  let clientCertificateDocumentResource = validationURL(
                    environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_DOCUMENT_RESOURCE"],
                    token: components[1]),
                  let clientCertificateSubject =
                    boundedMetadata(environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_SUBJECT"]),
                  let clientCertificateIssuer =
                    boundedMetadata(environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_ISSUER"]),
                  let clientCertificateSerial =
                    boundedMetadata(environment["COBBLE_CHROMIUM_VALIDATION_CLIENT_CERT_SERIAL"]),
                  let interruptedReleaseString =
                    environment["COBBLE_CHROMIUM_VALIDATION_INTERRUPTED_RELEASE_URL"],
                  let interruptedReleaseDownload = URL(string: interruptedReleaseString),
                  interruptedReleaseDownload.scheme == "http",
                  interruptedReleaseDownload.host == "127.0.0.1",
                  interruptedReleaseDownload.port != nil,
                  interruptedReleaseDownload.path.hasPrefix(
                    "/fixture/\(components[1])/download/interrupt-release-"),
                  let userDataPath = environment["COBBLE_CHROMIUM_VALIDATION_USER_DATA_DIR"],
                  userDataPath.hasPrefix("/"), !userDataPath.utf8.contains(0),
                  let downloadPath = environment["COBBLE_CHROMIUM_VALIDATION_DOWNLOAD_DIRECTORY"],
                  downloadPath.hasPrefix("/"), !downloadPath.utf8.contains(0),
                  let crashMarkerPath = environment["COBBLE_CHROMIUM_PROMPT_CRASH_MARKER"],
                  crashMarkerPath.hasPrefix("/"), !crashMarkerPath.utf8.contains(0),
                  let beforeUnloadMarkerPath = environment["COBBLE_CHROMIUM_BEFOREUNLOAD_MARKER"],
                  beforeUnloadMarkerPath.hasPrefix("/"), !beforeUnloadMarkerPath.utf8.contains(0),
                  let beforeUnloadActivatedPath = environment["COBBLE_CHROMIUM_BEFOREUNLOAD_ACTIVATED"],
                  beforeUnloadActivatedPath.hasPrefix("/"), !beforeUnloadActivatedPath.utf8.contains(0),
                  let repostBeforeUnloadMarkerPath =
                    environment["COBBLE_CHROMIUM_REPOST_BEFOREUNLOAD_MARKER"],
                  repostBeforeUnloadMarkerPath.hasPrefix("/"),
                  !repostBeforeUnloadMarkerPath.utf8.contains(0),
                  let repostBeforeUnloadActivatedPath =
                    environment["COBBLE_CHROMIUM_REPOST_BEFOREUNLOAD_ACTIVATED"],
                  repostBeforeUnloadActivatedPath.hasPrefix("/"),
                  !repostBeforeUnloadActivatedPath.utf8.contains(0),
                  let fileChooserMarkerPath = environment["COBBLE_CHROMIUM_FILE_CHOOSER_MARKER"],
                  fileChooserMarkerPath.hasPrefix("/"), !fileChooserMarkerPath.utf8.contains(0),
                  let exclusiveAccessMarkerPath = environment["COBBLE_CHROMIUM_EXCLUSIVE_ACCESS_MARKER"],
                  exclusiveAccessMarkerPath.hasPrefix("/"),
                  !exclusiveAccessMarkerPath.utf8.contains(0),
                  let exclusiveAccessOutcomePath = environment["COBBLE_CHROMIUM_EXCLUSIVE_ACCESS_OUTCOME"],
                  exclusiveAccessOutcomePath.hasPrefix("/"),
                  !exclusiveAccessOutcomePath.utf8.contains(0),
                  let postReloadMarkerPath = environment["COBBLE_CHROMIUM_POST_RELOAD_MARKER"],
                  postReloadMarkerPath.hasPrefix("/"), !postReloadMarkerPath.utf8.contains(0),
                  let postReloadActivatedPath = environment["COBBLE_CHROMIUM_POST_RELOAD_ACTIVATED"],
                  postReloadActivatedPath.hasPrefix("/"),
                  !postReloadActivatedPath.utf8.contains(0),
                  let externalProtocolMarkerPath = environment["COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_MARKER"],
                  externalProtocolMarkerPath.hasPrefix("/"), !externalProtocolMarkerPath.utf8.contains(0),
                  let externalProtocolActivatedPath = environment["COBBLE_CHROMIUM_EXTERNAL_PROTOCOL_ACTIVATED"],
                  externalProtocolActivatedPath.hasPrefix("/"), !externalProtocolActivatedPath.utf8.contains(0),
                  let devToolsMarkerPath = environment["COBBLE_CHROMIUM_DEVTOOLS_MARKER"],
                  devToolsMarkerPath.hasPrefix("/"), !devToolsMarkerPath.utf8.contains(0),
                  let devToolsActionPath = environment["COBBLE_CHROMIUM_DEVTOOLS_ACTION"],
                  devToolsActionPath.hasPrefix("/"), !devToolsActionPath.utf8.contains(0),
                  let stagePath = environment["COBBLE_CHROMIUM_VALIDATION_STAGE"],
                  stagePath.hasPrefix("/"), !stagePath.utf8.contains(0)
            else { return nil }
            return Self(report: report, origin: origin,
                        undeclaredOrigin: undeclaredOrigin, extensionTarget: extensionTarget,
                        storageWrite: storageWrite, storageRead: storageRead,
                        websiteData: websiteData,
                        delayedTitle: delayedTitle, streamedHistoryTitle: streamedHistoryTitle,
                        securePage: securePage, mixedPage: mixedPage,
                        invalidSecurePage: invalidSecurePage,
                        mediaPage: mediaPage,
                        clientCertificateSelect: clientCertificateSelect,
                        clientCertificateCancel: clientCertificateCancel,
                        clientCertificateUnhandled: clientCertificateUnhandled,
                        clientCertificateStale: clientCertificateStale,
                        clientCertificateClose: clientCertificateClose,
                        clientCertificateReentrant: clientCertificateReentrant,
                        clientCertificateDocumentPage: clientCertificateDocumentPage,
                        clientCertificateDocumentResource: clientCertificateDocumentResource,
                        clientCertificateSubject: clientCertificateSubject,
                        clientCertificateIssuer: clientCertificateIssuer,
                        clientCertificateSerial: clientCertificateSerial,
                        interruptedReleaseDownload: interruptedReleaseDownload,
                        userDataDirectory: URL(fileURLWithPath: userDataPath, isDirectory: true),
                        downloadDirectory: URL(fileURLWithPath: downloadPath, isDirectory: true),
                        promptCrashMarker: URL(fileURLWithPath: crashMarkerPath),
                        beforeUnloadMarker: URL(fileURLWithPath: beforeUnloadMarkerPath),
                        beforeUnloadActivated: URL(fileURLWithPath: beforeUnloadActivatedPath),
                        repostBeforeUnloadMarker:
                            URL(fileURLWithPath: repostBeforeUnloadMarkerPath),
                        repostBeforeUnloadActivated:
                            URL(fileURLWithPath: repostBeforeUnloadActivatedPath),
                        fileChooserMarker: URL(fileURLWithPath: fileChooserMarkerPath),
                        exclusiveAccessMarker: URL(fileURLWithPath: exclusiveAccessMarkerPath),
                        exclusiveAccessOutcome: URL(fileURLWithPath: exclusiveAccessOutcomePath),
                        postReloadMarker: URL(fileURLWithPath: postReloadMarkerPath),
                        postReloadActivated: URL(fileURLWithPath: postReloadActivatedPath),
                        externalProtocolMarker: URL(fileURLWithPath: externalProtocolMarkerPath),
                        externalProtocolActivated: URL(fileURLWithPath: externalProtocolActivatedPath),
                        devToolsMarker: URL(fileURLWithPath: devToolsMarkerPath),
                        devToolsAction: URL(fileURLWithPath: devToolsActionPath),
                        stage: URL(fileURLWithPath: stagePath),
                        skipDevToolsFrontendProbe:
                            environment["COBBLE_CHROMIUM_SKIP_DEVTOOLS_FRONTEND_PROBE"] == "1",
                        skipLocalFileValidation:
                            environment["COBBLE_CHROMIUM_SKIP_LOCAL_FILE_VALIDATION"] == "1",
                        skipRepostValidation:
                            environment["COBBLE_CHROMIUM_SKIP_REPOST_VALIDATION"] == "1",
                        token: components[1])
        }

        private static func validationURL(_ value: String?, token: String) -> URL? {
            guard let value, let url = URL(string: value), url.scheme == "https",
                  url.host?.lowercased() == "127.0.0.1", url.port != nil,
                  url.path.hasPrefix("/fixture/\(token)/"), url.query == nil, url.fragment == nil
            else { return nil }
            return url
        }

        private static func boundedMetadata(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 1_024,
                  !value.utf8.contains(0) else { return nil }
            return value
        }
    }

    struct Report: Encodable {
        let status: String
        let checks: [String: Bool]
        let error: String?
    }

    struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
