// WindowReopen's native reopen approach and window heuristic are based on
// Command Reopen 1.5.5, Copyright (c) 2025 Chen, licensed under MIT. See LICENSE.

import AppKit
import CoreGraphics
import os

private let version = "1.1.0"
private let log = Logger(subsystem: "local.windowreopen", category: "service")

private final class WindowReopen {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.spotlight", "com.apple.notificationcenterui",
        "com.apple.controlcenter", "com.apple.loginwindow", "com.apple.securityagent",
        "com.apple.screencaptureui", "com.apple.universalcontrol",
        "com.dev.kkuk.commandreopen", "com.dev.kkuk.commandreopen.direct"
    ]

    private let workspace = NSWorkspace.shared
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var lastActivatedPID: pid_t?
    private var lastSpaceChange = -Double.infinity
    private var suppressUntil: [pid_t: TimeInterval] = [:]
    private var sessionIsActive = true
    private var foregroundTimer: Timer?
    private var foregroundApplication: NSRunningApplication?
    private var sawForegroundWindow = false
    private var missingWindowSince: TimeInterval?
    private var handoffActivation: (pid: pid_t, expiresAt: TimeInterval)?

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func run() {
        let center = workspace.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.applicationActivated(app)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastSpaceChange = self.uptime
            self.resetForegroundWindowObservation()
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessionIsActive = false
            self?.cancelPending()
            self?.handoffActivation = nil
            self?.observeForeground(nil)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionIsActive = true
            self.observeCurrentForeground()
        })

        observeCurrentForeground()
        log.notice("WindowReopen \(version, privacy: .public) started")
        RunLoop.main.run()
    }

    deinit {
        foregroundTimer?.invalidate()
        for token in observers {
            workspace.notificationCenter.removeObserver(token)
        }
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != lastActivatedPID else { return }
        lastActivatedPID = pid
        cancelPending()
        let now = uptime
        let fromHandoff = handoffActivation.map { $0.pid == pid && now <= $0.expiresAt } ?? false
        handoffActivation = nil
        observeForeground(sessionIsActive ? app : nil)

        guard sessionIsActive, !fromHandoff, !sawForegroundWindow, NSEvent.pressedMouseButtons == 0,
              Self.isSupportedApplication(app), app.isFinishedLaunching,
              (suppressUntil[pid] ?? 0) <= now else {
            return
        }
        if let launchDate = app.launchDate, abs(launchDate.timeIntervalSinceNow) < 0.9 {
            return
        }

        schedule(app, after: 0.20, deadline: now + 1.2, missingWindowSample: false)
    }

    private func observeCurrentForeground() {
        let app = workspace.frontmostApplication
        lastActivatedPID = app?.processIdentifier
        observeForeground(app)
    }

    private func observeForeground(_ app: NSRunningApplication?) {
        resetForegroundWindowObservation()
        guard let app, Self.isSupportedApplication(app) else {
            foregroundApplication = nil
            foregroundTimer?.invalidate()
            foregroundTimer = nil
            return
        }
        foregroundApplication = app
        if foregroundTimer == nil {
            foregroundTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.sampleForegroundWindow()
            }
        }
        sampleForegroundWindow()
    }

    private func resetForegroundWindowObservation() {
        sawForegroundWindow = false
        missingWindowSince = nil
    }

    private func sampleForegroundWindow() {
        guard let app = foregroundApplication, isStillFrontmost(app) else {
            resetForegroundWindowObservation()
            return
        }
        let now = uptime
        guard now - lastSpaceChange >= 0.45, let windows = Self.onScreenWindows() else {
            missingWindowSince = nil
            return
        }

        let pid = app.processIdentifier
        if windows.contains(where: { Self.normalWindowOwner($0) == pid }) {
            sawForegroundWindow = true
            missingWindowSince = nil
            cancelPending()
            return
        }

        guard sawForegroundWindow, app.isFinishedLaunching else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            missingWindowSince = nil
            return
        }
        guard let firstMissing = missingWindowSince else {
            missingWindowSince = now
            return
        }
        guard now - firstMissing >= 0.20 else { return }

        resetForegroundWindowObservation()
        handOffForeground(from: app, windows: windows)
    }

    private func handOffForeground(from source: NSRunningApplication, windows: [[String: Any]]) {
        let sourcePID = source.processIdentifier
        let visibleTarget = windows.lazy.compactMap(Self.normalWindowOwner)
            .filter { $0 != sourcePID }
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { Self.isSupportedApplication($0) && $0.isFinishedLaunching && !$0.isHidden }
        let target = visibleTarget ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first { $0.processIdentifier != sourcePID && !$0.isTerminated }
        guard let target, isStillFrontmost(source) else { return }

        let targetPID = target.processIdentifier
        // Consume the activation once so an empty Finder stays on the desktop.
        handoffActivation = (targetPID, uptime + 1.0)
        let accepted: Bool
        if #available(macOS 14.0, *) {
            accepted = target.activate(from: source, options: []) || target.activate(options: [])
        } else {
            accepted = target.activate(options: [])
        }
        if accepted {
            log.info("Requested foreground handoff from PID \(sourcePID, privacy: .public) to PID \(targetPID, privacy: .public)")
        } else {
            handoffActivation = nil
            log.info("Foreground handoff request declined")
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func schedule(
        _ app: NSRunningApplication, after delay: TimeInterval, deadline: TimeInterval,
        missingWindowSample: Bool
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.evaluate(app, deadline: deadline, missingWindowSample: missingWindowSample)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate(_ app: NSRunningApplication, deadline: TimeInterval, missingWindowSample: Bool) {
        let now = uptime
        guard now <= deadline, isStillFrontmost(app), NSEvent.pressedMouseButtons == 0 else { return }

        // A Space transition can briefly remove all normal windows from the list.
        let spaceSettleTime = lastSpaceChange + 0.30 - now
        if spaceSettleTime > 0 {
            schedule(app, after: spaceSettleTime, deadline: deadline, missingWindowSample: false)
            return
        }

        guard let windows = Self.onScreenWindows(), !windows.isEmpty else {
            log.debug("Window metadata unavailable")
            return
        }

        let pid = app.processIdentifier
        guard !windows.contains(where: { Self.normalWindowOwner($0) == pid }) else { return }
        if !missingWindowSample {
            schedule(app, after: 0.12, deadline: deadline, missingWindowSample: true)
            return
        }

        guard let url = app.bundleURL, let bundleID = app.bundleIdentifier,
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { !$0.isTerminated && $0.processIdentifier != pid }),
              isStillFrontmost(app) else { return }

        suppressUntil = suppressUntil.filter { $0.value > now }
        suppressUntil[pid] = now + 1.25
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        log.info("Requesting native reopen for PID \(pid, privacy: .public)")
        workspace.openApplication(at: url, configuration: configuration) { opened, error in
            if let error = error as NSError? {
                log.error("Native reopen error \(error.domain, privacy: .public)/\(error.code, privacy: .public)")
            } else if opened?.processIdentifier != pid {
                log.error("Native reopen did not return the original process")
            }
        }
    }

    private func isStillFrontmost(_ app: NSRunningApplication) -> Bool {
        sessionIsActive && !app.isTerminated && !app.isHidden && app.activationPolicy == .regular
            && workspace.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func isSupportedApplication(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, !app.isTerminated,
              let bundleID = app.bundleIdentifier?.lowercased() else { return false }
        return !excludedBundleIDs.contains(bundleID) && !bundleID.contains(".helper") && !bundleID.hasSuffix("helper")
    }

    private static func onScreenWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    private static func normalWindowOwner(_ window: [String: Any]) -> pid_t? {
        guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              (window[kCGWindowIsOnscreen as String] as? Bool) != false,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds),
              bounds.width >= 32, bounds.height >= 32 else { return nil }
        return owner
    }
}

if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
    print(version)
} else {
    let service = WindowReopen()
    withExtendedLifetime(service) { service.run() }
}
