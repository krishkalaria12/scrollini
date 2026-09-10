import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func installStatusItem() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.installStatusItem()
            }
            return
        }

        MainActor.assumeIsolated {
            installStatusItemOnMainActor()
        }
    }

    @MainActor
    func installStatusItemOnMainActor() {
        _ = NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = statusBarIcon() {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        item.button?.toolTip = "Scrollini"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItemOnMainActor()
    }

    func updateStatusItem() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItem()
            }
            return
        }

        MainActor.assumeIsolated {
            updateStatusItemOnMainActor()
        }
    }

    @MainActor
    func updateStatusItemOnMainActor() {
        guard let button = statusItem?.button else {
            return
        }

        button.title = button.image == nil ? "Scrollini" : ""
    }

    @MainActor
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    @MainActor
    func menuWillOpen(_ menu: NSMenu) {
        ScrolliniMenuItemFactory.refreshViewHeights(in: menu)
    }

    @MainActor
    func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.appearance = NSApp.effectiveAppearance

        let snapshot = statusMenuSnapshot
        menu.addItem(ScrolliniMenuItemFactory.makeItem(for: ScrolliniMenuHeaderView(snapshot: snapshot)))
        if snapshot.transientSystemDialogActive {
            menu.addItem(ScrolliniMenuItemFactory.makeItem(for: ScrolliniMenuBannerView(
                message: "System dialog is active. Scrollini is temporarily staying out of the way.",
                systemImage: "pause.circle"
            )))
        }
        if snapshot.keybindingsPaused {
            menu.addItem(ScrolliniMenuItemFactory.makeItem(for: ScrolliniMenuBannerView(
                message: "Keybindings are paused. Every shortcut goes straight to the focused app.",
                systemImage: "keyboard.badge.ellipsis"
            )))
        }
        menu.addItem(ScrolliniMenuItemFactory.makeItem(for: ScrolliniMenuDividerView()))

        addMenuItem(
            "Settings...",
            systemImage: "gearshape",
            action: #selector(presentSettingsFromStatusItem),
            to: menu
        )
        addMenuItem(
            "Reveal Settings in Finder",
            systemImage: "folder",
            action: #selector(revealConfigFromStatusItem),
            to: menu
        )
        addMenuItem(
            "Reveal Layout State",
            systemImage: "internaldrive",
            action: #selector(revealStateFromStatusItem),
            to: menu,
            enabled: FileManager.default.fileExists(atPath: persistentLayoutStateURL.path)
        )
        addMenuItem(
            "Donate to the Project",
            systemImage: "heart",
            action: #selector(openDonationFromStatusItem),
            to: menu
        )

        menu.addItem(ScrolliniMenuItemFactory.makeItem(for: ScrolliniMenuDividerView()))

        addMenuItem(
            "Reload Settings",
            systemImage: "arrow.clockwise",
            action: #selector(reloadConfigFromStatusItem),
            to: menu,
            enabled: FileManager.default.fileExists(atPath: settingsURL.path)
        )
        addMenuItem(
            "Reapply Layout",
            systemImage: "rectangle.3.group",
            action: #selector(reapplyLayoutFromStatusItem),
            to: menu
        )
        addMenuItem(
            snapshot.keybindingsPaused ? "Resume Keybindings" : "Pause Keybindings",
            systemImage: snapshot.keybindingsPaused ? "play.circle" : "pause.circle",
            action: #selector(toggleKeybindingsPausedFromStatusItem),
            to: menu
        )

        menu.addItem(ScrolliniMenuItemFactory.makeItem(for: ScrolliniMenuDividerView()))
        addMenuItem("Quit Scrollini", systemImage: "power", action: #selector(quitFromStatusItem), to: menu)
        ScrolliniMenuItemFactory.refreshViewHeights(in: menu)
    }

    var statusMenuSnapshot: ScrolliniMenuSnapshot {
        let workspace = activeWorkspaceObject()
        let activeWindow: ManagedWindow?
        if let workspace, !workspace.columns.isEmpty {
            workspace.clampFocus()
            activeWindow = workspace.columns[workspace.activeColumn]
        } else {
            activeWindow = nil
        }

        return ScrolliniMenuSnapshot(
            workspaceIndex: activeWorkspace + 1,
            columnIndex: activeWindow == nil ? nil : (workspace?.activeColumn ?? 0) + 1,
            columnCount: workspace?.columns.count ?? 0,
            activeAppName: activeWindow?.appName ?? "No tiled window",
            settingsPath: abbreviatedPath(settingsURL),
            layoutStatePath: persistLayoutEnabled ? abbreviatedPath(persistentLayoutStateURL) : nil,
            layoutStateExists: FileManager.default.fileExists(atPath: persistentLayoutStateURL.path),
            transientSystemDialogActive: transientWindowActive,
            keybindingsPaused: keybindingsPaused
        )
    }

    var settingsURL: URL {
        if let sourceURL = loadedConfig.sourceURL {
            return sourceURL
        }

        if let path = ProcessInfo.processInfo.environment["SCROLLINI_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }

        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return xdgConfig.appendingPathComponent("scrollini/config.json")
    }

    func abbreviatedPath(_ url: URL) -> String {
        NSString(string: url.path).abbreviatingWithTildeInPath
    }

    func addMenuItem(
        _ title: String,
        systemImage: String,
        action: Selector,
        to menu: NSMenu,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = menuImage(systemImage, description: title)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    func statusBarIcon() -> NSImage? {
        for name in ["rectangle.3.group", "square.grid.2x2", "rectangle.grid.1x2"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Scrollini") {
                return image
            }
        }
        return nil
    }

    func menuImage(_ systemName: String, description: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: description) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    @objc func revealConfigFromStatusItem() {
        guard let url = ensureSettingsFileExists() else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func revealStateFromStatusItem() {
        let url = persistentLayoutStateURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openDonationFromStatusItem() {
        guard let url = URL(string: "https://ko-fi.com/krishkalaria12") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func reloadConfigFromStatusItem() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            NSSound.beep()
            return
        }

        loadedConfig.sourceModificationDate = nil
        guard reloadConfigIfNeeded() else {
            NSSound.beep()
            return
        }
        updateStatusItem()
    }
    @objc func reapplyLayoutFromStatusItem() {
        cancelHoverFocus()
        clearTrackpadCamera()
        clearAppliedLayoutCache()
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
        updateStatusItem()
    }

    /// Paused only means scrollini stops claiming keystrokes. The strip keeps its layout and the
    /// trackpad keeps working, so this is the escape hatch for a chord fighting the focused app,
    /// not a way to hand every window back.
    @objc func toggleKeybindingsPausedFromStatusItem() {
        setKeybindingsPaused(!keybindingsPaused)
    }

    @objc func quitFromStatusItem() {
        restoreManagedWindowsForExit()
        exit(0)
    }
}
