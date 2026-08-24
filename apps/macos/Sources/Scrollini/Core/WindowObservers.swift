import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func startObservingApp(pid: pid_t) {
        guard observers[pid] == nil else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            return
        }

        let notifications = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func stopObservingApp(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else {
            return
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func handleAXNotification(_ name: String, element: AXUIElement) {
        if transientSystemWindowIsActive(forceRefresh: true) {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        switch name {
        case kAXFocusedWindowChangedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard !reconcileExpectedFocusChange(pid: pid) else {
                return
            }
            guard !shouldSuppressFocusedWindowAdoption else {
                return
            }
            rescanWindows(adoptFocused: false)
            adoptFocusedWindow(pid: pid, respectFocusSuppression: true)
        case kAXCreatedNotification, kAXUIElementDestroyedNotification:
            scheduleRescan(after: 0.08, adoptFocused: true)
        case kAXWindowResizedNotification:
            guard let location = tiledWindowLocation(for: element) else {
                restoreFloatingVisibility(raise: true)
                return
            }
            guard location.workspaceIndex == activeWorkspace else {
                return
            }
            guard !manualResizeNotificationsSuppressed else {
                return
            }
            guard !systemFrameMatchesCurrentLayout(for: element) else {
                return
            }
            invalidateAppliedLayoutCache(for: element)

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                beginOrContinueManualResize(for: element)
            }
        case kAXWindowMovedNotification:
            if manualResizeNotificationsSuppressed, tiledWindow(for: element) != nil {
                return
            }
            if let location = tiledWindowLocation(for: element), location.workspaceIndex != activeWorkspace {
                return
            }
            guard !systemFrameMatchesCurrentLayout(for: element) else {
                return
            }
            invalidateAppliedLayoutCache(for: element)

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                guard let window = tiledWindow(for: element) else {
                    restoreFloatingVisibility(raise: true)
                    return
                }
                if frameWidthDiffersFromLayout(for: element) {
                    beginOrContinueManualResize(for: element)
                    return
                }
                if let frame = axFrame(of: element) {
                    presentationFrames[ObjectIdentifier(window)] = frame
                }
                projectLayout(focusActiveWindow: false)
            }
        default:
            break
        }
    }
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }

    let app = Unmanaged<Scrollini>.fromOpaque(refcon).takeUnretainedValue()
    app.handleAXNotification(notification as String, element: element)
}
