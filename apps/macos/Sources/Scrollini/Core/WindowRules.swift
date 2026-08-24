import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        for rule in config.rules where rule.matches(window) {
            if let widthRatio = rule.widthRatio {
                return widthRatio.clampedWidthRatio
            }
        }
        return config.defaultWidthRatio.clampedWidthRatio
    }

    func behavior(for window: ManagedWindow) -> WindowBehavior {
        for rule in config.rules where rule.matches(window) {
            if let behavior = rule.behavior {
                return behavior
            }
        }
        return .tile
    }

    func rule(for window: ManagedWindow) -> WindowRule? {
        config.rules.first { $0.matches(window) }
    }

    func hoverToFocusAllowed(for window: ManagedWindow) -> Bool {
        rule(for: window)?.hoverToFocus ?? true
    }

    var trackpadNavigationAllowedForActiveWindow: Bool {
        guard let window = activeWindow() else {
            return true
        }
        return rule(for: window)?.trackpadNavigation ?? true
    }
}
