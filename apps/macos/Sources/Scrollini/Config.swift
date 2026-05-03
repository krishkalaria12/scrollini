import CoreGraphics
import Foundation

enum WindowBehavior: String, Codable {
    case tile
    case float
    case ignore
}

struct ScrolliniConfig: Codable {
    var defaultWidthRatio: CGFloat
    var presetWidthRatios: [CGFloat]?
    var animationDurationMS: Int?
    var hoverToFocus: Bool?
    var hoverFocusDelayMS: Int?
    var hoverFocusMaxScrollRatio: CGFloat?
    var workspaceAutoBackAndForth: Bool?
    var centerFocusedColumn: Bool?
    var excludedKeybindings: [String]?
    var rules: [WindowRule]

    static let fallback = ScrolliniConfig(
        defaultWidthRatio: 0.8,
        presetWidthRatios: [0.5, 0.67, 0.8, 1.0],
        animationDurationMS: 180,
        hoverToFocus: true,
        hoverFocusDelayMS: 120,
        hoverFocusMaxScrollRatio: 0.15,
        workspaceAutoBackAndForth: true,
        centerFocusedColumn: true,
        excludedKeybindings: ["cmd+shift+5"],
        rules: [
            WindowRule(bundleID: "com.apple.finder", behavior: .ignore),
        ]
    )

    static func load() -> ScrolliniConfig {
        let candidates = configCandidates()
        let decoder = JSONDecoder()

        for url in candidates {
            guard let data = try? Data(contentsOf: url) else {
                continue
            }

            do {
                var config = try decoder.decode(ScrolliniConfig.self, from: data)
                config.defaultWidthRatio = config.defaultWidthRatio.clampedWidthRatio
                config.presetWidthRatios = normalizeWidthPresets(config.presetWidthRatios)
                config.animationDurationMS = config.animationDurationMS.map { min(max($0, 0), 500) }
                config.hoverFocusDelayMS = config.hoverFocusDelayMS.map { min(max($0, 0), 1000) }
                config.hoverFocusMaxScrollRatio = config.hoverFocusMaxScrollRatio.map { min(max($0, 0), 2) }
                config.rules = config.rules.map { rule in
                    var rule = rule
                    rule.widthRatio = rule.widthRatio.map(\.clampedWidthRatio)
                    return rule
                }
                print("scrollini: loaded config \(url.path)")
                return config
            } catch {
                fputs("scrollini: failed to parse config \(url.path): \(error)\n", stderr)
            }
        }

        return .fallback
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

    private static func configCandidates() -> [URL] {
        var urls: [URL] = []

        if let path = ProcessInfo.processInfo.environment["SCROLLINI_CONFIG"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
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
        case hoverToFocus = "hover_to_focus"
        case hoverFocusDelayMS = "hover_focus_delay_ms"
        case hoverFocusMaxScrollRatio = "hover_focus_max_scroll_ratio"
        case workspaceAutoBackAndForth = "workspace_auto_back_and_forth"
        case centerFocusedColumn = "center_focused_column"
        case excludedKeybindings = "excluded_keybindings"
        case rules
    }
}

struct WindowRule: Codable {
    var bundleID: String?
    var appName: String?
    var titleContains: String?
    var behavior: WindowBehavior?
    var widthRatio: CGFloat?

    init(
        bundleID: String? = nil,
        appName: String? = nil,
        titleContains: String? = nil,
        behavior: WindowBehavior? = nil,
        widthRatio: CGFloat? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.titleContains = titleContains
        self.behavior = behavior
        self.widthRatio = widthRatio
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
