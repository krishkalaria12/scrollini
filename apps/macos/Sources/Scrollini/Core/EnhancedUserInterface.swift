import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// AppKit's own name for the attribute. Not exported by any header, but stable since the
/// accessibility API grew window manipulation.
private let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

extension Scrollini {
    /// Takes an application out of enhanced-interface mode the first time scrollini moves one of
    /// its windows.
    ///
    /// AppKit turns the flag on for an app as soon as an accessibility client attaches, and with
    /// it on the app services a `kAXPosition` write by running an animated window move rather
    /// than placing the window. Scrolling the strip writes a position for every visible column on
    /// every frame, so those animations pile up behind each other and the strip trails the
    /// fingers by a visible margin. Clearing the flag is the standard remedy across macOS tiling
    /// window managers.
    ///
    /// Gated on an application rather than a window, done once, and only for applications whose
    /// windows are actually being placed: the two accessibility round trips it costs are paid on
    /// the first move and never again. Everything taken away here is handed back by
    /// `restoreEnhancedUserInterface(for:)` when the app quits or scrollini does.
    func prepareApplicationForLayout(_ pid: pid_t) {
        let now = CFAbsoluteTimeGetCurrent()
        guard disableEnhancedUserInterfaceEnabled,
              !enhancedUIHandledPIDs.contains(pid),
              now >= enhancedUIRetryAfterByPID[pid, default: 0]
        else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, enhancedUserInterfaceAttribute as CFString, &value) == .success else {
            // Apps can briefly return cannotComplete while their accessibility tree is starting.
            // Retry later without putting two failed AX calls into every animation frame.
            enhancedUIRetryAfterByPID[pid] = now + 1
            return
        }

        guard value as? Bool == true else {
            enhancedUIRetryAfterByPID.removeValue(forKey: pid)
            enhancedUIHandledPIDs.insert(pid)
            return
        }

        guard AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttribute as CFString, kCFBooleanFalse) == .success else {
            enhancedUIRetryAfterByPID[pid] = now + 1
            return
        }

        enhancedUIRetryAfterByPID.removeValue(forKey: pid)
        enhancedUIHandledPIDs.insert(pid)
        enhancedUIDisabledPIDs.insert(pid)
        debugLog("disabled AXEnhancedUserInterface for pid \(pid)")
    }

    func restoreEnhancedUserInterface(for pid: pid_t) {
        enhancedUIRetryAfterByPID.removeValue(forKey: pid)
        enhancedUIHandledPIDs.remove(pid)
        guard enhancedUIDisabledPIDs.remove(pid) != nil else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttribute as CFString, kCFBooleanTrue)
    }

    /// Hands the flag back to every application that still has it switched off. Called when
    /// scrollini exits, and when the setting itself is turned off mid-session.
    func restoreAllEnhancedUserInterface() {
        for pid in enhancedUIDisabledPIDs {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttribute as CFString, kCFBooleanTrue)
        }
        enhancedUIDisabledPIDs.removeAll()
        enhancedUIHandledPIDs.removeAll()
        enhancedUIRetryAfterByPID.removeAll()
    }
}
