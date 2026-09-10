import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    var shouldSuppressFocusedWindowAdoption: Bool {
        isApplyingLayout
            || animationTimer != nil
            || expectedFocusedWindowID() != nil
            || CFAbsoluteTimeGetCurrent() < focusedWindowAdoptionSuppressedUntil
    }

    func suppressFocusedWindowAdoption(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }

        let until = CFAbsoluteTimeGetCurrent() + duration
        focusedWindowAdoptionSuppressedUntil = max(focusedWindowAdoptionSuppressedUntil, until)
    }

    func markExpectedFocusedWindow(for window: ManagedWindow?, duration: TimeInterval) {
        guard let window else {
            expectedFocusedWindow = nil
            expectedFocusedWindowUntil = 0
            return
        }

        // Extending the deadline only makes sense while the target is unchanged. Carrying a long
        // deadline over to a different window pinned focus to the new one for however long the
        // previous request had left, which outlasted the layout change that asked for it.
        let deadline = CFAbsoluteTimeGetCurrent() + max(duration, 0.25)
        let id = ObjectIdentifier(window)
        expectedFocusedWindowUntil = expectedFocusedWindow == id
            ? max(expectedFocusedWindowUntil, deadline)
            : deadline
        expectedFocusedWindow = id
    }

    func expectedFocusedWindowID() -> ObjectIdentifier? {
        guard let expectedFocusedWindow else {
            return nil
        }

        guard CFAbsoluteTimeGetCurrent() <= expectedFocusedWindowUntil else {
            self.expectedFocusedWindow = nil
            expectedFocusedWindowUntil = 0
            return nil
        }

        return expectedFocusedWindow
    }

    func settleExpectedFocusedWindow(if window: ManagedWindow) {
        guard expectedFocusedWindow == ObjectIdentifier(window) else {
            return
        }

        releaseExpectedFocusedWindow()
    }

    func releaseExpectedFocusedWindow() {
        focusRequestGeneration &+= 1
        focusVerificationGeneration &+= 1
        cancelColumnNavigationFocus()
        cancelHoverFocus()
        expectedFocusedWindow = nil
        expectedFocusedWindowUntil = 0
        focusedWindowAdoptionSuppressedUntil = 0
    }
}
