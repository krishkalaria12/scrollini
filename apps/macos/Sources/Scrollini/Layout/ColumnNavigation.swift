import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func enqueueColumnNavigation(delta: Int) {
        guard delta != 0 else {
            return
        }

        pendingColumnNavigationDelta += delta
        let now = CFAbsoluteTimeGetCurrent()
        if pendingColumnNavigationStartedAt == 0 {
            pendingColumnNavigationStartedAt = now
        }
        let burstActive = columnNavigationInputBurstIsActive()
        let delay: DispatchTimeInterval = burstActive
            ? (now - pendingColumnNavigationStartedAt >= 0.11 ? .milliseconds(1) : .milliseconds(55))
            : .milliseconds(6)
        if let pendingColumnNavigationTimer {
            if burstActive {
                pendingColumnNavigationTimer.schedule(
                    deadline: .now() + delay,
                    leeway: .milliseconds(4)
                )
            }
            return
        }

        pendingColumnNavigationTimer = makeMainTimer(deadline: .now() + delay) { [weak self] in
            self?.flushPendingColumnNavigation()
        }
    }

    func flushPendingColumnNavigation() {
        cancelTimer(&pendingColumnNavigationTimer)
        pendingColumnNavigationStartedAt = 0

        let delta = pendingColumnNavigationDelta
        pendingColumnNavigationDelta = 0
        guard delta != 0 else {
            return
        }

        performColumnNavigation(by: delta)
    }

    func columnNavigationInputBurstIsActive() -> Bool {
        animationTimer != nil
            || pendingColumnNavigationProjectionState != nil
            || columnNavigationFocusTimer != nil
            || CFAbsoluteTimeGetCurrent() - lastColumnNavigationAt < 0.18
    }

    func scheduleColumnNavigationFocus(after delay: TimeInterval) {
        guard let window = activeWindow() else {
            cancelColumnNavigationFocus()
            return
        }

        cancelTimer(&columnNavigationFocusTimer)
        columnNavigationFocusGeneration &+= 1
        let generation = columnNavigationFocusGeneration
        let windowID = ObjectIdentifier(window)
        let focusDelay = max(delay, 0.02)
        markExpectedFocusedWindow(for: window, duration: focusDelay + 1.0)
        suppressFocusedWindowAdoption(for: focusDelay + 0.5)

        columnNavigationFocusTimer = makeMainTimer(
            deadline: .now() + focusDelay,
            leeway: .milliseconds(4)
        ) { [weak self] in
            self?.settleColumnNavigationFocus(windowID: windowID, generation: generation)
        }
    }

    func settleColumnNavigationFocus(windowID: ObjectIdentifier, generation: UInt64) {
        guard generation == columnNavigationFocusGeneration else {
            return
        }

        cancelTimer(&columnNavigationFocusTimer)
        guard pendingColumnNavigationProjectionState == nil
        else {
            scheduleColumnNavigationFocus(after: 0.025)
            return
        }

        guard let window = activeWindow(),
              ObjectIdentifier(window) == windowID
        else {
            return
        }

        guard animationTimer == nil else {
            scheduleColumnNavigationFocus(after: 0.025)
            return
        }

        focus(window, verify: true)
    }

    func cancelColumnNavigationFocus() {
        columnNavigationFocusGeneration &+= 1
        cancelTimer(&columnNavigationFocusTimer)
    }

    func flushColumnNavigationProjection(animated: Bool) {
        guard let previousState = pendingColumnNavigationProjectionState else {
            return
        }
        pendingColumnNavigationProjectionState = nil

        let targetState = captureLayoutState()
        let shouldAnimate = animated && (previousState != targetState || !presentationFrames.isEmpty)
        let duration = shouldAnimate ? columnNavigationRetargetAnimationDuration : 0
        projectLayout(
            focusActiveWindow: true,
            animated: shouldAnimate,
            from: previousState,
            animationDuration: duration,
            layoutLockDelay: 0.04,
            prefocusActiveWindow: true,
            snapshotTiming: .deferred,
            verifyActiveLayout: false
        )
        cancelColumnNavigationFocus()
    }
    func performColumnNavigation(by delta: Int) {
        guard !transientSystemWindowIsActive() else {
            return
        }

        clearTrackpadCamera()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false

        let now = CFAbsoluteTimeGetCurrent()
        let stepCount = abs(delta)
        let burstIsActive = columnNavigationBurstIsActive(at: now, stepCount: stepCount)
        let previousState = captureLayoutState()
        guard focusColumn(relativeOffset: delta) else {
            return
        }

        layoutVerificationGeneration &+= 1
        let newState = captureLayoutState()
        lastColumnNavigationAt = now
        lastColumnNavigationDirection = delta.signum()
        let duration = burstIsActive ? columnNavigationRetargetAnimationDuration : columnNavigationAnimationDuration
        markExpectedFocusedWindow(for: activeWindow(), duration: duration + 1.0)
        suppressFocusedWindowAdoption(for: duration + 0.5)
        debugLog("column navigation delta=\(delta) workspace=\(newState.activeWorkspace + 1) burst=\(burstIsActive)")

        if burstIsActive {
            if pendingColumnNavigationProjectionState == nil {
                pendingColumnNavigationProjectionState = previousState
            }
            suppressManualResizeNotifications(for: 0.25)
            flushColumnNavigationProjection(animated: true)
            return
        }

        projectLayout(
            focusActiveWindow: true,
            animated: previousState != newState,
            from: previousState,
            animationDuration: duration,
            layoutLockDelay: 0.04,
            prefocusActiveWindow: true,
            snapshotTiming: .deferred,
            verifyActiveLayout: false
        )
        cancelColumnNavigationFocus()
    }
    func columnNavigationBurstIsActive(at now: CFAbsoluteTime, stepCount: Int) -> Bool {
        if animationTimer != nil
            || pendingColumnNavigationProjectionState != nil
            || columnNavigationFocusTimer != nil
            || stepCount > 1
        {
            return true
        }

        guard now - lastColumnNavigationAt < 0.18 else {
            return false
        }

        return lastColumnNavigationDirection != 0
    }
}
