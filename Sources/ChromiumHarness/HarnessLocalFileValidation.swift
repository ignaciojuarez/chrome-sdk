import Foundation
import Darwin
import CobbleChromium

@MainActor
enum HarnessLocalFileValidation {
    static func run(runtime: ChromiumRuntime, token: String, origin: URL,
                    baseline: URL, reserveHost: () -> UUID,
                    showPage: (ChromiumPage) -> Void,
                    closeHost: ((UUID) -> Void)?) async throws -> [String: Bool] {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &resolved) != nil else {
            throw Failure("Could not canonicalize the local-file fixture directory.")
        }
        let resolvedPath = String(decoding: resolved.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
                                  as: UTF8.self)
        let canonicalTemporaryDirectory = URL(fileURLWithPath: resolvedPath,
                                              isDirectory: true)
        let root = canonicalTemporaryDirectory.appendingPathComponent(
            "cobble-local-file-\(token)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sibling = root.appendingPathComponent("sibling.txt")
        let child = root.appendingPathComponent("child.html")
        let worker = root.appendingPathComponent("worker.js")
        let image = root.appendingPathComponent("pixel.png")
        let download = root.appendingPathComponent("download.txt")
        try Data("SIBLING-\(token)".utf8).write(to: sibling)
        try Data(("<title>Forbidden child</title>CHILD-\(token)" +
            "<script>parent.postMessage('CHILD-\(token)', '*')</script>").utf8).write(to: child)
        try Data("postMessage('WORKER-\(token)')".utf8).write(to: worker)
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            .write(to: image)
        try Data("DOWNLOAD-\(token)".utf8).write(to: download)

        func html(_ title: String, marker: String, probes: Bool = false,
                  padding: Int = 0) -> Data {
            let probe = probes ? """
              <img id="probe-image">
              <a id="probe-download" download href="download.txt">download</a>
              <script>
              const done = (name, value) => document.body.dataset[name] = value;
              const image = document.querySelector('#probe-image');
              image.addEventListener('error', () => done('image', 'denied'));
              image.addEventListener('load', () => done('image', 'allowed'));
              image.src = 'pixel.png';
              const frame = document.createElement('iframe');
              frame.id = 'probe-frame';
              let childMessageReceived = false;
              window.addEventListener('message', event => {
                if (event.data === 'CHILD-\(token)') {
                  childMessageReceived = true;
                  done('frame', 'allowed');
                }
              });
              frame.addEventListener('load', () => {
                setTimeout(() => {
                  if (!childMessageReceived) done('frame', 'denied');
                }, 250);
              });
              frame.addEventListener('error', () => done('frame', 'denied'));
              frame.src = 'child.html';
              document.body.append(frame);
              try {
                const localWorker = new Worker('worker.js');
                localWorker.onmessage = () => done('worker', 'allowed');
                localWorker.onerror = () => done('worker', 'denied');
              } catch { done('worker', 'denied'); }
              fetch('sibling.txt').then(response => response.text()).then(
                value => done('fetch', value.includes('SIBLING-\(token)') ? 'allowed' : 'denied'),
                () => done('fetch', 'denied'));
              document.querySelector('#probe-download').click();
              </script>
            """ : ""
            return Data(("<!doctype html><meta charset=utf-8><title>\(title)</title>" +
                "<body><main id=marker>\(marker)</main>\(probe)" +
                String(repeating: "x", count: padding) + "</body>").utf8)
        }

        let first = root.appendingPathComponent("first.html")
        let second = root.appendingPathComponent("second.html")
        let text = root.appendingPathComponent("plain.txt")
        let large = root.appendingPathComponent("held.html")
        try html("Local first \(token)", marker: "FIRST-\(token)", probes: true).write(to: first)
        try html("Local second \(token)", marker: "SECOND-\(token)").write(to: second)
        try Data("PLAIN-\(token)".utf8).write(to: text)
        try html("Held original \(token)", marker: "HELD-ORIGINAL-\(token)",
                 padding: 64 * 1024).write(to: large)

        let context = try await runtime.openContext(profileKey: "harness-local-file")
        let host = reserveHost()
        let page = try context.makePage(url: baseline, hostWindowID: host)
        showPage(page)
        defer { closeHost?(host) }
        try await wait(page, url: baseline)

        var checks: [String: Bool] = [:]
        var downloadCount = 0
        let previousDownload = runtime.onDownload
        runtime.onDownload = { source, item in
            downloadCount += 1
            previousDownload?(source, item)
        }
        defer { runtime.onDownload = previousDownload }

        try await page.openLocalFile(first)
        try await wait(page, url: first, title: "Local first \(token)")
        let firstDOM = try await page.currentDOM()
        checks["localFileExactHTMLLoaded"] = page.urlString == first.absoluteString &&
            firstDOM.contains("FIRST-\(token)")
        let isolatedDOM = try await waitForResourceProbe(page)
        try await Task.sleep(for: .milliseconds(300))
        checks["localFileChildrenWorkersAndDownloadsDenied"] =
            ["image", "frame", "worker", "fetch"].allSatisfy {
                isolatedDOM.contains("data-\($0)=\"denied\"")
            } && downloadCount == 0

        let beforeSibling = page.urlString
        try page.load(sibling)
        try await Task.sleep(for: .milliseconds(300))
        checks["genericSiblingFileNavigationDenied"] = page.urlString == beforeSibling

        try await page.openLocalFile(text)
        try await wait(page, url: text)
        checks["localFileExactTextLoaded"] = (try await page.currentDOM()).contains("PLAIN-\(token)")

        try await page.openLocalFile(first)
        try await wait(page, url: first, title: "Local first \(token)")
        try await page.openLocalFile(second)
        try await wait(page, url: second, title: "Local second \(token)")
        let adjacent = page.urlString
        page.goBack()
        page.goForward()
        try await Task.sleep(for: .milliseconds(300))
        checks["localFileAdjacentHistoryUnavailable"] =
            !page.canGoBack && !page.canGoForward && page.urlString == adjacent

        try html("Local second changed \(token)", marker: "SECOND-CHANGED-\(token)").write(to: second)
        checks["localFileNativeReloadRefused"] = !page.reload()
        try await page.openLocalFile(second)
        try await wait(page, url: second, title: "Local second changed \(token)")
        let changedDOM = try await page.currentDOM()
        checks["localFileSecureReopenReplacesCurrentEntry"] =
            changedDOM.contains("SECOND-CHANGED-\(token)") && !page.canGoBack && !page.canGoForward

        let replacement = root.appendingPathComponent("held-new.html")
        try html("Held replacement \(token)", marker: "HELD-REPLACEMENT-\(token)").write(to: replacement)
        let previousPageChange = page.onChange
        var heldPathReplaced = false
        page.onChange = {
            previousPageChange?()
            if !heldPathReplaced, page.isLoading, page.urlString == large.absoluteString {
                heldPathReplaced = rename(replacement.path, large.path) == 0
            }
        }
        do {
            defer { page.onChange = previousPageChange }
            try await page.openLocalFile(large)
        }
        try await wait(page, url: large, title: "Held original \(token)")
        let heldDOM = try await page.currentDOM()
        checks["localFileUsesHeldAuthorizedInode"] = heldPathReplaced &&
            heldDOM.contains("HELD-ORIGINAL-\(token)")

        let leafLink = root.appendingPathComponent("leaf-link.html")
        try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: first)
        let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        let parentFile = realParent.appendingPathComponent("parent.html")
        try html("Parent \(token)", marker: token).write(to: parentFile)
        let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)
        let fifo = root.appendingPathComponent("fixture.fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw Failure("Could not create FIFO fixture.") }
        let pdfExtension = root.appendingPathComponent("fixture.PDF")
        let pdfMagic = root.appendingPathComponent("fixture-data.bin")
        try Data("not a PDF payload".utf8).write(to: pdfExtension)
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdfMagic)
        var rejected: [Bool] = []
        for candidate in [leafLink, parentLink.appendingPathComponent("parent.html"), fifo,
                          URL(fileURLWithPath: "/dev/null"), root, pdfExtension, pdfMagic] {
            rejected.append(await rejects { try await page.openLocalFile(candidate) })
        }
        checks["localFileSymlinkLeafRejected"] = rejected[0]
        checks["localFileSymlinkParentRejected"] = rejected[1]
        checks["localFileFIFORejected"] = rejected[2]
        checks["localFileDeviceRejected"] = rejected[3]
        checks["localFileDirectoryRejected"] = rejected[4]
        checks["localFilePDFExtensionRejected"] = rejected[5]
        checks["localFilePDFMagicRejected"] = rejected[6]

        let httpRedirect = origin.appendingPathComponent("fixture/\(token)/local-http-redirect")
        try page.load(httpRedirect)
        try await wait(page, url: baseline, title: "Cobble Smoke A")
        checks["httpRedirectStillAllowed"] = true

        var fileRedirect = URLComponents(
            url: origin.appendingPathComponent("fixture/\(token)/local-file-redirect"),
            resolvingAgainstBaseURL: false)!
        fileRedirect.queryItems = [URLQueryItem(name: "target", value: first.absoluteString)]
        try page.load(fileRedirect.url!)
        try await Task.sleep(for: .milliseconds(500))
        let fileRedirectDOM = try await page.currentDOM()
        checks["httpRedirectToFileDenied"] = page.urlString != first.absoluteString &&
            !fileRedirectDOM.contains("FIRST-\(token)")

        try await page.openLocalFile(first)
        try await wait(page, url: first, title: "Local first \(token)")
        try page.load(origin.appendingPathComponent("fixture/\(token)/local-no-content"))
        try await Task.sleep(for: .milliseconds(300))
        let afterNoContentDOM = try await page.currentDOM()
        checks["localFileProvisionalCancellationPreservesDocument"] =
            page.urlString == first.absoluteString &&
            afterNoContentDOM.contains("FIRST-\(token)")

        try page.load(origin.appendingPathComponent("fixture/\(token)/local-abort"))
        try await Task.sleep(for: .milliseconds(500))
        let afterAbortDOM = try await page.currentDOM()
        let committedErrorURL = page.urlString
        try page.load(first)
        try await Task.sleep(for: .milliseconds(300))
        checks["localFileCommittedErrorRevokesAuthorization"] =
            committedErrorURL.contains("/local-abort") && !page.canGoBack &&
            !afterAbortDOM.contains("FIRST-\(token)") && page.urlString == committedErrorURL
        try html("Local first after abort \(token)", marker: "AFTER-ABORT-\(token)").write(to: first)
        try await page.openLocalFile(first)
        try await wait(page, url: first, title: "Local first after abort \(token)")
        checks["localFileCanBeReauthorizedAfterCommittedError"] =
            (try await page.currentDOM()).contains("AFTER-ABORT-\(token)")

        try page.load(baseline)
        try await wait(page, url: baseline, title: "Cobble Smoke A")
        page.goBack()
        try await Task.sleep(for: .milliseconds(300))
        checks["committedHTTPRevokesLocalFileHistory"] =
            !page.canGoBack && page.urlString == baseline.absoluteString

        let supersede = root.appendingPathComponent("supersede.html")
        try html("Superseded \(token)", marker: token, padding: 8 * 1024 * 1024).write(to: supersede)
        let superseded = Task { () -> Bool in
            do { try await page.openLocalFile(supersede); return false } catch { return true }
        }
        await Task.yield()
        try page.load(baseline)
        checks["localFileSupersedeCompletesOnceWithFailure"] = await superseded.value
        try await wait(page, url: baseline, title: "Cobble Smoke A")

        let closingHost = reserveHost()
        var closingPage: ChromiumPage? = try context.makePage(url: baseline, hostWindowID: closingHost)
        showPage(closingPage!)
        try await wait(closingPage!, url: baseline)
        let releasedPage = WeakPage(closingPage)
        let closeTask = Task { [page = closingPage!] () -> Bool in
            do { try await page.openLocalFile(supersede); return false } catch { return true }
        }
        await Task.yield()
        closingPage!.forceClose()
        let didClose = await closingPage!.waitUntilClosed()
        closingPage = nil
        let callbackFailed = await closeTask.value
        await Task.yield()
        checks["localFileCloseCompletesOnceAndReleasesPage"] =
            didClose && callbackFailed && releasedPage.value == nil
        closeHost?(closingHost)

        page.forceClose()
        guard await page.waitUntilClosed(), await context.close() else {
            throw Failure("Local-file fixture page or context did not close.")
        }
        return checks
    }

    private static func wait(_ page: ChromiumPage, url: URL, title: String? = nil) async throws {
        for _ in 0..<200 {
            if page.urlString == url.absoluteString && !page.isLoading &&
                (title == nil || page.title == title) { return }
            if page.isClosed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Timed out waiting for local-file navigation to \(url.absoluteString); " +
            "observed url=\(page.urlString) title=\(page.title) loading=\(page.isLoading) " +
            "closed=\(page.isClosed) crashed=\(page.isCrashed).")
    }

    private static func rejects(_ operation: () async throws -> Void) async -> Bool {
        do { try await operation(); return false } catch { return true }
    }

    private static func waitForResourceProbe(_ page: ChromiumPage) async throws -> String {
        for _ in 0..<200 {
            let dom = try await page.currentDOM()
            if ["image", "frame", "worker", "fetch"].allSatisfy({
                dom.contains("data-\($0)=\"denied\"") ||
                    dom.contains("data-\($0)=\"allowed\"")
            }) { return dom }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("A local child-resource probe did not settle.")
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class WeakPage {
        weak var value: ChromiumPage?
        init(_ value: ChromiumPage?) { self.value = value }
    }
}
