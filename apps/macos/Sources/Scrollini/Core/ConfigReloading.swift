import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    @discardableResult
    func reloadConfigIfNeeded() -> Bool {
        let previousSourceURL = loadedConfig.sourceURL
        let previousModificationDate = loadedConfig.sourceModificationDate

        if let previousSourceURL {
            let currentModificationDate = ScrolliniConfig.modificationDate(for: previousSourceURL)
            guard currentModificationDate != previousModificationDate else {
                return false
            }

            loadedConfig.sourceModificationDate = currentModificationDate
        }

        return reloadConfigFromDisk(previousSourceURL: previousSourceURL)
    }

    @discardableResult
    func reloadConfigFromDisk(previousSourceURL: URL?) -> Bool {
        guard let previousSourceURL else {
            let reloaded = ScrolliniConfig.loadWithMetadata(
                logLoaded: false,
                logErrors: !configLoadErrorsSuppressed
            )
            guard reloaded.sourceURL != nil else {
                // This path is polled once per rescan with no modification-date guard to gate it,
                // so a config that never parses would otherwise write its error to stderr at 1 Hz
                // for the life of the process. Say it once, then wait for something to change.
                configLoadErrorsSuppressed = true
                return false
            }

            configLoadErrorsSuppressed = false
            applyLoadedConfig(reloaded)
            let sourcePath = loadedConfig.sourceURL?.path ?? "fallback"
            print("scrollini: reloaded config \(sourcePath), \(commandByKeybinding.count) keybindings")
            return true
        }

        let reloaded: LoadedScrolliniConfig
        switch ScrolliniConfig.load(from: previousSourceURL, logLoaded: false) {
        case let .loaded(loaded) where loaded.sourceURL == previousSourceURL:
            reloaded = loaded
        case .loaded, .notFound, .parseError:
            fputs("scrollini: config reload skipped; keeping previous config\n", stderr)
            return false
        }

        applyLoadedConfig(reloaded)
        let sourcePath = loadedConfig.sourceURL?.path ?? "fallback"
        print("scrollini: reloaded config \(sourcePath), \(commandByKeybinding.count) keybindings")
        return true
    }

    @discardableResult
    func saveConfigFromSettingsWindow(_ newConfig: ScrolliniConfig) -> Bool {
        let url = settingsURL

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(newConfig)
            try data.write(to: url, options: [.atomic])

            applyLoadedConfig(LoadedScrolliniConfig(
                config: ScrolliniConfig.normalize(newConfig),
                sourceURL: url,
                sourceModificationDate: ScrolliniConfig.modificationDate(for: url)
            ))
            updateStatusItem()

            print("scrollini: saved settings \(url.path)")
            return true
        } catch {
            fputs("scrollini: failed to save settings \(url.path): \(error)\n", stderr)
            return false
        }
    }

    func applyLoadedConfig(_ newLoadedConfig: LoadedScrolliniConfig) {
        let previousRescanInterval = rescanInterval
        let previousRestoreOnExit = restoreOnExit
        let previousTrackpadSettings = trackpadNavigationSettings

        loadedConfig = newLoadedConfig
        configureInput()

        if !disableEnhancedUserInterfaceEnabled {
            restoreAllEnhancedUserInterface()
        }

        if trackpadNavigationSettings != previousTrackpadSettings {
            restartTrackpadNavigation()
        }
        if rescanInterval != previousRescanInterval {
            scheduleRescanTimer()
        }
        updateCleanupWatcher(previousRestoreOnExit: previousRestoreOnExit)
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
    }
}
