import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    @MainActor
    @objc func presentSettingsFromStatusItem() {
        presentSettingsView()
    }

    @MainActor
    func presentSettingsView() {
        if let settingsWindow {
            settingsWindow.contentView = makeSettingsContentView()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Settings"
        settingsWindow.titleVisibility = .visible
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titlebarSeparatorStyle = .none
        settingsWindow.toolbarStyle = .unified
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = makeSettingsContentView()
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = settingsWindow
    }

    @MainActor
    func makeSettingsContentView() -> NSView {
        NSHostingView(rootView: ScrolliniSettingsView(
            config: config,
            settingsURL: settingsURL,
            stateURL: persistentLayoutStateURL,
            onSave: { [weak self] config in
                self?.saveConfigFromSettingsWindow(config) ?? false
            },
            onRevealSettings: { [weak self] in
                self?.revealConfigFromStatusItem()
            },
            onRevealState: { [weak self] in
                self?.revealStateFromStatusItem()
            }
        ))
    }
    func ensureSettingsFileExists() -> URL? {
        let url = settingsURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try data.write(to: url, options: [.atomic])
            loadedConfig.sourceURL = url
            loadedConfig.sourceModificationDate = ScrolliniConfig.modificationDate(for: url)
            print("scrollini: created settings \(url.path)")
            return url
        } catch {
            fputs("scrollini: failed to create settings \(url.path): \(error)\n", stderr)
            return nil
        }
    }
}
