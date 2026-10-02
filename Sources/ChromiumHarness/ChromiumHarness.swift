import AppKit
import CobbleChromium
import WebKit

@_cdecl("CCSClientMain")
public func CCSClientMain(_ launcherFrameworkHandle: UnsafeMutableRawPointer?) -> Int32 {
    let handleBits = launcherFrameworkHandle.map { UInt(bitPattern: $0) } ?? 0
    let configuredURL = ProcessInfo.processInfo.environment["COBBLE_CHROMIUM_HARNESS_URL"]
    let initialURL = configuredURL.flatMap(URL.init(string:)) ?? URL(string: "https://example.com")!
    if configuredURL != nil || initialURL.scheme == "http" {
        guard initialURL.scheme == "http",
              ["localhost", "127.0.0.1", "::1"].contains(initialURL.host?.lowercased() ?? "")
        else { return -1 }
    }
    return MainActor.assumeIsolated {
        guard HarnessLifetime.harness == nil else { return -1 }
        do {
            let handle = handleBits == 0 ? nil : UnsafeMutableRawPointer(bitPattern: handleBits)
            let runtime = try ChromiumRuntime(launcherFrameworkHandle: handle)
            let harness = ChromiumHarness(runtime: runtime, initialURL: initialURL)
            HarnessLifetime.harness = harness
            try runtime.registerClient()
            return 0
        } catch {
            HarnessLifetime.harness = nil
            return -1
        }
    }
}

@MainActor private enum HarnessLifetime {
    static var harness: ChromiumHarness?
}

@MainActor private final class ChromiumHarness {
    private let runtime: ChromiumRuntime
    private let initialURL: URL
    private var windows: [ObjectIdentifier: HarnessWindowController] = [:]
    private var hostWindows: [UUID: NSWindow] = [:]
    private var popupEvents: [[String: Any]] = []
    private var popupHosts: Set<UUID> = []
    private var approvedPopupCount = 0
    private var downloads: [ObjectIdentifier: HarnessDownload] = [:]
    private weak var metadataPage: ChromiumPage?
    private var closePageOnHostLookup: [UUID: ChromiumPage] = [:]
    private var starting = false

    init(runtime: ChromiumRuntime, initialURL: URL) {
        self.runtime = runtime
        self.initialURL = initialURL
        runtime.onReady = { [weak self] in self?.start() }
        runtime.onWillStop = { [weak self] in self?.stop() }
        runtime.popupPolicy = { [weak self] request in self?.approvePopup(request) ?? false }
        runtime.onPopupWithDisposition = { [weak self] opener, page, disposition in
            guard let self, let opener else { page.forceClose(); return }
            showInNewWindow(page, opener: opener, disposition: disposition)
        }
        runtime.onDownload = { [weak self] page, download in
            self?.receive(download, from: page)
        }
        runtime.hostWindow = { [weak self] hostID, _ in
            if let page = self?.closePageOnHostLookup.removeValue(forKey: hostID) {
                page.forceClose()
            }
            return self?.hostWindows[hostID]
        }
        runtime.onReopen = { [weak self] in
            guard let self else { return }
            if let window = hostWindow(for: nil) { window.makeKeyAndOrderFront(nil) }
            else { start() }
        }
        runtime.onOpenURLs = { [weak self] urls in
            guard let self else { return }
            for url in urls where url.scheme == "http" || url.scheme == "https" {
                Task {
                    do { try await self.createPageAndShow(url: url) }
                    catch { NSAlert(error: error).runModal() }
                }
            }
        }
    }

    private func start() {
        guard windows.isEmpty, !starting else { return }
        let environment = ProcessInfo.processInfo.environment
        if environment["COBBLE_CHROMIUM_COOKIE_TRANSFER_REPORT"] != nil ||
           environment["COBBLE_CHROMIUM_EXTERNAL_SHUTDOWN_REPORT"] != nil ||
           environment["COBBLE_CHROMIUM_DEVTOOLS_SHUTDOWN_REPORT"] != nil {
            startValidation()
            return
        }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            defer { starting = false }
            do {
                try await createPageAndShow(url: initialURL)
            } catch {
                if runtime.isReady { NSAlert(error: error).runModal() }
            }
        }
        startValidation()
    }

    private func startValidation() {
        HarnessValidation.startIfConfigured(
            runtime: runtime,
            reserveHost: { [weak self] in self?.reserveValidationHost() ?? UUID() },
            showPage: { [weak self] in self?.showValidationPage($0) },
            showDevTools: { [weak self] session, hostID in
                self?.showDevTools(session, hostID: hostID) ?? false
            },
            closeHost: { [weak self] hostID in self?.closeValidationHost(hostID) },
            reserveReentrantHost: { [weak self] page in
                self?.reserveReentrantValidationHost(for: page) ?? UUID()
            })
    }

    private func createPageAndShow(url: URL) async throws {
        let hostID = UUID()
        let window = Self.makeWindow()
        hostWindows[hostID] = window
        do {
            let page = try await runtime.makePage(
                url: url, profileKey: "harness", hostWindowID: hostID)
            guard runtime.isReady else {
                hostWindows.removeValue(forKey: hostID)
                page.forceClose()
                return
            }
            if metadataPage == nil { metadataPage = page }
            show(page, in: window)
        } catch {
            hostWindows.removeValue(forKey: hostID)
            throw error
        }
    }

    private func showInNewWindow(_ page: ChromiumPage, opener: ChromiumPage,
                                 disposition: ChromiumPopupRequest.Disposition) {
        let policyApproved = approvedPopupCount > 0
        if policyApproved { approvedPopupCount -= 1 }
        let hostID = UUID()
        let window = Self.makeWindow()
        hostWindows[hostID] = window
        do {
            try page.move(toHostWindowID: hostID)
            show(page, in: window)
            popupHosts.insert(hostID)
            recordPopupEvent([
                "event": "opened", "hostID": hostID.uuidString,
                "disposition": disposition.rawValue,
                "openerHostID": opener.hostWindowID.uuidString,
                "nativeViewAttached": page.nativeView.window === window,
                "separateNativeWindow": hostWindows[opener.hostWindowID].map { $0 !== window } ?? false,
                "visible": window.isVisible,
                "policyBeforeCreation": policyApproved,
            ])
        } catch {
            hostWindows.removeValue(forKey: hostID)
            page.forceClose()
        }
    }

    private func approvePopup(_ request: ChromiumPopupRequest) -> Bool {
        guard let targetURL = request.targetURL else { return false }
        let blocked = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "popupPolicy" && $0.value == "block" } == true
        if blocked {
            recordPopupEvent([
                "event": "blocked", "targetURL": targetURL.absoluteString,
                "userGesture": request.userGesture,
                "openerSuppressed": request.openerSuppressed,
            ])
            return false
        }
        approvedPopupCount += 1
        return true
    }

    private func show(_ page: ChromiumPage, in window: NSWindow) {
        let id = ObjectIdentifier(page)
        if let existing = windows[id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            page.focus()
            return
        }
        let controller = HarnessWindowController(
            page: page, window: window, owner: self, initialURL: initialURL)
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        page.focus()
    }

    private func reserveValidationHost() -> UUID {
        let hostID = UUID()
        hostWindows[hostID] = Self.makeWindow()
        return hostID
    }

    private func showValidationPage(_ page: ChromiumPage) {
        guard let window = hostWindows[page.hostWindowID] else { return }
        show(page, in: window)
    }

    private func showDevTools(_ session: ChromiumDevToolsSession, hostID: UUID) -> Bool {
        guard let window = hostWindows[hostID] else { return false }
        window.contentView = session.nativeView
        session.nativeView.frame = window.contentLayoutRect
        session.nativeView.autoresizingMask = [.width, .height]
        window.title = "Cobble Chromium DevTools Harness"
        let activationAccepted = NSRunningApplication.current.activate(options: [.activateAllWindows])
        let activationDiagnostic = "devtools activation accepted=\(activationAccepted) " +
            "policy=\(NSApp.activationPolicy().rawValue)\n"
        try? FileHandle.standardError.write(contentsOf: Data(activationDiagnostic.utf8))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.zoom(nil)
        window.makeKeyAndOrderFront(nil)
        session.setVisible(true)
        session.focus()
        return session.nativeView.window === window && window.isVisible
    }

    private func closeValidationHost(_ hostID: UUID) {
        guard let window = hostWindows.removeValue(forKey: hostID) else { return }
        window.orderOut(nil)
        window.close()
    }

    private func reserveReentrantValidationHost(for page: ChromiumPage) -> UUID {
        let hostID = reserveValidationHost()
        closePageOnHostLookup[hostID] = page
        return hostID
    }

    private func hostWindow(for page: ChromiumPage?) -> NSWindow? {
        if let page, let controller = windows[ObjectIdentifier(page)] { return controller.window }
        return windows.values.first(where: { $0.window?.isKeyWindow == true })?.window ?? windows.values.first?.window
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Cobble Chromium Harness"
        window.isReleasedWhenClosed = false
        return window
    }

    private func receive(_ download: ChromiumDownload, from page: ChromiumPage) {
        let session = HarnessDownload(
            download: download,
            window: hostWindow(for: page),
            automaticDirectory: ProcessInfo.processInfo.environment["COBBLE_CHROMIUM_HARNESS_DOWNLOAD_DIRECTORY"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
            owner: self)
        downloads[ObjectIdentifier(download)] = session
        session.start()
    }

    func forget(_ download: ChromiumDownload) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func forget(_ controller: HarnessWindowController) {
        let id = ObjectIdentifier(controller.page)
        guard windows[id] === controller else { return }
        windows.removeValue(forKey: id)
        hostWindows.removeValue(forKey: controller.page.hostWindowID)
        if popupHosts.remove(controller.page.hostWindowID) != nil {
            recordPopupEvent([
                "event": "closed", "hostID": controller.page.hostWindowID.uuidString,
                "pageClosed": controller.page.isClosed,
            ])
        }
    }

    private func recordPopupEvent(_ event: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["COBBLE_CHROMIUM_POPUP_REPORT"],
              path.hasPrefix("/"), !path.utf8.contains(0) else { return }
        popupEvents.append(event)
        do {
            let data = try JSONSerialization.data(withJSONObject: popupEvents, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Could not record native popup event: \(error)\n".utf8))
        }
    }

    fileprivate func recordMetadata(_ page: ChromiumPage) {
        guard page === metadataPage,
              let path = ProcessInfo.processInfo.environment["COBBLE_CHROMIUM_METADATA_REPORT"],
              path.hasPrefix("/"), !path.utf8.contains(0) else { return }
        let favicon = page.faviconPNG
        let report: [String: Any] = [
            "url": page.urlString,
            "faviconBytes": favicon?.count ?? 0,
            "faviconPNG": favicon?.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) ?? false,
            "hoveredLink": page.hoveredLink ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Could not record native page metadata: \(error)\n".utf8))
        }
    }

    private func stop() {
        starting = false
        runtime.onReady = nil
        runtime.onWillStop = nil
        runtime.popupPolicy = nil
        runtime.onPopupWithDisposition = nil
        runtime.onDownload = nil
        runtime.hostWindow = nil
        runtime.onReopen = nil
        runtime.onOpenURLs = nil
        let current = Array(windows.values)
        windows.removeAll()
        hostWindows.removeAll()
        current.forEach { $0.runtimeStopped() }
    }
}

@MainActor private final class HarnessDownload {
    private let download: ChromiumDownload
    private weak var window: NSWindow?
    private let automaticDirectory: URL?
    private weak var owner: ChromiumHarness?
    private var destination: URL?
    private var staging: URL?
    private var panel: NSSavePanel?
    private var destinationExisted = false
    private var progressReported = false
    private var pauseAttempted = false
    private var interruptionCount = 0
    private var finished = false
    private var rejectedDestinationProbe: (() throws -> Void)?

    init(download: ChromiumDownload, window: NSWindow?, automaticDirectory: URL?,
         owner: ChromiumHarness) {
        self.download = download
        self.window = window
        self.automaticDirectory = automaticDirectory
        self.owner = owner
    }

    func start() {
        download.onProgress = { [weak self] received, total in
            self?.recordProgress(received: received, total: total)
        }
        download.onFinish = { [weak self] in self?.complete() }
        download.onFailure = { [weak self] error in self?.fail(error) }
        if let automaticDirectory { chooseAutomatically(in: automaticDirectory) }
        else { chooseWithPanel() }
    }

    private func chooseAutomatically(in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = safeFilename(download.suggestedFilename)
            destination = directory.appendingPathComponent(name)
            let staging = try makeStagingURL(named: name)
            self.staging = staging
            if name.hasPrefix("existing-destination-") {
                let sentinel = Data("Cobble existing destination sentinel\n".utf8)
                try sentinel.write(to: staging, options: .withoutOverwriting)
                let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
                let keys: [FileAttributeKey] = [.size, .modificationDate,
                                                .systemFileNumber, .posixPermissions]
                rejectedDestinationProbe = { [staging] in
                    let current = try FileManager.default.attributesOfItem(atPath: staging.path)
                    guard try Data(contentsOf: staging) == sentinel,
                          keys.allSatisfy({ current[$0] as? NSObject == attributes[$0] as? NSObject }) else {
                        throw ChromiumError.operationFailed("Chromium changed the existing destination sentinel.")
                    }
                }
            } else if name.hasPrefix("dangling-destination-") {
                let target = staging.deletingLastPathComponent().appendingPathComponent("missing-target")
                try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: target)
                rejectedDestinationProbe = { [staging] in
                    guard try FileManager.default.destinationOfSymbolicLink(atPath: staging.path) == target.path,
                          !FileManager.default.fileExists(atPath: target.path) else {
                        throw ChromiumError.operationFailed("Chromium followed or changed the dangling destination link.")
                    }
                }
            }
            download.setDestination(staging)
            if name.hasPrefix("cancel-") {
                download.cancel { [weak self] in self?.cancelled(name: name) }
            }
        } catch {
            download.setDestination(nil)
            fail(error)
        }
    }

    private func chooseWithPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename(download.suggestedFilename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.title = "Save Harness Download"
        self.panel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self, !finished else { return }
            self.panel = nil
            guard result == .OK, let destination = panel.url else {
                download.setDestination(nil)
                return
            }
            do {
                self.destination = destination
                self.destinationExisted = FileManager.default.fileExists(atPath: destination.path)
                self.staging = try self.makeStagingURL(named: destination.lastPathComponent)
                download.setDestination(self.staging)
            } catch {
                download.setDestination(nil)
                self.fail(error)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func complete() {
        guard !finished, let staging, let destination else { return }
        do {
            if let automaticDirectory, download.suggestedFilename.hasPrefix("network-") {
                // The terminal file barrier has already completed. Cancelling
                // again synchronously nests a native callback inside onFinish.
                var completed = false
                download.cancel {
                    completed = true
                    self.download.release()
                }
                guard completed else {
                    throw ChromiumError.operationFailed("Terminal cancellation callback was not immediate.")
                }
                // AppKit modal event processing must not delete the native
                // download while the outer state callback still uses its frame.
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                try Data().write(to: automaticDirectory.appendingPathComponent(
                    ".nested-terminal-cancel-\(safeFilename(download.suggestedFilename))"))
            }
            try recordMetadata(phase: "complete")
            if destinationExisted {
                _ = try FileManager.default.replaceItemAt(
                    destination, withItemAt: staging, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            finish()
        } catch { fail(error) }
    }

    private func cancelled(name: String) {
        guard !finished else { return }
        if let automaticDirectory {
            try? Data().write(to: automaticDirectory.appendingPathComponent(".cancelled-\(name)"))
        }
        finish()
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        if let automaticDirectory {
            let name = safeFilename(download.suggestedFilename)
            if name.hasPrefix("interrupt-"), download.canResume {
                interruptionCount += 1
                try? recordMetadata(phase: "interruption-\(interruptionCount)")
                try? Data(error.localizedDescription.utf8).write(to: automaticDirectory
                    .appendingPathComponent(".interrupted-\(interruptionCount)-\(name)"))
                if name.hasPrefix("interrupt-release-") {
                    download.release()
                    let staleResumeRejected: Bool
                    do {
                        try download.resume()
                        staleResumeRejected = false
                    } catch ChromiumError.closed {
                        staleResumeRejected = true
                    } catch {
                        staleResumeRejected = false
                    }
                    try? Data(String(staleResumeRejected).utf8).write(to: automaticDirectory
                        .appendingPathComponent(".released-interrupted-\(name)"))
                    finished = true
                    owner?.forget(download)
                } else if name.hasPrefix("interrupt-cancel-") {
                    download.cancel { [weak self] in self?.cancelled(name: name) }
                } else {
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(100))
                        guard let self, !finished else { return }
                        do {
                            try Data().write(to: automaticDirectory.appendingPathComponent(
                                ".resume-requested-\(self.interruptionCount)-\(name)"))
                            try self.download.resume()
                            try Data().write(to: automaticDirectory
                                .appendingPathComponent(".retry-\(self.interruptionCount)-\(name)"))
                        } catch {
                            download.cancel { [weak self] in self?.fail(error) }
                        }
                    }
                }
                return
            }
            var reportedError = error
            if let rejectedDestinationProbe {
                do {
                    try rejectedDestinationProbe()
                    try Data().write(to: automaticDirectory.appendingPathComponent(".rejected-\(name)"))
                    finish()
                    return
                } catch {
                    reportedError = error
                }
            }
            try? Data(reportedError.localizedDescription.utf8).write(
                to: automaticDirectory.appendingPathComponent(".failed-\(name)"))
        }
        finish()
    }

    private func recordMetadata(phase: String) throws {
        guard let automaticDirectory else { return }
        let value: [String: Any] = [
            "originalURL": download.originalURL?.absoluteString ?? "",
            "currentURL": download.currentURL?.absoluteString ?? "",
            "mimeType": download.mimeType ?? "",
            "receivedBytes": download.receivedBytes,
            "totalBytes": download.totalBytes.map { $0 as Any } ?? NSNull(),
            "interruptionReason": download.interruptionReasonCode.map { $0 as Any } ?? NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(
            to: automaticDirectory.appendingPathComponent(
                ".metadata-\(phase)-\(safeFilename(download.suggestedFilename)).json"), options: .atomic)
    }

    private func recordProgress(received: Int64, total: Int64) {
        guard !progressReported, received > 0, let automaticDirectory else { return }
        progressReported = true
        try? Data("\(received)/\(total)".utf8).write(
            to: automaticDirectory.appendingPathComponent(".progress-\(safeFilename(download.suggestedFilename))"))
        let name = safeFilename(download.suggestedFilename)
        guard name.hasPrefix("pause-"), !pauseAttempted else { return }
        pauseAttempted = true
        do {
            guard download.canPause, !download.canResume, !download.isPaused else {
                throw ChromiumError.operationFailed("Download did not advertise its running control state.")
            }
            try download.pause()
            guard download.isPaused, download.canResume, !download.canPause else {
                throw ChromiumError.operationFailed("Download did not advertise its paused control state.")
            }
            try Data().write(to: automaticDirectory.appendingPathComponent(".paused-\(name)"))
            if name.hasPrefix("pause-cancel-") {
                download.cancel { [weak self] in self?.cancelled(name: name) }
            } else {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !finished else { return }
                    do {
                        try download.resume()
                        guard download.canPause, !download.canResume, !download.isPaused else {
                            throw ChromiumError.operationFailed("Download did not return to its running control state.")
                        }
                        try Data().write(to: automaticDirectory.appendingPathComponent(".resumed-\(name)"))
                    } catch {
                        download.cancel { [weak self] in self?.fail(error) }
                    }
                }
            }
        } catch {
            download.cancel { [weak self] in self?.fail(error) }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        panel?.cancel(nil)
        panel = nil
        download.onProgress = nil
        download.onFinish = nil
        download.onFailure = nil
        let name = safeFilename(download.suggestedFilename)
        download.release()
        if name.hasPrefix("pause-") {
            let rejected: Bool
            do {
                try download.pause()
                rejected = false
            } catch ChromiumError.closed {
                do {
                    try download.resume()
                    rejected = false
                } catch ChromiumError.closed {
                    rejected = true
                } catch {
                    rejected = false
                }
            } catch {
                rejected = false
            }
            if rejected, let automaticDirectory {
                try? Data().write(to: automaticDirectory.appendingPathComponent(".released-controls-rejected-\(name)"))
            }
        }
        if let staging { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        owner?.forget(download)
    }

    private func makeStagingURL(named name: String) throws -> URL {
        let manager = FileManager.default
        return try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                               appropriateFor: manager.temporaryDirectory, create: true)
            .appendingPathComponent(name)
    }

    private func safeFilename(_ suggested: String) -> String {
        let name = URL(fileURLWithPath: suggested).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }
}

@MainActor private final class HarnessWindowController: NSWindowController, NSWindowDelegate {
    let page: ChromiumPage
    private weak var harness: ChromiumHarness?
    private let address = NSTextField()
    private let state = NSTextField(labelWithString: "Starting Chromium…")
    private let findField = NSSearchField()
    private let chromiumContainer = NSView()
    private let webKitView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private var allowingClose = false
    private var closeRequested = false

    init(page: ChromiumPage, window: NSWindow, owner: ChromiumHarness, initialURL: URL) {
        self.page = page
        self.harness = owner
        super.init(window: window)
        window.delegate = self
        configureWindow(initialURL: initialURL)
        page.onChange = { [weak self] in self?.refresh() }
        page.onClose = { [weak self] in self?.pageClosed() }
    }

    required init?(coder: NSCoder) { nil }

    private func configureWindow(initialURL: URL) {
        guard let content = window?.contentView else { return }
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        let back = NSButton(title: "Back", target: self, action: #selector(goBack))
        let forward = NSButton(title: "Forward", target: self, action: #selector(goForward))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reload))
        let printPage = NSButton(title: "Print…", target: self, action: #selector(printCurrentPage))
        address.placeholderString = initialURL.absoluteString
        address.target = self
        address.action = #selector(navigate)
        state.lineBreakMode = .byTruncatingTail
        controls.addArrangedSubview(back)
        controls.addArrangedSubview(forward)
        controls.addArrangedSubview(reload)
        controls.addArrangedSubview(printPage)
        controls.addArrangedSubview(address)
        controls.addArrangedSubview(state)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        state.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chromiumLabel = NSTextField(labelWithString: "Chromium")
        let webKitLabel = NSTextField(labelWithString: "WebKit")
        let chromiumColumn = NSStackView(views: [chromiumLabel, chromiumContainer])
        let webKitColumn = NSStackView(views: [webKitLabel, webKitView])
        [chromiumColumn, webKitColumn].forEach {
            $0.orientation = .vertical
            $0.alignment = .width
            $0.spacing = 6
        }
        let pages = NSStackView(views: [chromiumColumn, webKitColumn])
        pages.orientation = .horizontal
        pages.alignment = .height
        pages.distribution = .fillEqually
        pages.spacing = 8

        findField.placeholderString = "Find in Chromium"
        findField.target = self
        findField.action = #selector(findNext)
        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pageControls = NSStackView(views: [
            NSTextField(labelWithString: "Chromium controls"), findField,
            NSButton(title: "Previous", target: self, action: #selector(findPrevious)),
            NSButton(title: "Next", target: self, action: #selector(findNext)),
            NSButton(title: "Zoom Out", target: self, action: #selector(zoomOut)),
            NSButton(title: "100%", target: self, action: #selector(resetZoom)),
            NSButton(title: "Zoom In", target: self, action: #selector(zoomIn)),
        ])
        pageControls.orientation = .horizontal
        pageControls.spacing = 8
        let root = NSStackView(views: [controls, pageControls, pages])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            pages.widthAnchor.constraint(equalTo: root.widthAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let nativeView = page.nativeView
        nativeView.translatesAutoresizingMaskIntoConstraints = false
        chromiumContainer.addSubview(nativeView)
        NSLayoutConstraint.activate([
            nativeView.leadingAnchor.constraint(equalTo: chromiumContainer.leadingAnchor),
            nativeView.trailingAnchor.constraint(equalTo: chromiumContainer.trailingAnchor),
            nativeView.topAnchor.constraint(equalTo: chromiumContainer.topAnchor),
            nativeView.bottomAnchor.constraint(equalTo: chromiumContainer.bottomAnchor),
        ])
        webKitView.load(URLRequest(url: initialURL))
    }

    @objc private func navigate() {
        let value = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else { return }
        do { try page.load(url) }
        catch { state.stringValue = error.localizedDescription }
        webKitView.load(URLRequest(url: url))
    }

    @objc private func goBack() { page.goBack(); webKitView.goBack() }
    @objc private func goForward() { page.goForward(); webKitView.goForward() }
    @objc private func reload() { page.reload(); webKitView.reload() }
    @objc private func printCurrentPage() {
        do { try page.printPage() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func findNext() { find(backwards: false) }
    @objc private func findPrevious() { find(backwards: true) }
    private func find(backwards: Bool) {
        do { try page.find(findField.stringValue, backwards: backwards) }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func zoomOut() { changeZoom(multiplier: 0.8) }
    @objc private func zoomIn() { changeZoom(multiplier: 1.25) }
    @objc private func resetZoom() { setZoom(1) }
    private func changeZoom(multiplier: Double) {
        guard let factor = page.zoomFactor else {
            state.stringValue = "Zoom is unavailable for this page."
            return
        }
        setZoom(factor * multiplier)
    }
    private func setZoom(_ factor: Double) {
        do { try page.setZoomFactor(factor) }
        catch { state.stringValue = error.localizedDescription }
    }

    private func refresh() {
        if !page.urlString.isEmpty { address.stringValue = page.urlString }
        state.stringValue = page.isCrashed ? "Chromium renderer crashed" :
            (page.isLoading ? "Loading…" : (page.title.isEmpty ? "Loaded" : page.title))
        harness?.recordMetadata(page)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allowingClose else {
            closePageThenWindow()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { harness?.forget(self) }

    private func closePageThenWindow() {
        guard !closeRequested else { return }
        closeRequested = true
        Task { [weak self] in
            guard let self else { return }
            if !page.isClosed, !page.isClosing { page.close() }
            guard await page.waitUntilClosed() else {
                closeRequested = false
                return
            }
            finishClose()
        }
    }

    private func pageClosed() {
        if !closeRequested { finishClose() }
    }

    private func finishClose() {
        guard !allowingClose else { return }
        allowingClose = true
        window?.performClose(nil)
    }

    func runtimeStopped() {
        page.onChange = nil
        page.onClose = nil
        closeRequested = true
        allowingClose = true
        window?.performClose(nil)
    }
}
