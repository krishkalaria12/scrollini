import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension FocusAlignment: CaseIterable {
    static var allCases: [FocusAlignment] { [.left, .center, .smart] }

    var displayName: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .smart: "Smart"
        }
    }
}

extension NewWindowPosition: CaseIterable {
    static var allCases: [NewWindowPosition] { [.beforeActive, .afterActive, .end] }

    var displayName: String {
        switch self {
        case .beforeActive: "Before active"
        case .afterActive: "After active"
        case .end: "End"
        }
    }
}

extension HideMethod: CaseIterable {
    static var allCases: [HideMethod] { [.skyLightAlpha, .parkOnly] }

    var displayName: String {
        switch self {
        case .skyLightAlpha: "SkyLight alpha"
        case .parkOnly: "Park only"
        }
    }
}

extension AnimationCurve: CaseIterable {
    static var allCases: [AnimationCurve] { [.smooth, .snappy, .linear] }

    var displayName: String {
        switch self {
        case .smooth: "Smooth"
        case .snappy: "Snappy"
        case .linear: "Linear"
        }
    }
}

extension HoverFocusMode: CaseIterable {
    static var allCases: [HoverFocusMode] { [.off, .visibleOnly, .edgeOrVisible] }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .visibleOnly: "Visible only"
        case .edgeOrVisible: "Edge or visible"
        }
    }
}

extension TrackpadNavigationSnap: CaseIterable {
    static var allCases: [TrackpadNavigationSnap] { [.nearestColumn, .nearestVisible, .none] }

    var displayName: String {
        switch self {
        case .nearestColumn: "Nearest column"
        case .nearestVisible: "Nearest visible"
        case .none: "None"
        }
    }
}
