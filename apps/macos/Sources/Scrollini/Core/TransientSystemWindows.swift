import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func transientSystemWindowIsActive(forceRefresh: Bool = false) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if !forceRefresh, now - transientWindowStateCheckedAt < 0.25 {
            return transientWindowActive
        }

        transientWindowStateCheckedAt = now
        let activeTransientWindows = transientSystemWindows()
        recoverTransientSystemWindows(activeTransientWindows)
        transientWindowActive = !activeTransientWindows.isEmpty
        return transientWindowActive
    }

    func transientSystemWindows() -> [TransientSystemWindow] {
        transientCheckApplications.compactMap { app in
            if let window = focusedWindow(for: app),
               isTransientSystemWindow(window, app: app) {
                return TransientSystemWindow(element: window, recoverable: true)
            }

            guard let focusedElement = focusedUIElement(for: app),
                  isTransientFocusedElement(focusedElement, app: app)
            else {
                return nil
            }
            return TransientSystemWindow(element: focusedElement, recoverable: false)
        }
    }

    @discardableResult
    func recoverTransientSystemWindows(_ windows: [TransientSystemWindow]) -> Bool {
        guard !windows.isEmpty else {
            return false
        }

        let viewport = currentViewport()
        var moved = false
        for transient in windows {
            guard transient.recoverable else {
                continue
            }
            setWindowAlpha(1, for: SkyLight.shared.windowID(for: transient.element))
            if let frame = axFrame(of: transient.element), transientFrameNeedsRecovery(frame, viewport: viewport) {
                setAXPosition(centeredOrigin(for: frame, in: viewport), for: transient.element)
                moved = true
            }
            AXUIElementPerformAction(transient.element, kAXRaiseAction as CFString)
        }
        return moved
    }

    func transientFrameNeedsRecovery(_ frame: CGRect, viewport: CGRect) -> Bool {
        !frame.intersects(viewport)
            || frame.midX < viewport.minX
            || frame.midX > viewport.maxX
            || frame.midY < viewport.minY
            || frame.midY > viewport.maxY
    }

    func centeredOrigin(for frame: CGRect, in viewport: CGRect) -> CGPoint {
        CGPoint(
            x: viewport.midX - frame.width / 2,
            y: viewport.midY - frame.height / 2
        )
    }

    var transientCheckApplications: [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        // Tracked from the activation notification rather than read back off NSWorkspace: this
        // property is reached from the event tap, which handles every keystroke and every pointer
        // move, and each of those reads was a cross-process lookup.
        if let frontmostApplication {
            apps.append(frontmostApplication)
        }
        for app in runningApplications() where app.isActive {
            if !apps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                apps.append(app)
            }
        }
        for panelService in openAndSavePanelServices(matchingAnyHostIn: apps) {
            if !apps.contains(where: { $0.processIdentifier == panelService.processIdentifier }) {
                apps.append(panelService)
            }
        }
        return apps
    }

    func openAndSavePanelServices(matchingAnyHostIn hosts: [NSRunningApplication]) -> [NSRunningApplication] {
        let hostNames = hosts.compactMap(\.localizedName)
        guard !hostNames.isEmpty else {
            return []
        }

        return runningApplications().filter { app in
            guard isOpenAndSavePanelService(app),
                  let name = app.localizedName
            else {
                return false
            }
            return hostNames.contains { name.contains("(\($0))") }
        }
    }

    func isOpenAndSavePanelService(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
    }

    func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success else {
            return nil
        }
        return asAXUIElement(value)
    }

    func focusedUIElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success else {
            return nil
        }
        return asAXUIElement(value)
    }

    func isTransientSystemWindow(_ element: AXUIElement, app: NSRunningApplication) -> Bool {
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        if isTransientRole(role) {
            return true
        }
        if isTransientSubrole(subrole) {
            return true
        }
        return isOpenAndSavePanelService(app)
    }

    func isTransientFocusedElement(_ element: AXUIElement, app: NSRunningApplication) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else {
                break
            }

            if isTransientSystemWindow(candidate, app: app) {
                return true
            }

            current = axElement(candidate, kAXParentAttribute)
        }

        return false
    }

    func isTransientRole(_ role: String?) -> Bool {
        switch role {
        case kAXSheetRole, "AXSheet", "AXDialog", "AXMenu", "AXMenuItem", "AXPopover":
            return true
        default:
            return false
        }
    }

    func isTransientSubrole(_ subrole: String?) -> Bool {
        switch subrole {
        case "AXSystemDialog", "AXDialog", "AXPopover", "AXMenu":
            return true
        default:
            return false
        }
    }
}
