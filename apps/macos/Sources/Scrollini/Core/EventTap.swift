import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = makeEventTap(location: .cghidEventTap, mask: mask, refcon: refcon)
            ?? makeEventTap(location: .cgSessionEventTap, mask: mask, refcon: refcon)
        else {
            fputs("scrollini: unable to create event tap. Check Accessibility/Input Monitoring permissions.\n", stderr)
            exit(1)
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("scrollini: unable to create event tap run loop source.\n", stderr)
            exit(1)
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func makeEventTap(
        location: CGEventTapLocation,
        mask: CGEventMask,
        refcon: UnsafeMutableRawPointer
    ) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        )
    }

    func reenableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }
    func configureInput() {
        commandByKeybinding = makeCommandByKeybinding()
        excludedKeybindingSet = Set((config.excludedKeybindings ?? ScrolliniConfig.fallback.excludedKeybindings ?? [])
            .compactMap(normalizedKeybinding(_:)))
        appKeybindingExclusions = makeAppKeybindingExclusions()
        refreshFrontmostApplication()
    }

    func makeAppKeybindingExclusions() -> [AppKeybindingExclusion] {
        windowRules.compactMap { rule in
            guard let bindings = rule.excludedKeybindings, !bindings.isEmpty else {
                return nil
            }
            guard rule.bundleID != nil || rule.appName != nil else {
                fputs("scrollini: ignoring rule excluded_keybindings without a bundle_id or app_name\n", stderr)
                return nil
            }

            let chords = Set(bindings.compactMap(normalizedKeybinding(_:)))
            guard !chords.isEmpty else {
                return nil
            }
            return AppKeybindingExclusion(bundleID: rule.bundleID, appName: rule.appName, chords: chords)
        }
    }

    func refreshFrontmostApplication() {
        let app = NSWorkspace.shared.frontmostApplication
        frontmostAppBundleID = app?.bundleIdentifier
        frontmostAppName = app?.localizedName
    }

    func setKeybindingsPaused(_ paused: Bool) {
        guard keybindingsPaused != paused else {
            return
        }
        keybindingsPaused = paused
        if paused {
            flushPendingColumnNavigation()
            flushColumnNavigationProjection(animated: false)
            cancelColumnNavigationFocus()
        }
        updateStatusItem()
    }

    func handleKeyEvent(_ event: CGEvent, type: CGEventType) -> Bool {
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            return swallowedKeyUps.remove(keyCode) != nil
        }
        swallowedKeyUps.remove(keyCode)

        guard !keybindingsPaused else {
            return false
        }

        guard !transientSystemWindowIsActive() else {
            return false
        }

        let keyText = keyboardText(from: event)
        if isSystemWindowSwitcherEvent(modifiers: modifiers, keyCode: keyCode, keyText: keyText) {
            releaseExpectedFocusedWindow()
        }

        guard !isExcludedKeybinding(modifiers: modifiers, keyCode: keyCode, keyText: keyText) else {
            return false
        }

        guard let command = commandForKeyEvent(modifiers: modifiers, keyCode: keyCode, keyText: keyText) else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            self?.handle(command)
        }
        swallowedKeyUps.insert(keyCode)
        return true
    }

    func isSystemWindowSwitcherEvent(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> Bool {
        modifiers.contains(.maskCommand)
            && normalizedKeyNames(keyCode: keyCode, keyText: keyText, includeFnNavigationAliases: false).contains("tab")
    }

    func handle(_ command: Command) {
        switch command {
        case .columnLeft:
            enqueueColumnNavigation(delta: -1)
        case .columnRight:
            enqueueColumnNavigation(delta: 1)
        default:
            flushPendingColumnNavigation()
            flushColumnNavigationProjection(animated: false)
            cancelColumnNavigationFocus()
            perform(command)
        }
    }
}

private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<Scrollini>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.reenableEventTap()
        return nil
    }

    guard type == .keyDown || type == .keyUp || type == .mouseMoved else {
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        app.handleMouseMoved(event)
        return Unmanaged.passUnretained(event)
    }

    if app.handleKeyEvent(event, type: type) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
