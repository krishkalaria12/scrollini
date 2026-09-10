import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    /// First value any matching rule sets for one setting. Rules resolve per setting rather than
    /// as a whole: a narrow rule that only pins `behavior` must not swallow the `workspace` a
    /// broader rule declares for the same window, which is what reading every field off
    /// `windowRules.first(where:)` used to do.
    func ruleValue<Value>(for window: ManagedWindow, _ field: (WindowRule) -> Value?) -> Value? {
        for rule in windowRules where rule.matches(window) {
            if let value = field(rule) {
                return value
            }
        }
        return nil
    }

    func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        return ruleValue(for: window, \.widthRatio)?.clampedWidthRatio ?? defaultWidthRatio
    }

    func behavior(for window: ManagedWindow) -> WindowBehavior {
        ruleValue(for: window, \.behavior) ?? .tile
    }

    func workspace(for window: ManagedWindow) -> Int? {
        ruleValue(for: window, \.workspace)
    }

    func openPosition(for window: ManagedWindow) -> NewWindowPosition {
        ruleValue(for: window, \.openPosition) ?? newWindowPosition
    }

    func hoverToFocusAllowed(for window: ManagedWindow) -> Bool {
        ruleValue(for: window, \.hoverToFocus) ?? true
    }

    var trackpadNavigationAllowedForActiveWindow: Bool {
        guard let window = activeWindow() else {
            return true
        }
        return ruleValue(for: window, \.trackpadNavigation) ?? true
    }
}
