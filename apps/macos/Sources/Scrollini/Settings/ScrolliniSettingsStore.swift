import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

import AppKit
import SwiftUI

@MainActor
final class ScrolliniSettingsStore: ObservableObject {
    @Published var config: ScrolliniConfig
    @Published var presetRatios: [CGFloat]
    @Published var statePathText: String
    @Published var errorMessage: String?
    @Published var savedMessage: String?

    let settingsURL: URL
    let stateURL: URL
    private let onSave: (ScrolliniConfig) -> Bool
    private let onRevealSettings: () -> Void
    private let onRevealState: () -> Void
    private var pendingSave: DispatchWorkItem?

    init(
        config: ScrolliniConfig,
        settingsURL: URL,
        stateURL: URL,
        onSave: @escaping (ScrolliniConfig) -> Bool,
        onRevealSettings: @escaping () -> Void,
        onRevealState: @escaping () -> Void
    ) {
        self.config = config
        self.settingsURL = settingsURL
        self.stateURL = stateURL
        self.onSave = onSave
        self.onRevealSettings = onRevealSettings
        self.onRevealState = onRevealState
        presetRatios = ScrolliniSettingsStore.normalizedPresets(
            config.presetWidthRatios ?? ScrolliniConfig.fallback.presetWidthRatios ?? []
        )
        statePathText = config.statePath ?? ""
    }

    func save() {
        pendingSave?.cancel()
        var next = config
        next.presetWidthRatios = normalizedPresetRatios()
        next.statePath = statePathText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        guard errorMessage == nil else {
            NSSound.beep()
            return
        }

        if onSave(next) {
            config = next
            savedMessage = "Saved and applied"
        } else {
            savedMessage = nil
            errorMessage = "Could not save settings."
            NSSound.beep()
        }
    }

    func scheduleSave() {
        pendingSave?.cancel()
        savedMessage = nil

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.save()
            }
        }
        pendingSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    func revealSettings() {
        onRevealSettings()
    }

    func revealState() {
        onRevealState()
    }

    func addPreset() {
        let next = min((presetRatios.last ?? config.defaultWidthRatio) + 0.1, 2.0)
        presetRatios.append(next.clampedManualWidthRatio)
        scheduleSave()
    }

    func removePreset(at index: Int) {
        guard presetRatios.indices.contains(index), presetRatios.count > 1 else {
            NSSound.beep()
            return
        }
        presetRatios.remove(at: index)
        scheduleSave()
    }

    func presetBinding(at index: Int) -> Binding<CGFloat> {
        Binding(
            get: {
                guard self.presetRatios.indices.contains(index) else {
                    return self.config.defaultWidthRatio
                }
                return self.presetRatios[index]
            },
            set: { newValue in
                guard self.presetRatios.indices.contains(index) else {
                    return
                }
                self.presetRatios[index] = newValue.clampedManualWidthRatio
                self.scheduleSave()
            }
        )
    }

    private func normalizedPresetRatios() -> [CGFloat]? {
        let normalized = Self.normalizedPresets(presetRatios)
        guard !normalized.isEmpty else {
            errorMessage = "Add at least one width preset."
            return nil
        }
        errorMessage = nil
        return normalized
    }

    private static func normalizedPresets(_ presets: [CGFloat]) -> [CGFloat] {
        let sorted = presets
            .filter(\.isFinite)
            .map(\.clampedManualWidthRatio)
            .sorted()
        var unique: [CGFloat] = []
        for preset in sorted where unique.last.map({ abs($0 - preset) >= 0.005 }) ?? true {
            unique.append(preset)
        }
        return unique
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
