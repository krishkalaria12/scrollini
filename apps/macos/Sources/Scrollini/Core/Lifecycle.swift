import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func runMainLoop() {
        guard statusItem != nil, Thread.isMainThread else {
            RunLoop.main.run()
            return
        }

        MainActor.assumeIsolated {
            NSApplication.shared.run()
        }
    }

    func makeMainTimer(
        deadline: DispatchTime,
        repeating interval: DispatchTimeInterval? = nil,
        leeway: DispatchTimeInterval = .milliseconds(2),
        handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        if let interval {
            timer.schedule(deadline: deadline, repeating: interval, leeway: leeway)
        } else {
            timer.schedule(deadline: deadline, leeway: leeway)
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    func cancelTimer(_ timer: inout DispatchSourceTimer?) {
        timer?.cancel()
        timer = nil
    }

    func scheduleRescanTimer() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: rescanInterval, repeats: true) { [weak self] _ in
            self?.handlePeriodicTick()
        }
    }

    func handlePeriodicTick() {
        ensureEventTapEnabled()
        guard !reloadConfigIfNeeded() else {
            return
        }
        let wasTransient = transientWindowActive
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        rescanWindowsIfChanged(adoptFocused: wasTransient)
    }
    func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        // Registered ahead of applicationActivated(_:) and kept separate from it: that handler
        // returns early in several cases, and the cache has to track every activation so per-app
        // keybinding exclusions never consult a stale frontmost app.
        center.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Resolution changes, display arrangement, Dock resizing, and menu bar auto-hide all
        // change the working area, and all of them post this. Anything the notification misses
        // is caught by the cache expiring on its own.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc func screenParametersChanged(_ notification: Notification) {
        invalidateViewportCache()
        clearAppliedLayoutCache()
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
    }

    @objc func frontmostApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            refreshFrontmostApplication()
            return
        }
        frontmostApplication = app
        frontmostAppBundleID = app.bundleIdentifier
        frontmostAppName = app.localizedName
        refreshGlobalHotkeysForFrontmostApp()
    }

    func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                // Unconditional, unlike the window restore below it: `AXEnhancedUserInterface`
                // belongs to the applications scrollini borrowed it from, and leaving it switched
                // off after exit would degrade them for the rest of their run.
                self?.restoreAllEnhancedUserInterface()
                if self?.restoreOnExit == true {
                    self?.restoreManagedWindowsForExit()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func startCleanupWatcher() {
        guard let executableURL = currentExecutableURL() else {
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--cleanup-watch",
            "\(ProcessInfo.processInfo.processIdentifier)",
            restoreStateURL.path,
        ]

        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        }

        do {
            try process.run()
            cleanupWatcher = process
        } catch {
            fputs("scrollini: failed to start cleanup watcher: \(error)\n", stderr)
        }
    }
    func updateCleanupWatcher(previousRestoreOnExit: Bool) {
        guard restoreOnExit != previousRestoreOnExit else {
            return
        }

        if restoreOnExit {
            startCleanupWatcher()
        } else {
            cleanupWatcher?.terminate()
            cleanupWatcher = nil
            try? FileManager.default.removeItem(at: restoreStateURL)
        }
    }
}
