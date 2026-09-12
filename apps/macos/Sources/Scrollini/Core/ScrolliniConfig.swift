import CoreGraphics
import Foundation

enum WindowBehavior: String, Codable {
    case tile
    case float
    case ignore
}

enum FocusAlignment: String, Codable {
    case left
    case center
    case smart
}

enum NewWindowPosition: String, Codable {
    case beforeActive = "before_active"
    case afterActive = "after_active"
    case end
}

enum HideMethod: String, Codable {
    case skyLightAlpha = "skylight_alpha"
    case parkOnly = "park_only"
}

enum AnimationCurve: String, Codable {
    case smooth
    case snappy
    case linear
}

enum HoverFocusMode: String, Codable {
    case off
    case visibleOnly = "visible_only"
    case edgeOrVisible = "edge_or_visible"
}

enum TrackpadNavigationSnap: String, Codable {
    case nearestColumn = "nearest_column"
    case nearestVisible = "nearest_visible"
    case none
}

struct LoadedScrolliniConfig {
    var config: ScrolliniConfig
    var sourceURL: URL?
    var sourceModificationDate: Date?
}

enum ScrolliniConfigLoadResult {
    case loaded(LoadedScrolliniConfig)
    case notFound
    case parseError(Error)
}

struct ScrolliniConfig: Codable {
    var defaultWidthRatio: CGFloat?
    var presetWidthRatios: [CGFloat]?
    var animationDurationMS: Int?
    var keyboardAnimationMS: Int?
    var hoverFocusAnimationMS: Int?
    var trackpadSettleAnimationMS: Int?
    var moveColumnAnimationMS: Int?
    var widthAnimationMS: Int?
    var animationCurve: AnimationCurve?
    var hoverToFocus: Bool?
    var hoverFocusDelayMS: Int?
    var hoverFocusMaxScrollRatio: CGFloat?
    var hoverFocusRequiresVisibleRatio: CGFloat?
    var hoverFocusEdgeTriggerWidth: CGFloat?
    var hoverFocusAfterTrackpadMS: Int?
    var hoverFocusMode: HoverFocusMode?
    var workspaceAutoBackAndForth: Bool?
    var centerFocusedColumn: Bool?
    var focusAlignment: FocusAlignment?
    var newWindowPosition: NewWindowPosition?
    var innerGap: CGFloat?
    var outerGap: CGFloat?
    var parkedSliverWidth: CGFloat?
    var excludedKeybindings: [String]?
    var keybindings: [String: [String]]?
    var trackpadNavigation: Bool?
    var trackpadNavigationFingers: Int?
    var trackpadNavigationSensitivity: CGFloat?
    var trackpadNavigationWorkspaceSensitivity: CGFloat?
    var trackpadNavigationDirectionLockThreshold: CGFloat?
    var trackpadNavigationDeceleration: CGFloat?
    var trackpadNavigationHoverSuppressionMS: Int?
    var trackpadNavigationMomentumMinVelocity: CGFloat?
    var trackpadNavigationVelocityGain: CGFloat?
    var trackpadNavigationSettleAnimationMS: Int?
    var trackpadNavigationSnap: TrackpadNavigationSnap?
    var trackpadNavigationInvertX: Bool?
    var trackpadNavigationInvertY: Bool?
    var rescanIntervalMS: Int?
    var restoreOnExit: Bool?
    var persistLayout: Bool?
    var statePath: String?
    var hideMethod: HideMethod?
    var disableEnhancedUserInterface: Bool?
    var debugLogging: Bool?
    var rules: [WindowRule]?

    static let fallback = ScrolliniConfig(
        defaultWidthRatio: 0.8,
        presetWidthRatios: [0.5, 0.67, 0.8, 1.0],
        animationDurationMS: 240,
        keyboardAnimationMS: 240,
        hoverFocusAnimationMS: 240,
        trackpadSettleAnimationMS: 240,
        moveColumnAnimationMS: 240,
        widthAnimationMS: 280,
        animationCurve: .smooth,
        hoverToFocus: true,
        hoverFocusDelayMS: 120,
        hoverFocusMaxScrollRatio: 0.15,
        hoverFocusRequiresVisibleRatio: 0.15,
        hoverFocusEdgeTriggerWidth: 8,
        hoverFocusAfterTrackpadMS: 280,
        hoverFocusMode: .edgeOrVisible,
        workspaceAutoBackAndForth: true,
        centerFocusedColumn: true,
        focusAlignment: .smart,
        newWindowPosition: .afterActive,
        innerGap: 12,
        outerGap: 12,
        parkedSliverWidth: 1,
        excludedKeybindings: [],
        keybindings: defaultKeybindings,
        trackpadNavigation: true,
        trackpadNavigationFingers: 3,
        trackpadNavigationSensitivity: 1.6,
        trackpadNavigationWorkspaceSensitivity: 6.4,
        trackpadNavigationDirectionLockThreshold: 0.02,
        trackpadNavigationDeceleration: 5.5,
        trackpadNavigationHoverSuppressionMS: 280,
        trackpadNavigationMomentumMinVelocity: 80,
        trackpadNavigationVelocityGain: 1.35,
        trackpadNavigationSettleAnimationMS: 240,
        trackpadNavigationSnap: .nearestColumn,
        trackpadNavigationInvertX: false,
        trackpadNavigationInvertY: false,
        rescanIntervalMS: 1000,
        restoreOnExit: true,
        persistLayout: true,
        statePath: nil,
        hideMethod: .skyLightAlpha,
        disableEnhancedUserInterface: true,
        debugLogging: false,
        rules: [
            WindowRule(bundleID: "com.apple.finder", behavior: .float),
        ]
    )

    /// Every default sits in the `ctrl+alt` space, the only two-modifier combination macOS leaves
    /// entirely unclaimed. `ctrl+alt` focuses, `ctrl+alt+shift` moves whatever `ctrl+alt` focuses.
    /// Nothing here collides with a system shortcut, so no exclusions are needed out of the box.
    static let defaultKeybindings: [String: [String]] = [
        "focus_workspace_1": ["ctrl+alt+1"],
        "focus_workspace_2": ["ctrl+alt+2"],
        "focus_workspace_3": ["ctrl+alt+3"],
        "focus_workspace_4": ["ctrl+alt+4"],
        "focus_workspace_5": ["ctrl+alt+5"],
        "focus_workspace_6": ["ctrl+alt+6"],
        "focus_workspace_7": ["ctrl+alt+7"],
        "focus_workspace_8": ["ctrl+alt+8"],
        "focus_workspace_9": ["ctrl+alt+9"],
        "focus_previous_workspace": ["ctrl+alt+0"],
        "workspace_down": ["ctrl+alt+down"],
        "workspace_up": ["ctrl+alt+up"],
        "column_left": ["ctrl+alt+left"],
        "column_right": ["ctrl+alt+right"],
        "column_first": ["ctrl+alt+["],
        "column_last": ["ctrl+alt+]"],
        "move_column_to_workspace_1": ["ctrl+alt+shift+1"],
        "move_column_to_workspace_2": ["ctrl+alt+shift+2"],
        "move_column_to_workspace_3": ["ctrl+alt+shift+3"],
        "move_column_to_workspace_4": ["ctrl+alt+shift+4"],
        "move_column_to_workspace_5": ["ctrl+alt+shift+5"],
        "move_column_to_workspace_6": ["ctrl+alt+shift+6"],
        "move_column_to_workspace_7": ["ctrl+alt+shift+7"],
        "move_column_to_workspace_8": ["ctrl+alt+shift+8"],
        "move_column_to_workspace_9": ["ctrl+alt+shift+9"],
        "move_column_down": ["ctrl+alt+shift+down"],
        "move_column_up": ["ctrl+alt+shift+up"],
        "move_column_left": ["ctrl+alt+shift+left"],
        "move_column_right": ["ctrl+alt+shift+right"],
        "move_column_to_first": ["ctrl+alt+shift+["],
        "move_column_to_last": ["ctrl+alt+shift+]"],
        "cycle_width_preset_forward": ["ctrl+alt+r"],
        "nudge_width_narrower": ["ctrl+alt+-"],
        "nudge_width_wider": ["ctrl+alt+="],
        "maximize_column_width": ["ctrl+alt+f"],
        "reset_column_width": ["ctrl+alt+shift+r"],

        // Available but unbound. `cycle_width_preset_forward` wraps at both ends, so cycling
        // backward is a convenience rather than a necessity, and the every-window width commands
        // are power-user territory. Bind them in config if you want them.
        "cycle_width_preset_backward": [],
        "cycle_all_width_presets_backward": [],
        "cycle_all_width_presets_forward": [],
        "nudge_all_widths_narrower": [],
        "nudge_all_widths_wider": [],
    ]

    static func load() -> ScrolliniConfig {
        loadWithMetadata().config
    }

    static func loadWithMetadata(logLoaded: Bool = true, logErrors: Bool = true) -> LoadedScrolliniConfig {
        let explicitConfigURL = explicitConfigURL()
        let candidates = configCandidates(explicitConfigURL: explicitConfigURL)

        for url in candidates {
            switch load(from: url, logLoaded: logLoaded, logErrors: logErrors) {
            case let .loaded(loaded):
                return loaded
            case .notFound:
                continue
            case let .parseError(error):
                if url == explicitConfigURL {
                    if logErrors {
                        fputs("scrollini: explicit config \(url.path) is invalid; not falling back: \(error)\n", stderr)
                    }
                    return LoadedScrolliniConfig(config: .fallback, sourceURL: nil, sourceModificationDate: nil)
                }
                continue
            }
        }

        return LoadedScrolliniConfig(config: .fallback, sourceURL: nil, sourceModificationDate: nil)
    }

    static func load(from url: URL, logLoaded: Bool = true, logErrors: Bool = true) -> ScrolliniConfigLoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return .notFound
        }

        do {
            let config = normalize(try JSONDecoder().decode(ScrolliniConfig.self, from: data))
            if logLoaded {
                print("scrollini: loaded config \(url.path)")
            }
            let loaded = LoadedScrolliniConfig(
                config: config,
                sourceURL: url,
                sourceModificationDate: modificationDate(for: url)
            )
            return .loaded(loaded)
        } catch {
            if logErrors {
                fputs("scrollini: failed to parse config \(url.path): \(error)\n", stderr)
            }
            return .parseError(error)
        }
    }

    static func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    static func normalize(_ loadedConfig: ScrolliniConfig) -> ScrolliniConfig {
        var config = loadedConfig
        config.defaultWidthRatio = config.defaultWidthRatio.map(\.clampedWidthRatio)
        config.presetWidthRatios = normalizeWidthPresets(config.presetWidthRatios)
        config.animationDurationMS = config.animationDurationMS.map { min(max($0, 0), 500) }
        config.keyboardAnimationMS = config.keyboardAnimationMS.map { min(max($0, 0), 500) }
        config.hoverFocusAnimationMS = config.hoverFocusAnimationMS.map { min(max($0, 0), 500) }
        config.trackpadSettleAnimationMS = config.trackpadSettleAnimationMS.map { min(max($0, 0), 500) }
        config.moveColumnAnimationMS = config.moveColumnAnimationMS.map { min(max($0, 0), 500) }
        config.widthAnimationMS = config.widthAnimationMS.map { min(max($0, 0), 500) }
        config.hoverFocusDelayMS = config.hoverFocusDelayMS.map { min(max($0, 0), 1000) }
        config.hoverFocusMaxScrollRatio = config.hoverFocusMaxScrollRatio.map { min(max($0, 0), 2) }
        config.hoverFocusRequiresVisibleRatio = config.hoverFocusRequiresVisibleRatio.map { min(max($0, 0), 2) }
        config.hoverFocusEdgeTriggerWidth = config.hoverFocusEdgeTriggerWidth.map { min(max($0, 0), 96) }
        config.hoverFocusAfterTrackpadMS = config.hoverFocusAfterTrackpadMS.map { min(max($0, 0), 2000) }
        config.innerGap = config.innerGap.map { min(max($0, 0), 96) }
        config.outerGap = config.outerGap.map { min(max($0, 0), 96) }
        config.parkedSliverWidth = config.parkedSliverWidth.map { min(max($0, 0), 32) }
        config.trackpadNavigationFingers = config.trackpadNavigationFingers.map { min(max($0, 2), 5) }
        config.trackpadNavigationSensitivity = config.trackpadNavigationSensitivity.map { min(max($0, 0.1), 20) }
        config.trackpadNavigationWorkspaceSensitivity = config.trackpadNavigationWorkspaceSensitivity
            .map { min(max($0, 0.1), 40) }
        config.trackpadNavigationDirectionLockThreshold = config.trackpadNavigationDirectionLockThreshold
            .map { min(max($0, 0.001), 0.5) }
        config.trackpadNavigationDeceleration = config.trackpadNavigationDeceleration.map { min(max($0, 1), 30) }
        config.trackpadNavigationHoverSuppressionMS = config.trackpadNavigationHoverSuppressionMS.map { min(max($0, 0), 2000) }
        config.trackpadNavigationMomentumMinVelocity = config.trackpadNavigationMomentumMinVelocity.map { min(max($0, 0), 5000) }
        config.trackpadNavigationVelocityGain = config.trackpadNavigationVelocityGain.map { min(max($0, 0), 5) }
        config.trackpadNavigationSettleAnimationMS = config.trackpadNavigationSettleAnimationMS.map { min(max($0, 0), 500) }
        config.rescanIntervalMS = config.rescanIntervalMS.map { min(max($0, 100), 5000) }
        config.rules = config.rules.map { rules in
            rules.map { rule in
                var rule = rule
                rule.widthRatio = rule.widthRatio.map(\.clampedWidthRatio)
                rule.workspace = rule.workspace.map { min(max($0, 1), 99) }
                return rule
            }
        }
        return config
    }

    private static func normalizeWidthPresets(_ presets: [CGFloat]?) -> [CGFloat]? {
        guard let presets else {
            return nil
        }

        let sorted = presets
            .filter(\.isFinite)
            .map(\.clampedManualWidthRatio)
            .sorted()
        var unique: [CGFloat] = []
        for preset in sorted where unique.last.map({ abs($0 - preset) >= 0.005 }) ?? true {
            unique.append(preset)
        }
        return unique.isEmpty ? nil : unique
    }

    private static func explicitConfigURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["SCROLLINI_CONFIG"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func configCandidates(explicitConfigURL: URL?) -> [URL] {
        var urls: [URL] = []

        if let explicitConfigURL {
            urls.append(explicitConfigURL)
        }

        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scrollini.config.json"))

        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        urls.append(xdgConfig.appendingPathComponent("scrollini/config.json"))

        return urls
    }

    private enum CodingKeys: String, CodingKey {
        case defaultWidthRatio = "default_width_ratio"
        case presetWidthRatios = "preset_width_ratios"
        case animationDurationMS = "animation_duration_ms"
        case keyboardAnimationMS = "keyboard_animation_ms"
        case hoverFocusAnimationMS = "hover_focus_animation_ms"
        case trackpadSettleAnimationMS = "trackpad_settle_animation_ms"
        case moveColumnAnimationMS = "move_column_animation_ms"
        case widthAnimationMS = "width_animation_ms"
        case animationCurve = "animation_curve"
        case hoverToFocus = "hover_to_focus"
        case hoverFocusDelayMS = "hover_focus_delay_ms"
        case hoverFocusMaxScrollRatio = "hover_focus_max_scroll_ratio"
        case hoverFocusRequiresVisibleRatio = "hover_focus_requires_visible_ratio"
        case hoverFocusEdgeTriggerWidth = "hover_focus_edge_trigger_width"
        case hoverFocusAfterTrackpadMS = "hover_focus_after_trackpad_ms"
        case hoverFocusMode = "hover_focus_mode"
        case workspaceAutoBackAndForth = "workspace_auto_back_and_forth"
        case centerFocusedColumn = "center_focused_column"
        case focusAlignment = "focus_alignment"
        case newWindowPosition = "new_window_position"
        case innerGap = "inner_gap"
        case outerGap = "outer_gap"
        case parkedSliverWidth = "parked_sliver_width"
        case excludedKeybindings = "excluded_keybindings"
        case keybindings
        case trackpadNavigation = "trackpad_navigation"
        case trackpadNavigationFingers = "trackpad_navigation_fingers"
        case trackpadNavigationSensitivity = "trackpad_navigation_sensitivity"
        case trackpadNavigationWorkspaceSensitivity = "trackpad_navigation_workspace_sensitivity"
        case trackpadNavigationDirectionLockThreshold = "trackpad_navigation_direction_lock_threshold"
        case trackpadNavigationDeceleration = "trackpad_navigation_deceleration"
        case trackpadNavigationHoverSuppressionMS = "trackpad_navigation_hover_suppression_ms"
        case trackpadNavigationMomentumMinVelocity = "trackpad_navigation_momentum_min_velocity"
        case trackpadNavigationVelocityGain = "trackpad_navigation_velocity_gain"
        case trackpadNavigationSettleAnimationMS = "trackpad_navigation_settle_animation_ms"
        case trackpadNavigationSnap = "trackpad_navigation_snap"
        case trackpadNavigationInvertX = "trackpad_navigation_invert_x"
        case trackpadNavigationInvertY = "trackpad_navigation_invert_y"
        case rescanIntervalMS = "rescan_interval_ms"
        case restoreOnExit = "restore_on_exit"
        case persistLayout = "persist_layout"
        case statePath = "state_path"
        case hideMethod = "hide_method"
        case disableEnhancedUserInterface = "disable_enhanced_user_interface"
        case debugLogging = "debug_logging"
        case rules
    }
}

struct WindowRule: Codable {
    var bundleID: String?
    var appName: String?
    var titleContains: String?
    var behavior: WindowBehavior?
    var widthRatio: CGFloat?
    var workspace: Int?
    var openPosition: NewWindowPosition?
    var trackpadNavigation: Bool?
    var hoverToFocus: Bool?
    /// Chords this app should keep for itself. Matched against the frontmost application rather
    /// than a tiled window, so a rule needs `bundle_id` or `app_name` for these to apply.
    var excludedKeybindings: [String]?

    init(
        bundleID: String? = nil,
        appName: String? = nil,
        titleContains: String? = nil,
        behavior: WindowBehavior? = nil,
        widthRatio: CGFloat? = nil,
        workspace: Int? = nil,
        openPosition: NewWindowPosition? = nil,
        trackpadNavigation: Bool? = nil,
        hoverToFocus: Bool? = nil,
        excludedKeybindings: [String]? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.titleContains = titleContains
        self.behavior = behavior
        self.widthRatio = widthRatio
        self.workspace = workspace
        self.openPosition = openPosition
        self.trackpadNavigation = trackpadNavigation
        self.hoverToFocus = hoverToFocus
        self.excludedKeybindings = excludedKeybindings
    }

    /// `matches(_:)` needs a tiled window. Key exclusions run on every keystroke against whatever
    /// app is frontmost, which may own no managed window at all, so they match on app identity only.
    func matchesApplication(bundleID candidateBundleID: String?, appName candidateAppName: String?) -> Bool {
        if let bundleID, bundleID != candidateBundleID {
            return false
        }
        if let appName, appName != candidateAppName {
            return false
        }
        return bundleID != nil || appName != nil
    }

    func matches(_ window: ManagedWindow) -> Bool {
        if let bundleID, window.bundleID != bundleID {
            return false
        }
        if let appName, window.appName != appName {
            return false
        }
        if let titleContains,
           window.title.range(of: titleContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        {
            return false
        }
        return bundleID != nil || appName != nil || titleContains != nil
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case appName = "app_name"
        case titleContains = "title_contains"
        case behavior
        case widthRatio = "width_ratio"
        case workspace
        case openPosition = "open_position"
        case trackpadNavigation = "trackpad_navigation"
        case hoverToFocus = "hover_to_focus"
        case excludedKeybindings = "excluded_keybindings"
    }
}

extension CGFloat {
    var clampedWidthRatio: CGFloat {
        Swift.min(Swift.max(self, 0.2), 2.0)
    }

    var clampedManualWidthRatio: CGFloat {
        Swift.min(Swift.max(self, 0.05), 2.0)
    }
}
