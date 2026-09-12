import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

private enum ScrolliniSettingsPane: String, CaseIterable, Identifiable {
    case general
    case navigation
    case motion
    case files
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .navigation: "Navigation"
        case .motion: "Motion"
        case .files: "Files"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .navigation: "hand.draw"
        case .motion: "waveform.path"
        case .files: "folder"
        case .advanced: "gearshape.2"
        }
    }
}

struct ScrolliniSettingsView: View {
    @StateObject private var store: ScrolliniSettingsStore
    @State private var selection: ScrolliniSettingsPane = .general

    init(
        config: ScrolliniConfig,
        settingsURL: URL,
        stateURL: URL,
        onSave: @escaping (ScrolliniConfig) -> Bool,
        onRevealSettings: @escaping () -> Void,
        onRevealState: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: ScrolliniSettingsStore(
            config: config,
            settingsURL: settingsURL,
            stateURL: stateURL,
            onSave: onSave,
            onRevealSettings: onRevealSettings,
            onRevealState: onRevealState
        ))
    }

    var body: some View {
        NavigationSplitView {
            List(ScrolliniSettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
            }
            .navigationTitle("Scrollini")
            .frame(minWidth: 170)
        } detail: {
            VStack(spacing: 0) {
                header
                Form {
                    selectedSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(selection.title)
                .font(.title3.weight(.semibold))

            Spacer(minLength: 12)
            statusMessage
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 0)
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch selection {
        case .general:
            layoutSection
            behaviorSection
        case .navigation:
            hoverSection
            trackpadSection
        case .motion:
            animationSection
        case .files:
            persistenceSection
        case .advanced:
            advancedSection
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let errorMessage = store.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else if let savedMessage = store.savedMessage {
            Text(savedMessage)
                .foregroundStyle(.secondary)
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default width")
                    Spacer()
                    Text("\(Int(store.resolvedDefaultWidthRatio * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: optionalCGFloatBinding(
                        \.defaultWidthRatio,
                        fallback: ScrolliniConfig.fallback.defaultWidthRatio ?? 0.8
                    ),
                    in: 0.2 ... 2.0,
                    step: 0.05
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Width presets")
                ForEach(Array(store.presetRatios.indices), id: \.self) { index in
                    HStack(spacing: 12) {
                        Text(String(format: "%.2f", store.presetRatios[index]))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .leading)
                        Slider(value: store.presetBinding(at: index), in: 0.05 ... 2.0, step: 0.01)
                        Button("Remove") {
                            store.removePreset(at: index)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.presetRatios.count <= 1)
                    }
                }
                Button("Add Preset", action: store.addPreset)
                    .buttonStyle(.borderless)
                Text("Ratios used by width cycling commands.").settingsCaption()
            }

            numericSlider(
                title: "Inner gap",
                value: optionalCGFloatBinding(\.innerGap, fallback: ScrolliniConfig.fallback.innerGap ?? 0),
                range: 0 ... 96,
                suffix: "pt"
            )
            numericSlider(
                title: "Outer gap",
                value: optionalCGFloatBinding(\.outerGap, fallback: ScrolliniConfig.fallback.outerGap ?? 0),
                range: 0 ... 96,
                suffix: "pt"
            )
        }
    }

    private var behaviorSection: some View {
        Section("Window Behavior") {
            Picker(selection: optionalEnumBinding(\.focusAlignment, fallback: .smart)) {
                ForEach(FocusAlignment.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Focus alignment")
            }

            Picker(selection: optionalEnumBinding(\.newWindowPosition, fallback: .afterActive)) {
                ForEach(NewWindowPosition.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("New windows")
            }

            Toggle("Workspace back-and-forth", isOn: optionalBoolBinding(\.workspaceAutoBackAndForth, fallback: true))
        }
    }

    private var hoverSection: some View {
        Section("Hover Focus") {
            Toggle("Hover to focus", isOn: optionalBoolBinding(\.hoverToFocus, fallback: true))

            Picker(selection: optionalEnumBinding(\.hoverFocusMode, fallback: .edgeOrVisible)) {
                ForEach(HoverFocusMode.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Activation")
            }

            numericStepper(
                title: "Delay",
                value: optionalIntBinding(\.hoverFocusDelayMS, fallback: 120),
                range: 0 ... 1000,
                suffix: "ms"
            )
        }
    }

    private var trackpadSection: some View {
        Section("Trackpad") {
            Toggle("Trackpad navigation", isOn: optionalBoolBinding(\.trackpadNavigation, fallback: true))

            Stepper(value: optionalIntBinding(\.trackpadNavigationWorkspaceFingers, fallback: 4), in: 2 ... 5) {
                HStack {
                    Text("Fingers")
                    Spacer()
                    Text("\(store.config.trackpadNavigationWorkspaceFingers ?? 4)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Workspaces per swipe")
                    Spacer()
                    Text(String(format: "%.1f", store.config.trackpadNavigationWorkspaceSensitivity ?? 6.4))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: optionalCGFloatBinding(\.trackpadNavigationWorkspaceSensitivity, fallback: 6.4),
                    in: 0.1 ... 40,
                    step: 0.1
                )
            }

            Toggle("Invert direction", isOn: optionalBoolBinding(\.trackpadNavigationInvertY, fallback: false))
        }
    }

    private var animationSection: some View {
        Section("Animation") {
            Picker(selection: optionalEnumBinding(\.animationCurve, fallback: .smooth)) {
                ForEach(AnimationCurve.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Curve")
            }

            numericStepper(
                title: "Default",
                value: optionalIntBinding(\.animationDurationMS, fallback: 240),
                range: 0 ... 500,
                suffix: "ms"
            )
            numericStepper(
                title: "Keyboard",
                value: optionalIntBinding(\.keyboardAnimationMS, fallback: 240),
                range: 0 ... 500,
                suffix: "ms"
            )
            numericStepper(
                title: "Width changes",
                value: optionalIntBinding(\.widthAnimationMS, fallback: 280),
                range: 0 ... 500,
                suffix: "ms"
            )
        }
    }

    private var persistenceSection: some View {
        Section("Files") {
            Toggle("Restore windows on exit", isOn: optionalBoolBinding(\.restoreOnExit, fallback: true))

            Toggle("Persist layout state", isOn: optionalBoolBinding(\.persistLayout, fallback: true))

            VStack(alignment: .leading, spacing: 4) {
                Text("Layout state path")
                TextField(store.stateURL.path, text: $store.statePathText)
                    .onChange(of: store.statePathText) { _ in store.scheduleSave() }
                Text("Leave blank to use Scrollini's default state location.").settingsCaption()
            }

            HStack {
                Button("Reveal Settings", action: store.revealSettings)
                Button("Reveal Layout State", action: store.revealState)
            }
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            Picker(selection: optionalEnumBinding(\.hideMethod, fallback: .skyLightAlpha)) {
                ForEach(HideMethod.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Parking method")
            }

            numericStepper(
                title: "Parked sliver",
                value: optionalCGFloatBinding(\.parkedSliverWidth, fallback: 1),
                range: 0 ... 32,
                suffix: "pt"
            )

            numericStepper(
                title: "Rescan interval",
                value: optionalIntBinding(\.rescanIntervalMS, fallback: 1000),
                range: 100 ... 5000,
                suffix: "ms"
            )

            Toggle("Debug logging", isOn: optionalBoolBinding(\.debugLogging, fallback: false))
        }
    }

    private func numericStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func numericStepper(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func numericSlider(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
        }
    }

    private func optionalBoolBinding(
        _ keyPath: WritableKeyPath<ScrolliniConfig, Bool?>,
        fallback: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }

    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<ScrolliniConfig, Int?>,
        fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }

    private func optionalCGFloatBinding(
        _ keyPath: WritableKeyPath<ScrolliniConfig, CGFloat?>,
        fallback: CGFloat
    ) -> Binding<CGFloat> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }

    private func optionalEnumBinding<Value>(
        _ keyPath: WritableKeyPath<ScrolliniConfig, Value?>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }
}

private extension Text {
    func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
