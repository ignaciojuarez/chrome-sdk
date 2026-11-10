import Foundation
import CobbleChromium

/// Camera and microphone state after the host answers: what meeting sites (Zoom, Meet,
/// Teams) read to choose a device. Kept out of the main validation function, which is
/// already at the limit of what CI can type-check.
@MainActor
enum HarnessMediaDeviceValidation {
    static func run(runtime: ChromiumRuntime, page: ChromiumPage, token: String, origin: String,
                    devices: URL, exact: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func devicesTitle(_ state: String, _ listed: Bool) -> String {
            "Cobble Devices \(token) \(state) \(state) \(listed) \(listed)"
        }
        // Like Chrome's "Allow this time", the preceding allow leaves a one-time grant:
        // permissions.query reports granted and enumerateDevices exposes IDs and labels.
        try page.load(devices)
        try await wait(for: page, url: devices, title: devicesTitle("granted", true))
        checks["mediaAllowExposesDevices"] = true
        var exactRequests: [ChromiumMediaPermissionRequest] = []
        runtime.onMediaPermissionRequest = { exactRequests.append($0); $0.allow() }
        try page.load(exact)
        try await wait(for: page, url: exact, title: "Cobble Exact Granted \(token)")
        checks["mediaExactDeviceGranted"] = exactRequests.count == 1 &&
            exactRequests[0].kinds == [.camera, .microphone]
        guard page.stopMediaCapture() else {
            throw ChromiumError.operationFailed("Native media capture stop was rejected after the exact-device request.")
        }
        try await wait("exact-device media capture stop") {
            !page.isCapturingMicrophone && !page.isCapturingCamera
        }
        runtime.onMediaPermissionRequest = nil
        guard page.context.resetPermission([.camera, .microphone], origin: origin) else {
            throw ChromiumError.operationFailed("Native camera and microphone reset was rejected.")
        }
        try page.load(devices)
        try await wait(for: page, url: devices, title: devicesTitle("prompt", false))
        checks["mediaResetHidesDevices"] = true
        // Saved host decisions answer the same quiet checks.
        var resolved: [(ChromiumMediaPermissionKinds, String, String)] = []
        var saved = ChromiumPermissionSetting.allow
        page.context.permissionResolver = { kind, requesting, embedding in
            resolved.append((kind, requesting, embedding))
            return kind == .windowManagement ? .ask : saved
        }
        try page.load(devices)
        try await wait(for: page, url: devices, title: devicesTitle("granted", true))
        saved = .deny
        try page.load(devices)
        try await wait(for: page, url: devices, title: devicesTitle("denied", false))
        page.context.permissionResolver = nil
        checks["mediaSavedDecisionsAnswerQuietly"] = resolved.contains { $0.0 == .camera } &&
            resolved.contains { $0.0 == .microphone } &&
            resolved.allSatisfy { ($0.0 == .camera || $0.0 == .microphone) && $0.1 == origin && $0.2 == origin }
        checks["mediaResetValidatesKind"] =
            !page.context.resetPermission([], origin: origin) &&
            !page.context.resetPermission([.camera, .display], origin: origin) &&
            !page.context.resetPermission(.camera, origin: origin + "/path")
        return checks
    }

    private static func wait(for page: ChromiumPage, url: URL, title: String) async throws {
        try await wait({ "\(url.path) with title \"\(title)\"; got \"\(page.title)\"" }) {
            page.urlString == url.absoluteString && !page.isLoading && page.title == title
        }
    }

    private static func wait(_ description: @autoclosure () -> String, until ready: () -> Bool) async throws {
        try await wait({ description() }, until: ready)
    }

    private static func wait(_ description: () -> String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !ready() {
            guard ContinuousClock.now < deadline else {
                throw ChromiumError.operationFailed("Timed out waiting for \(description()).")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
