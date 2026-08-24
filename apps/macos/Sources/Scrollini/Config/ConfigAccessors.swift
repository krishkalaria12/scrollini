import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    var animationDuration: TimeInterval {
        TimeInterval(config.animationDurationMS ?? ScrolliniConfig.fallback.animationDurationMS ?? 240) / 1000
    }

    var keyboardAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? ScrolliniConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.keyboardAnimationMS ?? fallback) / 1000
    }

    var columnNavigationAnimationDuration: TimeInterval {
        min(
            keyboardAnimationDuration,
            max(keyboardAnimationDuration * 0.65, 0.12)
        )
    }

    var columnNavigationRetargetAnimationDuration: TimeInterval {
        min(columnNavigationAnimationDuration, max(keyboardAnimationDuration * 0.2, 0.045))
    }
    var hoverFocusAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? ScrolliniConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.hoverFocusAnimationMS ?? fallback) / 1000
    }

    var trackpadSettleAnimationDuration: TimeInterval {
        let milliseconds: Int
        if let navigationSpecific = config.trackpadNavigationSettleAnimationMS,
           navigationSpecific != (ScrolliniConfig.fallback.trackpadNavigationSettleAnimationMS ?? 240)
        {
            milliseconds = navigationSpecific
        } else {
            milliseconds = config.trackpadSettleAnimationMS
                ?? config.trackpadNavigationSettleAnimationMS
                ?? config.animationDurationMS
                ?? ScrolliniConfig.fallback.trackpadSettleAnimationMS
                ?? 240
        }
        return TimeInterval(milliseconds) / 1000
    }

    var moveColumnAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? ScrolliniConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.moveColumnAnimationMS ?? fallback) / 1000
    }

    var widthAnimationDuration: TimeInterval {
        let fallback = config.keyboardAnimationMS
            ?? config.animationDurationMS
            ?? ScrolliniConfig.fallback.widthAnimationMS
            ?? 280
        return TimeInterval(config.widthAnimationMS ?? fallback) / 1000
    }

    var animationCurve: AnimationCurve {
        config.animationCurve ?? ScrolliniConfig.fallback.animationCurve ?? .smooth
    }

    var hoverFocusEnabled: Bool {
        (config.hoverToFocus ?? ScrolliniConfig.fallback.hoverToFocus ?? true) && hoverFocusMode != .off
    }

    var hoverFocusDelay: TimeInterval {
        TimeInterval(config.hoverFocusDelayMS ?? ScrolliniConfig.fallback.hoverFocusDelayMS ?? 120) / 1000
    }

    var hoverFocusMaxScrollRatio: CGFloat {
        config.hoverFocusRequiresVisibleRatio
            ?? config.hoverFocusMaxScrollRatio
            ?? ScrolliniConfig.fallback.hoverFocusRequiresVisibleRatio
            ?? ScrolliniConfig.fallback.hoverFocusMaxScrollRatio
            ?? 0.15
    }

    var hoverFocusEdgeTriggerWidth: CGFloat {
        config.hoverFocusEdgeTriggerWidth ?? ScrolliniConfig.fallback.hoverFocusEdgeTriggerWidth ?? 8
    }

    var hoverFocusAfterTrackpad: TimeInterval {
        let milliseconds: Int
        if let navigationSpecific = config.trackpadNavigationHoverSuppressionMS,
           navigationSpecific != (ScrolliniConfig.fallback.trackpadNavigationHoverSuppressionMS ?? 280)
        {
            milliseconds = navigationSpecific
        } else {
            milliseconds = config.hoverFocusAfterTrackpadMS
                ?? config.trackpadNavigationHoverSuppressionMS
                ?? ScrolliniConfig.fallback.hoverFocusAfterTrackpadMS
                ?? 280
        }
        return TimeInterval(milliseconds) / 1000
    }

    var hoverFocusMode: HoverFocusMode {
        config.hoverFocusMode ?? ScrolliniConfig.fallback.hoverFocusMode ?? .edgeOrVisible
    }

    var workspaceAutoBackAndForth: Bool {
        config.workspaceAutoBackAndForth ?? ScrolliniConfig.fallback.workspaceAutoBackAndForth ?? true
    }

    var focusAlignment: FocusAlignment {
        if let focusAlignment = config.focusAlignment {
            return focusAlignment
        }
        if let centerFocusedColumn = config.centerFocusedColumn {
            return centerFocusedColumn ? .smart : .left
        }
        if let focusAlignment = ScrolliniConfig.fallback.focusAlignment {
            return focusAlignment
        }
        return (config.centerFocusedColumn ?? ScrolliniConfig.fallback.centerFocusedColumn ?? true) ? .smart : .left
    }

    var newWindowPosition: NewWindowPosition {
        config.newWindowPosition ?? ScrolliniConfig.fallback.newWindowPosition ?? .afterActive
    }

    var innerGap: CGFloat {
        config.innerGap ?? ScrolliniConfig.fallback.innerGap ?? 0
    }

    var outerGap: CGFloat {
        config.outerGap ?? ScrolliniConfig.fallback.outerGap ?? 0
    }

    var parkedSliverWidth: CGFloat {
        config.parkedSliverWidth ?? ScrolliniConfig.fallback.parkedSliverWidth ?? 1
    }

    var trackpadNavigationEnabled: Bool {
        config.trackpadNavigation ?? ScrolliniConfig.fallback.trackpadNavigation ?? true
    }

    var trackpadNavigationFingers: Int {
        config.trackpadNavigationFingers ?? ScrolliniConfig.fallback.trackpadNavigationFingers ?? 3
    }

    var trackpadNavigationSensitivity: CGFloat {
        config.trackpadNavigationSensitivity ?? ScrolliniConfig.fallback.trackpadNavigationSensitivity ?? 1.6
    }

    /// Vertical sensitivity. niri needs a quarter of the finger travel to change workspace that it
    /// needs to scroll one screen width of columns (`WORKSPACE_GESTURE_MOVEMENT` 300 against
    /// `VIEW_GESTURE_WORKING_AREA_MOVEMENT` 1200), which is what makes a swipe up feel like a flick
    /// rather than a haul. Defaults to that same 4:1 ratio against the horizontal sensitivity.
    var trackpadNavigationWorkspaceSensitivity: CGFloat {
        config.trackpadNavigationWorkspaceSensitivity
            ?? ScrolliniConfig.fallback.trackpadNavigationWorkspaceSensitivity
            ?? trackpadNavigationSensitivity * 4
    }

    /// How far a three-finger swipe travels before it commits to an axis, in trackpad-normalized
    /// units where `1.0` is the full width of the trackpad.
    var trackpadNavigationDirectionLockThreshold: CGFloat {
        config.trackpadNavigationDirectionLockThreshold
            ?? ScrolliniConfig.fallback.trackpadNavigationDirectionLockThreshold
            ?? 0.02
    }

    var trackpadNavigationDeceleration: CGFloat {
        config.trackpadNavigationDeceleration ?? ScrolliniConfig.fallback.trackpadNavigationDeceleration ?? 5.5
    }

    var trackpadNavigationMomentumMinVelocity: CGFloat {
        config.trackpadNavigationMomentumMinVelocity
            ?? ScrolliniConfig.fallback.trackpadNavigationMomentumMinVelocity
            ?? 80
    }

    var trackpadNavigationVelocityGain: CGFloat {
        config.trackpadNavigationVelocityGain ?? ScrolliniConfig.fallback.trackpadNavigationVelocityGain ?? 1.35
    }

    var trackpadNavigationSnap: TrackpadNavigationSnap {
        config.trackpadNavigationSnap ?? ScrolliniConfig.fallback.trackpadNavigationSnap ?? .nearestColumn
    }

    var trackpadNavigationInvertX: Bool {
        config.trackpadNavigationInvertX ?? ScrolliniConfig.fallback.trackpadNavigationInvertX ?? false
    }

    var trackpadNavigationInvertY: Bool {
        config.trackpadNavigationInvertY ?? ScrolliniConfig.fallback.trackpadNavigationInvertY ?? false
    }

    var trackpadNavigationSettings: TrackpadNavigationSettings {
        TrackpadNavigationSettings(
            enabled: trackpadNavigationEnabled,
            fingers: trackpadNavigationFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY,
            // Baked into the recognizer at construction, so a change has to restart it.
            directionLockThreshold: trackpadNavigationDirectionLockThreshold
        )
    }

    var widthPresetRatios: [CGFloat] {
        config.presetWidthRatios ?? ScrolliniConfig.fallback.presetWidthRatios ?? [0.5, 0.67, 0.8, 1.0]
    }

    var rescanInterval: TimeInterval {
        TimeInterval(config.rescanIntervalMS ?? ScrolliniConfig.fallback.rescanIntervalMS ?? 1000) / 1000
    }

    var restoreOnExit: Bool {
        config.restoreOnExit ?? ScrolliniConfig.fallback.restoreOnExit ?? true
    }

    var hideMethod: HideMethod {
        config.hideMethod ?? ScrolliniConfig.fallback.hideMethod ?? .skyLightAlpha
    }

    var debugLogging: Bool {
        config.debugLogging ?? ScrolliniConfig.fallback.debugLogging ?? false
    }
}
