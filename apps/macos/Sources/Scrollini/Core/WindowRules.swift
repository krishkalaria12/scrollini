import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    /// Every rule-backed setting for one window, resolved in a single pass over the rules and
    /// held until the window's identity or the config changes. Settings resolve independently: a
    /// narrow rule that only pins `behavior` must not swallow the `workspace` a broader rule
    /// declares for the same window, which is what reading every field off
    /// `windowRules.first(where:)` used to do.
    func resolvedRules(for window: ManagedWindow) -> ResolvedWindowRules {
        if let cached = window.resolvedRules, window.resolvedRulesRevision == windowRuleRevision {
            return cached
        }

        var resolved = ResolvedWindowRules()
        for rule in windowRules where rule.matches(window) {
            resolved.widthRatio = resolved.widthRatio ?? rule.widthRatio
            resolved.behavior = resolved.behavior ?? rule.behavior
            resolved.workspace = resolved.workspace ?? rule.workspace
            resolved.openPosition = resolved.openPosition ?? rule.openPosition
            resolved.hoverToFocus = resolved.hoverToFocus ?? rule.hoverToFocus
            resolved.trackpadNavigation = resolved.trackpadNavigation ?? rule.trackpadNavigation
        }

        window.resolvedRules = resolved
        window.resolvedRulesRevision = windowRuleRevision
        return resolved
    }

    func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        return resolvedRules(for: window).widthRatio?.clampedWidthRatio ?? defaultWidthRatio
    }

    func behavior(for window: ManagedWindow) -> WindowBehavior {
        resolvedRules(for: window).behavior ?? .tile
    }

    func workspace(for window: ManagedWindow) -> Int? {
        resolvedRules(for: window).workspace
    }

    func openPosition(for window: ManagedWindow) -> NewWindowPosition {
        resolvedRules(for: window).openPosition ?? newWindowPosition
    }

    func hoverToFocusAllowed(for window: ManagedWindow) -> Bool {
        resolvedRules(for: window).hoverToFocus ?? true
    }

    var trackpadNavigationAllowedForActiveWindow: Bool {
        guard let window = activeWindow() else {
            return true
        }
        return resolvedRules(for: window).trackpadNavigation ?? true
    }
}
