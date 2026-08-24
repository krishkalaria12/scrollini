import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func requestFocus(_ window: ManagedWindow, verify: Bool, delay: TimeInterval) {
        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        let windowID = ObjectIdentifier(window)

        guard delay > 0 else {
            focus(window, verify: verify)
            return
        }

        suppressFocusedWindowAdoption(for: delay + 0.35)
        markExpectedFocusedWindow(for: window, duration: delay + 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == focusRequestGeneration,
                  let active = activeWindow(),
                  ObjectIdentifier(active) == windowID,
                  animationTimer == nil
            else {
                return
            }

            focus(active, verify: verify)
        }
    }

    func focus(_ window: ManagedWindow, verify: Bool = true, reveal: Bool = true) {
        focusRequestGeneration &+= 1
        suppressFocusedWindowAdoption(for: 0.25)
        markExpectedFocusedWindow(for: window, duration: 1.0)
        if reveal {
            setWindowAlpha(1, for: window.windowID)
        }
        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        restoreFloatingVisibility(raise: true, deferred: true)
        if verify {
            scheduleFocusVerification(for: window)
        }
    }

    func scheduleFocusVerification(for window: ManagedWindow) {
        focusVerificationGeneration &+= 1
        let generation = focusVerificationGeneration
        let windowID = ObjectIdentifier(window)
        for delay in [0.02, 0.08, 0.18, 0.36] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.verifyFocusedWindow(windowID: windowID, generation: generation)
            }
        }
    }

    func verifyFocusedWindow(windowID: ObjectIdentifier, generation: UInt64) {
        guard generation == focusVerificationGeneration,
              let window = activeWindow(),
              ObjectIdentifier(window) == windowID,
              animationTimer == nil
        else {
            return
        }

        let focusIsCorrect = isSystemFocused(window)
        let frameIsCorrect = activeWindowFrameMatchesLayout(window)
        guard focusIsCorrect, frameIsCorrect else {
            debugLog("reapplying active layout focusOK=\(focusIsCorrect) frameOK=\(frameIsCorrect)")
            reapplyCurrentLayout(focusActiveWindow: true, verifyFocus: false)
            return
        }

        settleExpectedFocusedWindow(if: window)
    }
    func confirmExpectedFocusedWindowIfNeeded(_ window: ManagedWindow) -> Bool {
        guard isSystemFocused(window) else {
            return false
        }

        if activeWindowFrameMatchesLayout(window) {
            settleExpectedFocusedWindow(if: window)
            return true
        }

        return false
    }

    func reconcileExpectedFocusChange(pid: pid_t) -> Bool {
        guard let expectedID = expectedFocusedWindowID(),
              let expectedWindow = activeWindow(),
              ObjectIdentifier(expectedWindow) == expectedID
        else {
            return false
        }

        if focusChangeLooksUserInitiated(pid: pid, expectedWindow: expectedWindow) {
            releaseExpectedFocusedWindow()
            return false
        }

        guard !isApplyingLayout, animationTimer == nil else {
            debugLog("ignoring focus drift during column animation")
            return true
        }

        if pid == expectedWindow.pid, confirmExpectedFocusedWindowIfNeeded(expectedWindow) {
            return true
        }

        debugLog("ignoring focus drift while targeting \(expectedWindow.appName)")
        focus(expectedWindow, verify: false)
        return true
    }

    func focusChangeLooksUserInitiated(pid: pid_t, expectedWindow: ManagedWindow) -> Bool {
        guard !isApplyingLayout, animationTimer == nil else {
            return false
        }

        guard pid == expectedWindow.pid else {
            return true
        }

        guard let app = NSRunningApplication(processIdentifier: pid),
              let focused = focusedWindow(for: app)
        else {
            return false
        }

        if sameWindow(expectedWindow.element, focused) {
            return false
        }

        return true
    }

    func isSystemFocused(_ window: ManagedWindow) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              let app = NSRunningApplication(processIdentifier: window.pid),
              let focused = focusedWindow(for: app)
        else {
            return false
        }

        return sameWindow(window.element, focused)
    }
}
