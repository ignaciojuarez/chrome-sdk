import Foundation
import CobbleChromium

@MainActor
enum HarnessClientCertificateValidation {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(runtime: ChromiumRuntime, token: String, baseline: URL,
                    selectURL: URL, cancelURL: URL, unhandledURL: URL,
                    staleURL: URL, closeURL: URL, reentrantURL: URL,
                    documentPageURL: URL, documentResourceURL: URL,
                    expectedSubject: String, expectedIssuer: String,
                    expectedSerial: String, reserveHost: () -> UUID,
                    showPage: (ChromiumPage) -> Void,
                    closeHost: ((UUID) -> Void)?) async throws -> [String: Bool] {
        let previousHandler = runtime.onClientCertificateRequest
        defer { runtime.onClientCertificateRequest = previousHandler }
        var checks: [String: Bool] = [:]
        let context = try await runtime.openContext(
            profileKey: "harness-client-certificate")

        let (selectPage, selectHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        let selectRequest = try await captureRequest(
            runtime: runtime, page: selectPage, target: selectURL)
        logMetadata("navigation", request: selectRequest, target: selectURL,
                    expectedTopLevel: baseline, expectedSubject: expectedSubject,
                    expectedIssuer: expectedIssuer, expectedSerial: expectedSerial)
        checks["clientCertificateExactNavigationMetadata"] =
            validMetadata(selectRequest, page: selectPage, target: selectURL,
                          baseline: baseline, expectedSubject: expectedSubject,
                          expectedIssuer: expectedIssuer, expectedSerial: expectedSerial)
        let pendingHost = reserveHost()
        checks["clientCertificatePromptMoveRejected"] = moveIsRejected(
            selectPage, temporaryHost: pendingHost)
        closeHost?(pendingHost)
        guard let choice = selectRequest.choices.first else {
            throw Failure(message: "Client-certificate request had no choice.")
        }
        checks["clientCertificateInvalidChoiceRejected"] =
            !selectRequest.select(choiceID: UInt64.max) && selectRequest.isPending
        checks["clientCertificateSelectAcceptedExactlyOnce"] =
            selectRequest.select(choiceID: choice.id) &&
            !selectRequest.select(choiceID: choice.id) && !selectRequest.cancel() &&
            !selectRequest.isPending
        try await wait(selectPage, url: selectURL,
                       title: title("select", token: token))
        let selectedDOM = try await selectPage.currentDOM()
        checks["clientCertificateSelectedNavigationAuthenticated"] =
            selectedDOM.contains("data-client-certificate=\"select\"") &&
            selectedDOM.contains("AUTHENTICATED-\(token)")
        await close(selectPage, host: selectHost, closeHost: closeHost)

        let (reentrantPage, reentrantHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        let reentrantRequest = try await captureRequest(
            runtime: runtime, page: reentrantPage, target: reentrantURL)
        guard let reentrantChoice = reentrantRequest.choices.first else {
            throw Failure(message: "Reentrant client-certificate request had no choice.")
        }
        var invalidateOnStateChange = true
        var invalidatingLoadAccepted = false
        let reentrantPreviousChange = reentrantPage.onChange
        reentrantPage.onChange = {
            reentrantPreviousChange?()
            guard invalidateOnStateChange else { return }
            invalidateOnStateChange = false
            do {
                try reentrantPage.load(baseline)
                invalidatingLoadAccepted = true
            } catch {}
        }
        let reentrantSelectionAccepted =
            reentrantRequest.select(choiceID: reentrantChoice.id)
        try await wait(reentrantPage, url: baseline, title: nil)
        reentrantPage.onChange = reentrantPreviousChange
        checks["reentrantClientCertificateSelectionAccepted"] =
            reentrantSelectionAccepted
        checks["reentrantClientCertificateInvalidatedToBaseline"] =
            invalidatingLoadAccepted && !invalidateOnStateChange &&
            reentrantPage.urlString == baseline.absoluteString
        checks["reentrantClientCertificateStaleActionsRejected"] =
            !reentrantRequest.isPending && !reentrantRequest.cancel() &&
            !reentrantRequest.select(choiceID: reentrantChoice.id)
        await close(reentrantPage, host: reentrantHost, closeHost: closeHost)

        let (documentPage, documentHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        var documentRequest: ChromiumClientCertificateRequest?
        runtime.onClientCertificateRequest = { request in
            guard request.page === documentPage else {
                request.cancel()
                return
            }
            documentRequest = request
        }
        try documentPage.load(documentPageURL)
        try await waitForCondition("document client-certificate request") {
            documentRequest != nil
        }
        guard let documentRequest, let documentChoice = documentRequest.choices.first else {
            throw Failure(message: "Document client-certificate request was not delivered.")
        }
        logMetadata("document", request: documentRequest, target: documentResourceURL,
                    expectedTopLevel: documentPageURL, expectedSubject: expectedSubject,
                    expectedIssuer: expectedIssuer, expectedSerial: expectedSerial)
        checks["clientCertificateExactDocumentMetadata"] =
            validDocumentMetadata(
                documentRequest, page: documentPage, challenger: documentResourceURL,
                document: documentPageURL, expectedSubject: expectedSubject,
                expectedIssuer: expectedIssuer, expectedSerial: expectedSerial)
        let documentSelected = documentRequest.select(choiceID: documentChoice.id) &&
            !documentRequest.select(choiceID: documentChoice.id) &&
            !documentRequest.cancel()
        try await wait(documentPage, url: documentPageURL,
                       title: title("document", token: token))
        let documentDOM = try await documentPage.currentDOM()
        checks["clientCertificateDocumentRequestAuthenticated"] = documentSelected &&
            documentDOM.contains("data-client-certificate=\"document\"") &&
            documentDOM.contains("AUTHENTICATED-\(token)")
        await close(documentPage, host: documentHost, closeHost: closeHost)

        let (cancelPage, cancelHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        let cancelRequest = try await captureRequest(
            runtime: runtime, page: cancelPage, target: cancelURL)
        checks["clientCertificateExplicitCancelExactlyOnce"] =
            cancelRequest.cancel() && !cancelRequest.cancel() &&
            !cancelRequest.select(choiceID: cancelRequest.choices[0].id) &&
            !cancelRequest.isPending
        try await waitUntilSettled(cancelPage)
        checks["clientCertificateCancelDidNotAuthenticate"] =
            cancelPage.title != title("cancel", token: token)
        await close(cancelPage, host: cancelHost, closeHost: closeHost)

        let (unhandledPage, unhandledHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        runtime.onClientCertificateRequest = nil
        var unhandledNavigationObserved = false
        let previousChange = unhandledPage.onChange
        unhandledPage.onChange = {
            unhandledNavigationObserved = true
            previousChange?()
        }
        try unhandledPage.load(unhandledURL)
        try await waitForCondition("unhandled client-certificate navigation start") {
            unhandledNavigationObserved
        }
        try await waitUntilSettled(unhandledPage)
        unhandledPage.onChange = previousChange
        checks["unhandledClientCertificateDenied"] =
            !unhandledPage.hasPendingPrompt &&
            unhandledPage.title != title("unhandled", token: token)
        await close(unhandledPage, host: unhandledHost, closeHost: closeHost)

        let (stalePage, staleHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        let staleRequest = try await captureRequest(
            runtime: runtime, page: stalePage, target: staleURL)
        var staleCancellationCount = 0
        staleRequest.onCancel = { staleCancellationCount += 1 }
        try stalePage.load(baseline)
        try await wait(stalePage, url: baseline, title: nil)
        try await waitForCondition("stale client-certificate cancellation") {
            staleCancellationCount == 1
        }
        checks["staleClientCertificateCancelledOnce"] =
            staleCancellationCount == 1 && !staleRequest.isPending &&
            !staleRequest.cancel() &&
            !staleRequest.select(choiceID: staleRequest.choices[0].id)
        await close(stalePage, host: staleHost, closeHost: closeHost)

        let (closingPage, closingHost) = try await makePage(
            context: context, baseline: baseline, reserveHost: reserveHost,
            showPage: showPage)
        let closingRequest = try await captureRequest(
            runtime: runtime, page: closingPage, target: closeURL)
        var closeCancellationCount = 0
        closingRequest.onCancel = { closeCancellationCount += 1 }
        closingPage.forceClose()
        let didClose = await closingPage.waitUntilClosed()
        try await waitForCondition("closed-page client-certificate cancellation") {
            closeCancellationCount == 1
        }
        checks["pageCloseCancelsClientCertificateOnce"] =
            didClose && closeCancellationCount == 1 &&
            !closingRequest.isPending && !closingRequest.cancel() &&
            !closingRequest.select(choiceID: closingRequest.choices[0].id)
        closeHost?(closingHost)
        checks["clientCertificateContextCloses"] = await context.close()

        return checks
    }

    private static func makePage(
        context: ChromiumContext, baseline: URL, reserveHost: () -> UUID,
        showPage: (ChromiumPage) -> Void
    ) async throws -> (ChromiumPage, UUID) {
        let host = reserveHost()
        let page = try context.makePage(url: baseline, hostWindowID: host)
        showPage(page)
        try await wait(page, url: baseline, title: nil)
        return (page, host)
    }

    private static func captureRequest(
        runtime: ChromiumRuntime, page: ChromiumPage, target: URL
    ) async throws -> ChromiumClientCertificateRequest {
        var captured: ChromiumClientCertificateRequest?
        runtime.onClientCertificateRequest = { request in
            guard request.page === page else {
                request.cancel()
                return
            }
            captured = request
        }
        try page.load(target)
        try await waitForCondition("client-certificate request for \(target.host ?? "host")") {
            captured != nil
        }
        guard let captured else {
            throw Failure(message: "Client-certificate request was not delivered.")
        }
        return captured
    }

    private static func validMetadata(
        _ request: ChromiumClientCertificateRequest, page: ChromiumPage,
        target: URL, baseline: URL, expectedSubject: String,
        expectedIssuer: String, expectedSerial: String
    ) -> Bool {
        guard request.page === page, request.id != 0, request.isPending,
              request.primaryMainFrame, !request.choicesTruncated,
              request.challengerOrigin == serializedOrigin(target),
              request.topLevelOrigin == serializedOrigin(baseline),
              request.visiblePageOrigin == serializedOrigin(baseline),
              request.choices.count == 1,
              case let .navigation(navigationID) = request.context,
              navigationID > 0 else { return false }
        let choice = request.choices[0]
        return choice.id != 0 && choice.subject == expectedSubject &&
            choice.issuer == expectedIssuer &&
            choice.serialNumber.caseInsensitiveCompare(expectedSerial) == .orderedSame &&
            choice.validFrom != nil && choice.validUntil != nil
    }

    private static func validDocumentMetadata(
        _ request: ChromiumClientCertificateRequest, page: ChromiumPage,
        challenger: URL, document: URL, expectedSubject: String,
        expectedIssuer: String, expectedSerial: String
    ) -> Bool {
        guard request.page === page, request.id != 0, request.isPending,
              request.primaryMainFrame, !request.choicesTruncated,
              request.challengerOrigin == serializedOrigin(challenger),
              request.topLevelOrigin == serializedOrigin(document),
              request.visiblePageOrigin == serializedOrigin(document),
              request.choices.count == 1,
              case let .document(processID, routingID, token) = request.context,
              processID >= 0, routingID >= 0, !token.isEmpty else { return false }
        let choice = request.choices[0]
        return choice.id != 0 && choice.subject == expectedSubject &&
            choice.issuer == expectedIssuer &&
            choice.serialNumber.caseInsensitiveCompare(expectedSerial) == .orderedSame &&
            choice.validFrom != nil && choice.validUntil != nil
    }

    private static func serializedOrigin(_ url: URL) -> String {
        var result = "\(url.scheme ?? "")://\(url.host ?? "")"
        if let port = url.port { result += ":\(port)" }
        return result
    }

    private static func logMetadata(
        _ label: String, request: ChromiumClientCertificateRequest,
        target: URL, expectedTopLevel: URL, expectedSubject: String,
        expectedIssuer: String, expectedSerial: String
    ) {
        let context: String
        switch request.context {
        case let .navigation(navigationID):
            context = "navigation:\(navigationID)"
        case let .document(processID, routingID, token):
            context = "document:\(processID):\(routingID):\(token)"
        }
        let choices = request.choices.map {
            "id=\($0.id),subject=\($0.subject),issuer=\($0.issuer),serial=\($0.serialNumber)," +
            "from=\(String(describing: $0.validFrom)),until=\(String(describing: $0.validUntil))"
        }.joined(separator: ";")
        let message = "client-certificate metadata \(label) " +
            "request=\(request.id) pending=\(request.isPending) primary=\(request.primaryMainFrame) " +
            "truncated=\(request.choicesTruncated) challenger=\(request.challengerOrigin) " +
            "top=\(request.topLevelOrigin) visible=\(request.visiblePageOrigin) context=\(context) " +
            "choices=[\(choices)] expectedChallenger=\(serializedOrigin(target)) " +
            "expectedTop=\(serializedOrigin(expectedTopLevel)) expectedSubject=\(expectedSubject) " +
            "expectedIssuer=\(expectedIssuer) expectedSerial=\(expectedSerial)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func title(_ name: String, token: String) -> String {
        "Cobble Client Certificate \(name) \(token)"
    }

    private static func moveIsRejected(_ page: ChromiumPage,
                                       temporaryHost: UUID) -> Bool {
        let original = page.hostWindowID
        do {
            try page.move(toHostWindowID: temporaryHost)
            try? page.move(toHostWindowID: original)
            return false
        } catch {
            return page.hostWindowID == original
        }
    }

    private static func wait(_ page: ChromiumPage, url: URL,
                             title: String?) async throws {
        try await waitForCondition("page \(url.absoluteString)") {
            !page.isClosed && !page.isLoading && page.urlString == url.absoluteString &&
                (title == nil || page.title == title)
        }
    }

    private static func waitUntilSettled(_ page: ChromiumPage) async throws {
        try await waitForCondition("client-certificate navigation settlement") {
            page.isClosed || (!page.isLoading && !page.hasPendingPrompt)
        }
    }

    private static func waitForCondition(
        _ description: String, condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Timed out waiting for \(description).")
    }

    private static func close(_ page: ChromiumPage, host: UUID,
                              closeHost: ((UUID) -> Void)?) async {
        if !page.isClosed {
            page.forceClose()
            _ = await page.waitUntilClosed()
        }
        closeHost?(host)
    }
}
