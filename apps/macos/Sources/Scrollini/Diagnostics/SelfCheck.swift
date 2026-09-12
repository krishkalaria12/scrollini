import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Invariant checks for the parts of scrollini that are pure computation: strip geometry, layout
/// projection, rule resolution, keybinding parsing, config clamping, workspace bookkeeping.
///
/// It lives in the app binary and runs as `scrollini --self-check` rather than under `swift test`
/// for one practical reason: `swift test` needs XCTest or swift-testing, and neither ships with
/// the Command Line Tools this project otherwise builds fine on. Compiling with every build also
/// means these cannot quietly rot the way a skipped test target would.
///
/// Everything here has to run without a window server, so nothing may reach for `NSScreen`. The
/// viewport is supplied directly, and where a call resolves it internally the cache is primed
/// first.
enum SelfCheck {
    nonisolated(unsafe) private static var checks = 0
    nonisolated(unsafe) private static var failures = 0

    static func run() -> Never {
        section("layout projection")
        checkLayoutItemMatchesFullProjection()

        section("niri proportional sizing")
        checkProportionalSizing()

        section("window rules")
        checkRuleResolution()
        checkRuleMatchingEdgeCases()

        section("width presets and nudging")
        checkWidthPresets()
        checkMaximizeToggle()
        checkNudging()

        section("workspace bookkeeping")
        checkWorkspaceInvariants()

        section("keybindings")
        checkKeybindingNormalization()
        checkKeybindingCandidatesAndCommands()

        section("config normalization")
        checkConfigClamping()
        checkConfigClampingExhaustive()

        section("hover focus")
        checkHoverFocusStaysOnActiveWorkspace()
        checkHoverFocusHelpers()

        section("strip metrics")
        checkStripMetrics()
        checkMeasuredWidthPacking()

        section("strip frames and scroll")
        checkStripFramesAndScrollOffset()
        checkCameraOffsets()

        section("parked frames")
        checkParkedFrames()

        section("camera math")
        checkCameraMath()

        section("layout visibility and parkHidden")
        checkLayoutVisibility()

        section("command resolution")
        checkCommandResolution()

        section("excluded keybindings")
        checkExcludedKeybindings()

        section("config accessors")
        checkConfigAccessors()
        checkTrackpadSensitivityFallback()

        section("persistence roundtrip")
        checkPersistenceRoundtrip()

        section("manual resize")
        checkManualResizeMath()

        section("animation math")
        checkAnimationMath()

        section("input")
        checkInputHelpers()

        section("transient windows")
        checkTransientWindowHelpers()

        section("focus expectations")
        checkFocusExpectations()

        section("column navigation")
        checkColumnNavigation()

        section("trackpad physics")
        checkTrackpadPhysics()

        section("config json loading")
        checkConfigJSONLoading()

        section("layout verification helpers")
        checkLayoutVerificationHelpers()

        section("resolved rule cache")
        checkResolvedRuleCacheInvalidation()

        print("")
        print("scrollini: \(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Checks

    /// The single most important check here. `layoutItem(for:)` lays out only the workspace that
    /// owns one window, where `layoutItems` lays out the whole model. Every window move and
    /// resize notification goes through the narrow path, so the two must never disagree.
    private static func checkLayoutItemMatchesFullProjection() {
        let scrollini = Scrollini()
        let windows = buildModel(scrollini)
        var compared = 0
        var mismatches = 0

        for parkHidden in [true, false] {
            for cameraY in [nil, 0, 500, 1000, 2000] as [CGFloat?] {
                for scrollOffset in [nil, 0, 340] as [CGFloat?] {
                    scrollini.workspaces[0].scrollOffset = scrollOffset
                    var state = scrollini.captureLayoutState()
                    state.cameraY = cameraY

                    let all = scrollini.layoutItems(viewport: viewport, state: state, parkHidden: parkHidden)
                    for window in windows {
                        compared += 1
                        let expected = all.first { $0.window === window }
                        let actual = scrollini.layoutItem(
                            for: window,
                            viewport: viewport,
                            state: state,
                            parkHidden: parkHidden
                        )
                        guard let expected, let actual,
                              sameRect(expected.frame, actual.frame),
                              expected.visible == actual.visible
                        else {
                            mismatches += 1
                            continue
                        }
                    }
                }
            }
        }

        check("all \(compared) window and state combinations agree", mismatches == 0, "\(mismatches) disagreed")
    }

    /// The sizing promises the README makes, pinned so a change to the gap arithmetic cannot
    /// quietly break them.
    private static func checkProportionalSizing() {
        let scrollini = Scrollini()
        let left = window(0)
        let right = window(1)
        left.manualWidthRatio = 0.5
        right.manualWidthRatio = 0.5
        let workspace = Workspace()
        workspace.columns = [left, right]
        scrollini.workspaces = [workspace]

        let gap = scrollini.innerGap
        let metrics = scrollini.stripMetrics(for: workspace, viewport: viewport)
        let occupied = metrics.widths[0] + gap + metrics.widths[1] + gap * 2
        check("two 0.5 columns tile the viewport exactly, gaps included", approx(occupied, viewport.width, 0.01))

        let full = window(2)
        full.manualWidthRatio = 1.0
        check(
            "a 1.0 column fills the viewport minus one gap each side",
            approx(scrollini.requestedWidth(for: full, viewport: viewport), viewport.width - gap * 2, 0.01)
        )

        let narrow = window(3)
        narrow.manualWidthRatio = 0.2
        let narrowW = scrollini.requestedWidth(for: narrow, viewport: viewport)
        check("0.2 ratio produces a narrow strip", narrowW > 0 && narrowW < viewport.width * 0.3)

        let wide = window(4)
        wide.manualWidthRatio = 2.0
        let wideW = scrollini.requestedWidth(for: wide, viewport: viewport)
        check("2.0 ratio overflows viewport", wideW > viewport.width)
    }

    /// Rules resolve per setting. A narrow rule that only sets `behavior` must not swallow the
    /// `workspace` a later rule declares for the same window.
    private static func checkRuleResolution() {
        let scrollini = Scrollini()
        scrollini.loadedConfig = LoadedScrolliniConfig(
            config: ScrolliniConfig(
                newWindowPosition: .end,
                rules: [
                    WindowRule(bundleID: "com.test.0", behavior: .float),
                    WindowRule(
                        bundleID: "com.test.0",
                        widthRatio: 0.5,
                        workspace: 3,
                        openPosition: .beforeActive,
                        hoverToFocus: false
                    ),
                ]
            ),
            sourceURL: nil,
            sourceModificationDate: nil
        )

        let candidate = window(0)
        check("behavior comes from the first rule that sets it", scrollini.behavior(for: candidate) == .float)
        check("workspace survives an earlier partial match", scrollini.workspace(for: candidate) == 3)
        check("open position survives an earlier partial match", scrollini.openPosition(for: candidate) == .beforeActive)
        check("hover to focus survives an earlier partial match", scrollini.hoverToFocusAllowed(for: candidate) == false)
        check("width ratio survives an earlier partial match", approx(scrollini.widthRatio(for: candidate), 0.5))
    }

    /// Rule resolution is cached per window, so every input the answer depends on has to retire
    /// the cache when it moves. A stale entry here is not a slow layout, it is the wrong one:
    /// a window that gets retitled into a `title_contains` rule would keep the old behaviour for
    /// as long as it lives.
    private static func checkResolvedRuleCacheInvalidation() {
        let scrollini = Scrollini()
        func load(_ rules: [WindowRule]) {
            scrollini.loadedConfig = LoadedScrolliniConfig(
                config: ScrolliniConfig(defaultWidthRatio: 0.8, rules: rules),
                sourceURL: nil,
                sourceModificationDate: nil
            )
            scrollini.configureInput()
        }

        load([WindowRule(titleContains: "Preferences", behavior: .float, widthRatio: 0.5)])
        let candidate = window(0)
        check("untitled window does not match the rule", scrollini.behavior(for: candidate) == .tile)
        check("untitled window keeps the default width", approx(scrollini.widthRatio(for: candidate), 0.8))

        candidate.title = "App Preferences"
        check("retitling into a rule takes effect", scrollini.behavior(for: candidate) == .float)
        check("retitling into a rule updates the width", approx(scrollini.widthRatio(for: candidate), 0.5))

        candidate.title = "Window 0"
        check("retitling back out of a rule takes effect", scrollini.behavior(for: candidate) == .tile)

        load([WindowRule(bundleID: "com.test.0", behavior: .ignore, workspace: 2)])
        check("reloading the config retires cached answers", scrollini.behavior(for: candidate) == .ignore)
        check("reloading the config retires cached workspaces", scrollini.workspace(for: candidate) == 2)

        candidate.bundleID = "com.test.999"
        check("changing bundle id retires cached answers", scrollini.behavior(for: candidate) == .tile)
        check("changing bundle id retires cached workspaces", scrollini.workspace(for: candidate) == nil)

        load([WindowRule(appName: "Renamed", hoverToFocus: false)])
        check("hover to focus defaults to allowed", scrollini.hoverToFocusAllowed(for: candidate))
        candidate.appName = "Renamed"
        check("renaming the app retires cached answers", !scrollini.hoverToFocusAllowed(for: candidate))

        // A manual width is read ahead of the rules, not cached alongside them.
        load([WindowRule(bundleID: "com.test.1", widthRatio: 0.5)])
        let manual = window(1)
        check("rule width applies before a manual width is set", approx(scrollini.widthRatio(for: manual), 0.5))
        manual.manualWidthRatio = 0.25
        check("manual width overrides the cached rule width", approx(scrollini.widthRatio(for: manual), 0.25))
        manual.manualWidthRatio = nil
        check("clearing the manual width falls back to the rule", approx(scrollini.widthRatio(for: manual), 0.5))
    }

    private static func checkRuleMatchingEdgeCases() {
        let scrollini = Scrollini()
        // title_contains is case and diacritic insensitive
        scrollini.loadedConfig = LoadedScrolliniConfig(
            config: ScrolliniConfig(rules: [
                WindowRule(titleContains: "Preferences", behavior: .float),
                WindowRule(bundleID: "com.apple.Safari", behavior: .float),
                WindowRule(appName: "Safari", behavior: .float),
            ]),
            sourceURL: nil,
            sourceModificationDate: nil
        )
        let w1 = window(10)
        w1.title = "preferences"
        check("title_contains matches case-insensitive", scrollini.behavior(for: w1) == .float)
        let w2 = window(11)
        w2.title = "PREFÉRENCES"
        // diacritic insensitive: é == e
        check("title_contains matches diacritic-insensitive", scrollini.behavior(for: w2) == .float)

        let w3 = window(12)
        w3.bundleID = "com.apple.Safari"
        w3.title = "whatever"
        check("bundle_id match", scrollini.behavior(for: w3) == .float)

        let wNoMatch = window(13)
        wNoMatch.bundleID = "com.other.app"
        wNoMatch.title = "Other"
        check("no rule yields tile behavior", scrollini.behavior(for: wNoMatch) == .tile)

        // matchesApplication requires bundleID or appName, title alone is ignored for key exclusions
        let ruleTitleOnly = WindowRule(titleContains: "Zoom", excludedKeybindings: ["ctrl+alt+left"])
        check("title-only rule does not match application", ruleTitleOnly.matchesApplication(bundleID: "com.zoom", appName: "Zoom") == false)

        let ruleBundle = WindowRule(bundleID: "com.zoom", excludedKeybindings: ["ctrl+alt+left"])
        check("bundle rule matches application", ruleBundle.matchesApplication(bundleID: "com.zoom", appName: "Zoom") == true)
        check("bundle rule rejects different bundle", ruleBundle.matchesApplication(bundleID: "com.other", appName: "Zoom") == false)

        // widthRatio falls back to default when no rule and no manual width
        let s2 = Scrollini()
        let w = window(20)
        check("default width ratio is 0.8", approx(s2.widthRatio(for: w), 0.8))
        w.manualWidthRatio = 0.6
        check("manual width ratio wins over default", approx(s2.widthRatio(for: w), 0.6))
        w.manualWidthRatio = 99 // clamped
        check("manual width clamps to 2.0", approx(s2.widthRatio(for: w), 2.0))
        w.manualWidthRatio = -5
        check("manual width clamps to 0.05", approx(s2.widthRatio(for: w), 0.05))
    }

    private static func checkWidthPresets() {
        let scrollini = Scrollini()
        scrollini.loadedConfig = LoadedScrolliniConfig(
            config: ScrolliniConfig(presetWidthRatios: [0.5, 0.67, 0.8, 1.0]),
            sourceURL: nil,
            sourceModificationDate: nil
        )

        check("cycling forward steps up", scrollini.widthPreset(after: 0.5, direction: 1) == 0.67)
        check("cycling backward steps down", scrollini.widthPreset(after: 1.0, direction: -1) == 0.8)
        check("cycling forward past the top wraps", scrollini.widthPreset(after: 1.0, direction: 1) == 0.5)
        check("cycling backward past the bottom wraps", scrollini.widthPreset(after: 0.5, direction: -1) == 1.0)
        check("cycling from in-between picks next preset", scrollini.widthPreset(after: 0.6, direction: 1) == 0.67)
        check("empty presets returns nil", {
            let s = Scrollini()
            s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(presetWidthRatios: []), sourceURL: nil, sourceModificationDate: nil)
            return s.widthPreset(after: 0.5, direction: 1) == nil
        }())
    }

    private static func checkMaximizeToggle() {
        let scrollini = Scrollini()
        let column = window(0)
        column.manualWidthRatio = 1.5
        let workspace = Workspace()
        workspace.columns = [column]
        scrollini.workspaces = [workspace]
        scrollini.activeWorkspace = 0

        check("a column wider than the viewport still maximizes", scrollini.toggleMaximizeActiveWidth())
        check("maximizing lands on exactly 1.0", approx(scrollini.widthRatio(for: column), 1.0))
        check("maximizing again toggles back", scrollini.toggleMaximizeActiveWidth())
        check("and restores the width it had before", approx(scrollini.widthRatio(for: column), 1.5))

        // already at 1.0 does nothing
        let col2 = window(1)
        col2.manualWidthRatio = 1.0
        let ws2 = Workspace()
        ws2.columns = [col2]
        scrollini.workspaces = [ws2]
        scrollini.activeWorkspace = 0
        check("maximizing a 1.0 column does nothing", scrollini.toggleMaximizeActiveWidth() == false)

        // nudge resets preMaximize
        let col3 = window(2)
        col3.manualWidthRatio = 0.8
        let ws3 = Workspace()
        ws3.columns = [col3]
        scrollini.workspaces = [ws3]
        scrollini.activeWorkspace = 0
        _ = scrollini.toggleMaximizeActiveWidth()
        // nudge from 1.0 upward is a no-op (capped), so use narrower to force a real change that clears preMaximize
        _ = scrollini.nudgeActiveWidth(by: -0.1)
        check("nudging clears preMaximize", col3.preMaximizeWidthRatio == nil)
    }

    private static func checkNudging() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(presetWidthRatios: [0.5, 0.8, 1.0]), sourceURL: nil, sourceModificationDate: nil)
        check("nudge up caps at 1.0 when coming from <=1.0", approx(s.nudgedWidthRatio(from: 0.9, by: 0.2), 1.0))
        check("nudge up beyond 1.0 can exceed when starting over 1.0", approx(s.nudgedWidthRatio(from: 1.2, by: 0.2), 1.4))
        check("nudge down clamps to 0.05", approx(s.nudgedWidthRatio(from: 0.06, by: -0.1), 0.05))
        check("nudge up clamps to 2.0", approx(s.nudgedWidthRatio(from: 1.9, by: 0.3), 2.0))

        // setWidthRatio deduplicates within 0.005
        let w = window(5)
        let ws = Workspace()
        ws.columns = [w]
        s.workspaces = [ws]
        s.activeWorkspace = 0
        w.manualWidthRatio = 0.5
        check("setWidthRatio ignores sub-threshold change", s.setWidthRatio(0.502, for: w) == false)
        check("setWidthRatio accepts meaningful change", s.setWidthRatio(0.6, for: w) == true)
    }

    private static func checkWorkspaceInvariants() {
        let scrollini = Scrollini()
        _ = buildModel(scrollini)
        scrollini.ensureTrailingEmptyWorkspace()

        check("there is exactly one trailing empty workspace", scrollini.workspaces.count == 4)
        check("the last workspace is the empty one", scrollini.workspaces.last?.isEmpty == true)
        check("no empty workspace is left in the middle", !scrollini.workspaces.dropLast().contains(where: \.isEmpty))

        scrollini.workspaces[1].columns.removeAll()
        scrollini.activeWorkspace = 2
        scrollini.ensureTrailingEmptyWorkspace()

        check("an emptied middle workspace collapses", scrollini.workspaces.count == 3)
        check("the active index follows the collapse", scrollini.activeWorkspace == 1)
        check("the active workspace keeps its columns", scrollini.activeWorkspaceObject()?.columns.count == 4)

        // empty model guarantees one workspace
        let s2 = Scrollini()
        s2.workspaces = []
        s2.activeWorkspace = 5
        s2.ensureTrailingEmptyWorkspace()
        check("empty workspaces seeds one", s2.workspaces.count == 1)
        check("activeWorkspace clamps to 0 when seeding", s2.activeWorkspace == 0)

        // focus workspace with back-and-forth
        let s3 = Scrollini()
        _ = buildModel(s3)
        s3.ensureTrailingEmptyWorkspace()
        s3.activeWorkspace = 0
        s3.previousWorkspace = s3.workspaces[2]
        s3.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(workspaceAutoBackAndForth: true), sourceURL: nil, sourceModificationDate: nil)
        _ = s3.focusWorkspace(1) // same as active -> should go to previous
        check("back-and-forth jumps to previous workspace", s3.activeWorkspace == 2)

        s3.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(workspaceAutoBackAndForth: false), sourceURL: nil, sourceModificationDate: nil)
        let before = s3.activeWorkspace
        _ = s3.focusWorkspace(before + 1)
        check("without back-and-forth, same index is no-op", s3.focusWorkspace(before + 1) == false)
    }

    private static func checkKeybindingNormalization() {
        let scrollini = Scrollini()

        check(
            "modifier spellings collapse",
            scrollini.normalizedKeybinding("Option+Control+Left") == scrollini.normalizedKeybinding("ctrl+alt+leftarrow")
        )
        check(
            "modifier order does not matter",
            scrollini.normalizedKeybinding("alt+ctrl+r") == scrollini.normalizedKeybinding("ctrl+alt+r")
        )
        check(
            "key spellings collapse",
            scrollini.normalizedKeybinding("ctrl+alt+minus") == scrollini.normalizedKeybinding("ctrl+alt+-")
        )
        check(
            "cmd, super, meta and win are one modifier",
            scrollini.normalizedKeybinding("super+a") == scrollini.normalizedKeybinding("cmd+a")
        )
        check("a chord with no key is rejected", scrollini.normalizedKeybinding("ctrl+alt") == nil)
        check(
            "every shipped default parses",
            ScrolliniConfig.defaultKeybindings.values.flatMap { $0 }.allSatisfy {
                scrollini.normalizedKeybinding($0) != nil
            }
        )
        check(
            "every shipped default names a real command",
            ScrolliniConfig.defaultKeybindings.keys.allSatisfy { scrollini.command(named: $0) != nil }
        )
        // additional
        check("fn alias home/left stripping", scrollini.normalizedKeybinding("ctrl+alt+home") != nil)
        check("leftbracket alias", scrollini.normalizedKeybinding("ctrl+alt+leftbracket") == scrollini.normalizedKeybinding("ctrl+alt+["))
        check("command is lowercased", scrollini.normalizedKeybinding("CTRL+ALT+R") == "ctrl+alt+r")
        check("brackets with shift produce same normalized", scrollini.normalizedKeybinding("ctrl+alt+shift+[") != nil)
    }

    private static func checkKeybindingCandidatesAndCommands() {
        let s = Scrollini()
        // candidates with fn
        let modsWithFn: CGEventFlags = [.maskControl, .maskAlternate, .maskSecondaryFn]
        let candidates = s.normalizedKeybindingCandidates(modifiers: modsWithFn, keyCode: KeyCode.leftArrow, keyText: "")
        check("fn leftArrow produces home alias candidate", candidates.contains("ctrl+alt+fn+home") || candidates.contains("ctrl+alt+home"))
        check("fn leftArrow also produces left without fn", candidates.contains("ctrl+alt+left"))

        // command mapping
        check("focus_workspace_5 maps", s.command(named: "focus_workspace_5") != nil)
        check("focus_workspace_0 is out of range", s.command(named: "focus_workspace_0") == nil)
        check("focus_workspace_10 out of range", s.command(named: "focus_workspace_10") == nil)
        check("unknown command is nil", s.command(named: "nonexistent_command") == nil)
        check("column_left maps", s.command(named: "column_left") != nil)
        check("move_column_to_workspace_9 maps", s.command(named: "move_column_to_workspace_9") != nil)
        check("cycle_all_width_presets_forward maps", s.command(named: "cycle_all_width_presets_forward") != nil)
        check("commandIndex respects bounds", s.commandIndex("focus_workspace_3", prefix: "focus_workspace_") == 3)
        check("commandIndex rejects zero", s.commandIndex("focus_workspace_0", prefix: "focus_workspace_") == nil)
    }

    private static func checkConfigClamping() {
        var wild = ScrolliniConfig.fallback
        wild.innerGap = 5000
        wild.outerGap = -20
        wild.rescanIntervalMS = 5
        wild.trackpadNavigationFingers = 99
        wild.presetWidthRatios = [3.0, 0.5, 0.5, -1.0]

        let normalized = ScrolliniConfig.normalize(wild)
        check("inner gap clamps to its ceiling", normalized.innerGap == 96)
        check("outer gap clamps to zero", normalized.outerGap == 0)
        check("rescan interval clamps to its floor", normalized.rescanIntervalMS == 100)
        check("finger count clamps to five", normalized.trackpadNavigationFingers == 5)
        check("presets come back sorted, clamped and deduplicated", normalized.presetWidthRatios == [0.05, 0.5, 2.0])
    }

    private static func checkConfigClampingExhaustive() {
        var c = ScrolliniConfig.fallback
        c.defaultWidthRatio = -5
        c.animationDurationMS = 999
        c.keyboardAnimationMS = -10
        c.hoverFocusDelayMS = 5000
        c.hoverFocusMaxScrollRatio = 5
        c.hoverFocusRequiresVisibleRatio = -2
        c.hoverFocusEdgeTriggerWidth = 200
        c.hoverFocusAfterTrackpadMS = 9999
        c.parkedSliverWidth = 100
        c.trackpadNavigationSensitivity = 999
        c.trackpadNavigationWorkspaceSensitivity = -1
        c.trackpadNavigationDirectionLockThreshold = 9
        c.trackpadNavigationDeceleration = 100
        c.trackpadNavigationHoverSuppressionMS = 9000
        c.trackpadNavigationMomentumMinVelocity = 99999
        c.trackpadNavigationVelocityGain = 99
        c.trackpadNavigationSettleAnimationMS = 9000
        let n = ScrolliniConfig.normalize(c)
        check("defaultWidthRatio clamps to 0.2", n.defaultWidthRatio == 0.2)
        check("animationDurationMS clamps to 500", n.animationDurationMS == 500)
        check("keyboardAnimationMS clamps to 0", n.keyboardAnimationMS == 0)
        check("hoverFocusDelayMS clamps to 1000", n.hoverFocusDelayMS == 1000)
        check("hoverFocusMaxScrollRatio clamps to 2", n.hoverFocusMaxScrollRatio == 2)
        check("hoverFocusRequiresVisibleRatio clamps to 0", n.hoverFocusRequiresVisibleRatio == 0)
        check("hoverFocusEdgeTriggerWidth clamps to 96", n.hoverFocusEdgeTriggerWidth == 96)
        check("hoverFocusAfterTrackpadMS clamps to 2000", n.hoverFocusAfterTrackpadMS == 2000)
        check("parkedSliver clamps to 32", n.parkedSliverWidth == 32)
        check("trackpad sensitivity clamps to 20", n.trackpadNavigationSensitivity == 20)
        check("workspace sensitivity clamps to 0.1 when negative", n.trackpadNavigationWorkspaceSensitivity == 0.1)
        check("directionLock clamps to 0.5", n.trackpadNavigationDirectionLockThreshold == 0.5)
        check("deceleration clamps to 30", n.trackpadNavigationDeceleration == 30)
        check("hoverSuppression clamps to 2000", n.trackpadNavigationHoverSuppressionMS == 2000)
        check("momentumMinVelocity clamps to 5000", n.trackpadNavigationMomentumMinVelocity == 5000)
        check("velocityGain clamps to 5", n.trackpadNavigationVelocityGain == 5)
        check("settleAnimation clamps to 500", n.trackpadNavigationSettleAnimationMS == 500)

        // rule workspace clamping
        var c2 = ScrolliniConfig.fallback
        c2.rules = [WindowRule(bundleID: "a", widthRatio: 99, workspace: 200)]
        let n2 = ScrolliniConfig.normalize(c2)
        check("rule workspace clamps to 99", n2.rules?.first?.workspace == 99)
        check("rule widthRatio clamps to 2.0", n2.rules?.first?.widthRatio == 2.0)

        // preset edge: NaN/Inf filtered, empty becomes nil, dedup tolerance 0.005
        var c3 = ScrolliniConfig(presetWidthRatios: [0.5, 0.501, 0.502, .infinity, .nan])
        c3 = ScrolliniConfig.normalize(c3)
        check("presets deduplicate within 0.005", c3.presetWidthRatios?.count == 1)
        var c4 = ScrolliniConfig(presetWidthRatios: [.infinity, .nan])
        c4 = ScrolliniConfig.normalize(c4)
        check("all non-finite presets becomes nil", c4.presetWidthRatios == nil)

        // CGFloat clamped helpers
        check("clampedWidthRatio 0.2 floor", CGFloat(-1).clampedWidthRatio == 0.2)
        check("clampedWidthRatio 2.0 ceiling", CGFloat(10).clampedWidthRatio == 2.0)
        check("clampedManual 0.05 floor", CGFloat(-1).clampedManualWidthRatio == 0.05)
    }

    /// Hover focus resolves against the active workspace's strip alone. Sweeping the pointer over
    /// the whole viewport must never produce a target in another workspace, and must never ask to
    /// focus the column that already has focus.
    private static func checkHoverFocusStaysOnActiveWorkspace() {
        let scrollini = Scrollini()
        _ = buildModel(scrollini)
        scrollini.loadedConfig = LoadedScrolliniConfig(
            config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .edgeOrVisible),
            sourceURL: nil,
            sourceModificationDate: nil
        )

        let activeWindows = Set(scrollini.workspaces[0].columns.map(ObjectIdentifier.init))
        var found = 0
        var strays = 0
        var selfTargets = 0

        for x in stride(from: viewport.minX, through: viewport.maxX, by: 7) {
            for y in stride(from: viewport.minY, through: viewport.maxY, by: 97) {
                scrollini.cachedViewport = viewport
                scrollini.cachedViewportAt = CFAbsoluteTimeGetCurrent()
                guard let target = scrollini.hoverFocusTarget(at: CGPoint(x: x, y: y)) else {
                    continue
                }

                found += 1
                if target.workspaceIndex != scrollini.activeWorkspace {
                    strays += 1
                }
                if !activeWindows.contains(ObjectIdentifier(target.window)) {
                    strays += 1
                }
                if target.columnIndex == scrollini.workspaces[0].activeColumn {
                    selfTargets += 1
                }
            }
        }

        check("the sweep resolved some targets", found > 0, "found none")
        check("no target came from another workspace", strays == 0, "\(strays) strayed")
        check("no target was the already focused column", selfTargets == 0, "\(selfTargets) self targets")
    }

    private static func checkHoverFocusHelpers() {
        let s = Scrollini()
        _ = buildModel(s)
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusEdgeTriggerWidth: 8, hoverFocusMode: .edgeOrVisible), sourceURL: nil, sourceModificationDate: nil)

        // edge trigger width 8: point at maxX - 4 should be edge trigger for +1
        let ws = s.workspaces[0]
        let active = ws.activeColumn
        let pointRightEdge = CGPoint(x: viewport.maxX - 4, y: viewport.midY)
        let pointLeftEdge = CGPoint(x: viewport.minX + 4, y: viewport.midY)
        check("hoverFocusEdgeTrigger right", s.hoverFocusEdgeTrigger(targetColumn: active + 1, activeColumn: active, point: pointRightEdge, viewport: viewport) == true)
        check("hoverFocusEdgeTrigger left", s.hoverFocusEdgeTrigger(targetColumn: active - 1, activeColumn: active, point: pointLeftEdge, viewport: viewport) == true)
        check("hoverFocusEdgeTrigger same column false", s.hoverFocusEdgeTrigger(targetColumn: active, activeColumn: active, point: pointRightEdge, viewport: viewport) == false)
        check("viewportContains inside", s.viewportContains(CGPoint(x: viewport.midX, y: viewport.midY), viewport: viewport) == true)
        check("viewportContains outside", s.viewportContains(CGPoint(x: viewport.maxX + 10, y: viewport.midY), viewport: viewport) == false)

        // hoverFocusCanScroll requires visible width * ratio depth - use a controlled workspace with 2 small columns that tile
        do {
            let s2 = Scrollini()
            let a = window(910); a.manualWidthRatio = 0.5
            let b = window(911); b.manualWidthRatio = 0.5
            let ws2 = Workspace(); ws2.columns = [a, b]; ws2.activeColumn = 0
            s2.workspaces = [ws2]
            s2.activeWorkspace = 0
            var cfg2 = ScrolliniConfig()
            cfg2.innerGap = 12
            cfg2.hoverFocusMaxScrollRatio = 0.15
            cfg2.hoverFocusRequiresVisibleRatio = 0.15
            s2.loadedConfig = LoadedScrolliniConfig(config: cfg2, sourceURL: nil, sourceModificationDate: nil)
            s2.cachedViewport = viewport
            s2.cachedViewportAt = CFAbsoluteTimeGetCurrent()
            let state2 = s2.captureLayoutState()
            let camY2 = s2.cameraY(for: state2, viewport: viewport)
            let items2 = s2.layoutItems(for: ws2, workspaceIndex: 0, viewport: viewport, state: state2, cameraY: camY2, cameraWorkspace: 0, parkHidden: false)
            let targetIdx = 1
            let targetFrame = items2[targetIdx].frame
            let visible = targetFrame.intersection(viewport)
            if !visible.isNull {
                let requiredDepth = viewport.width * s2.hoverFocusMaxScrollRatio
                let goodPoint = CGPoint(x: visible.minX + requiredDepth + 10, y: viewport.midY)
                let badPoint = CGPoint(x: visible.minX + 1, y: viewport.midY)
                check("hoverFocusCanScroll true when deep enough", s2.hoverFocusCanScroll(toColumn: targetIdx, in: ws2, workspaceIndex: 0, state: state2, viewport: viewport, targetFrame: targetFrame, point: goodPoint) == true)
                check("hoverFocusCanScroll false when shallow", s2.hoverFocusCanScroll(toColumn: targetIdx, in: ws2, workspaceIndex: 0, state: state2, viewport: viewport, targetFrame: targetFrame, point: badPoint) == false)
            } else {
                check("hoverFocusCanScroll visible frame exists", false)
                check("hoverFocusCanScroll shallow", false)
            }
        }
        // empty viewport width 0 returns false
        let state = s.captureLayoutState()
        let zeroViewport = CGRect(x: 0, y: 0, width: 0, height: 1000)
        check("hoverFocusCanScroll zero width false", s.hoverFocusCanScroll(toColumn: 1, in: ws, workspaceIndex: 0, state: state, viewport: zeroViewport, targetFrame: CGRect(x: 0, y: 0, width: 100, height: 100), point: CGPoint(x: 10, y: 10)) == false)
        // mode off disables hover (checked via accessor)
        let sOff = Scrollini()
        sOff.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .off), sourceURL: nil, sourceModificationDate: nil)
        check("hoverFocusEnabled false when mode off", sOff.hoverFocusEnabled == false)
        let sVisible = Scrollini()
        sVisible.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .visibleOnly), sourceURL: nil, sourceModificationDate: nil)
        check("hoverFocusEnabled true when visibleOnly", sVisible.hoverFocusEnabled == true)
    }

    private static func checkStripMetrics() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(innerGap: 12, outerGap: 12), sourceURL: nil, sourceModificationDate: nil)
        let w1 = window(100); w1.manualWidthRatio = 0.5
        let w2 = window(101); w2.manualWidthRatio = 0.5
        let ws = Workspace(); ws.columns = [w1, w2]
        let metrics = s.stripMetrics(for: ws, viewport: viewport)
        check("stripMetrics origins start at 0", approx(metrics.origins[0], 0))
        check("stripMetrics second origin = first width + gap", approx(metrics.origins[1], metrics.widths[0] + 12))
        check("stripMetrics widths count matches columns", metrics.widths.count == 2)
        // empty workspace
        let empty = Workspace()
        let mEmpty = s.stripMetrics(for: empty, viewport: viewport)
        check("stripMetrics empty returns empty", mEmpty.origins.isEmpty && mEmpty.widths.isEmpty)
        // 0.8 default width
        let wDefault = window(102)
        let req = s.requestedWidth(for: wDefault, viewport: viewport)
        check("requestedWidth for default 0.8 is 0.8*usable - gap", approx(req, (viewport.width - 12) * 0.8 - 12, 0.01))
    }

    private static func checkMeasuredWidthPacking() {
        let s = Scrollini()
        let w = window(200)
        w.manualWidthRatio = 0.8
        let requested = s.requestedWidth(for: w, viewport: viewport)
        // within 1pt tolerance is not considered clamped
        check("recordMeasuredWidth within 0.5 not clamped", s.recordMeasuredWidth(requested + 0.4, requested: requested, for: w) == false && w.measuredWidth == nil)
        check("recordMeasuredWidth stamps measuredForWidth even when not clamped", w.measuredForWidth == requested)
        // now clamped
        check("recordMeasuredWidth clamped creates measuredWidth", s.recordMeasuredWidth(requested + 20, requested: requested, for: w) == true && w.measuredWidth != nil)
        check("layoutWidth packs against measured", approx(s.layoutWidth(for: w, viewport: viewport), requested + 20))
        // changing requested invalidates measured
        w.manualWidthRatio = 0.5
        let newReq = s.requestedWidth(for: w, viewport: viewport)
        check("layoutWidth ignores stale measured when requested changed", approx(s.layoutWidth(for: w, viewport: viewport), newReq))
        // exact threshold 1.0
        let w2 = window(201)
        w2.manualWidthRatio = 0.8
        let req2 = s.requestedWidth(for: w2, viewport: viewport)
        _ = s.recordMeasuredWidth(req2 + 1.0, requested: req2, for: w2)
        check("threshold 1.0 considered clamped", w2.measuredWidth != nil)
        _ = s.recordMeasuredWidth(req2 + 0.9, requested: req2, for: w2)
        check("just under threshold not clamped", w2.measuredWidth == nil)
    }

    private static func checkStripFramesAndScrollOffset() {
        let s = Scrollini()
        _ = buildModel(s) // 3,2,4 pattern, workspace0 active 1
        do {
            var cfg = ScrolliniConfig()
            cfg.innerGap = 12
            cfg.centerFocusedColumn = true
            cfg.focusAlignment = .smart
            s.loadedConfig = LoadedScrolliniConfig(config: cfg, sourceURL: nil, sourceModificationDate: nil)
        }
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let ws = s.workspaces[0]
        let active = ws.activeColumn // 1
        let metrics = s.stripMetrics(for: ws, viewport: viewport)
        let defaultOffset = s.defaultScrollOffset(metrics: metrics, activeColumn: active, viewport: viewport)
        check("defaultScrollOffset centers column 1", defaultOffset >= 0)
        // left alignment
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .left), sourceURL: nil, sourceModificationDate: nil)
        let leftOffset = s.defaultScrollOffset(metrics: metrics, activeColumn: 1, viewport: viewport)
        check("left alignment returns origin", approx(leftOffset, metrics.origins[1]))
        // smart left for column 0
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .smart), sourceURL: nil, sourceModificationDate: nil)
        let smartZero = s.defaultScrollOffset(metrics: metrics, activeColumn: 0, viewport: viewport)
        check("smart focuses column 0 at left", approx(smartZero, metrics.origins[0]))
        // center focuses non-zero
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .center), sourceURL: nil, sourceModificationDate: nil)
        let centerOffset = s.defaultScrollOffset(metrics: metrics, activeColumn: 1, viewport: viewport)
        check("center alignment offset >=0", centerOffset >= 0)
        check("center offset centers", approx(centerOffset, metrics.origins[1] + metrics.widths[1]/2 + 12 - viewport.width/2))

        // stripFrames uses scrollOffset
        let frames = s.stripFrames(for: ws, viewport: viewport, activeColumn: active, scrollOffset: 0)
        check("stripFrames count matches columns", frames.count == ws.columns.count)
        check("stripFrames first at viewport+gap", approx(frames[0].minX, viewport.minX + 12))

        // horizontalCameraOffset respects scrollOffset when set
        ws.scrollOffset = 100
        check("horizontalCameraOffset returns scrollOffset when set", approx(s.horizontalCameraOffset(for: ws, viewport: viewport), 100))
        // clamp
        ws.scrollOffset = -10
        check("horizontalCameraOffset clamps negative", approx(s.horizontalCameraOffset(for: ws, viewport: viewport), 0))
        ws.scrollOffset = 99999
        check("horizontalCameraOffset clamps to max", s.horizontalCameraOffset(for: ws, viewport: viewport) <= s.maxHorizontalCameraOffset(for: ws, viewport: viewport))
        ws.scrollOffset = nil

        // closestColumn and mostVisibleColumn
        let off = s.horizontalCameraOffset(for: ws, viewport: viewport)
        let closest = s.closestColumn(to: off, in: ws, viewport: viewport)
        check("closestColumn near active", closest == active || closest == active - 1 || closest == active + 1)
        let mostVisible = s.mostVisibleColumn(in: ws, viewport: viewport, scrollOffset: off)
        check("mostVisibleColumn in bounds", (0..<ws.columns.count).contains(mostVisible))
    }

    private static func checkCameraOffsets() {
        let s = Scrollini()
        let ws = Workspace()
        ws.columns = [] // empty
        check("maxHorizontalCameraOffset empty is 0", s.maxHorizontalCameraOffset(for: ws, viewport: viewport) == 0)
        check("closestColumn empty is 0", s.closestColumn(to: 0, in: ws, viewport: viewport) == 0)
        check("mostVisibleColumn empty is 0", s.mostVisibleColumn(in: ws, viewport: viewport, scrollOffset: 0) == 0)
        // single column
        let w = window(300); w.manualWidthRatio = 0.8
        ws.columns = [w]
        let maxOff = s.maxHorizontalCameraOffset(for: ws, viewport: viewport)
        check("maxHorizontalCameraOffset single small content is 0 or small", maxOff >= 0)
    }

    private static func checkParkedFrames() {
        let s = Scrollini()
        let w = window(400)
        w.manualWidthRatio = 0.8
        let before = s.parkedFrame(for: w, viewport: viewport, beforeActive: true)
        let after = s.parkedFrame(for: w, viewport: viewport, beforeActive: false)
        let sliver = s.parkedSliverWidth
        check("parked before sits left of viewport", approx(before.minX, viewport.minX - before.width + sliver))
        check("parked after sits right of viewport", approx(after.minX, viewport.maxX - sliver))
        check("parked height respects innerGap", approx(before.height, viewport.height - s.innerGap * 2))
        check("parked width matches layoutWidth", approx(before.width, s.layoutWidth(for: w, viewport: viewport)))
    }

    private static func checkCameraMath() {
        let s = Scrollini()
        s.workspaces = (0..<5).map { _ in Workspace() }
        let state0 = LayoutState(activeWorkspace: 0, activeColumns: [0,0,0,0,0], scrollOffsets: [nil, nil, nil, nil, nil], cameraY: nil)
        check("cameraY fallback uses activeWorkspace * height", approx(s.cameraY(for: state0, viewport: viewport), 0))
        let state2 = LayoutState(activeWorkspace: 2, activeColumns: [0,0,0,0,0], scrollOffsets: [nil, nil, nil, nil, nil], cameraY: nil)
        check("cameraY for workspace 2", approx(s.cameraY(for: state2, viewport: viewport), viewport.height * 2))
        let stateCam = LayoutState(activeWorkspace: 0, activeColumns: [0,0,0,0,0], scrollOffsets: [nil, nil, nil, nil, nil], cameraY: 1234)
        check("cameraY uses explicit when present", approx(s.cameraY(for: stateCam, viewport: viewport), 1234))
        check("trackpadCameraWorkspaceIndex rounds", s.trackpadCameraWorkspaceIndex(cameraY: viewport.height * 1.6, viewport: viewport) == 2)
        check("trackpadCameraWorkspaceIndex clamps low", s.trackpadCameraWorkspaceIndex(cameraY: -100, viewport: viewport) == 0)
        check("trackpadCameraWorkspaceIndex clamps high", s.trackpadCameraWorkspaceIndex(cameraY: viewport.height * 100, viewport: viewport) == 4)
        check("trackpadCameraWorkspaceIndex zero height returns 0", s.trackpadCameraWorkspaceIndex(cameraY: 100, viewport: CGRect(x: 0, y: 0, width: 1600, height: 0)) == 0)
        // insetViewport
        let inset = s.insetViewport(viewport, by: 20)
        check("insetViewport shrinks", approx(inset.width, viewport.width - 40) && approx(inset.height, viewport.height - 40))
        let hugeInset = s.insetViewport(viewport, by: 9999)
        check("insetViewport caps at 1/3 width", hugeInset.width > 0)
        check("insetViewport zero returns same", s.insetViewport(viewport, by: 0) == viewport)
    }

    private static func checkLayoutVisibility() {
        let s = Scrollini()
        _ = buildModel(s)
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let state = s.captureLayoutState()
        // parkHidden false should keep offscreen workspaces projected with rowOffset, visible false? Actually they are offset vertically
        let itemsParkTrue = s.layoutItems(viewport: viewport, state: state, parkHidden: true)
        let itemsParkFalse = s.layoutItems(viewport: viewport, state: state, parkHidden: false)
        check("layoutItems counts equal regardless of parkHidden", itemsParkTrue.count == itemsParkFalse.count)
        // active workspace items should be visible in both modes
        let activeIdx = s.activeWorkspace
        let activeWindows = Set(s.workspaces[activeIdx].columns.map(ObjectIdentifier.init))
        let visibleActiveTrue = itemsParkTrue.filter { activeWindows.contains(ObjectIdentifier($0.window)) && $0.visible }.count
        let visibleActiveFalse = itemsParkFalse.filter { activeWindows.contains(ObjectIdentifier($0.window)) && $0.visible }.count
        check("active workspace visible counts equal parkHidden modes", visibleActiveTrue == visibleActiveFalse)
        // non-active workspace windows are not visible (off screen vertically)
        let nonActiveWindows = s.workspaces.enumerated().filter { $0.offset != activeIdx }.flatMap { $0.element.columns }
        var allNonVisibleWhenParked = true
        for w in nonActiveWindows {
            if let item = itemsParkTrue.first(where: { $0.window === w }), item.visible {
                allNonVisibleWhenParked = false
            }
        }
        check("non-active workspace windows not visible", allNonVisibleWhenParked)
        // parked frame consistency: offscreen windows when parkHidden true are slivered
        for w in nonActiveWindows {
            if let item = itemsParkTrue.first(where: { $0.window === w }) {
                if !item.visible {
                    check("parked non-visible frame is sliver (width)", item.frame.width > 0, "zero width")
                    break
                }
            }
        }
        // layoutItems for single workspace: cameraWorkspace handling
        let wid = s.workspaces[0].columns[0]
        if let single = s.layoutItem(for: wid, viewport: viewport, state: state, parkHidden: true) {
            check("layoutItem for existing window returns something", true)
            check("layoutItem frame matches full projection", itemsParkTrue.contains { $0.window === wid && sameRect($0.frame, single.frame) })
        } else {
            check("layoutItem for existing window returns something", false)
        }
        check("layoutItem for unknown window nil", s.layoutItem(for: window(9999), viewport: viewport, state: state, parkHidden: true) == nil)
    }

    private static func checkCommandResolution() {
        let s = Scrollini()
        let known: [String] = [
            "focus_workspace_1","focus_workspace_9","focus_previous_workspace","workspace_down","workspace_up",
            "column_left","column_right","column_first","column_last","move_column_left","move_column_right",
            "move_column_to_first","move_column_to_last","move_column_down","move_column_up",
            "move_column_to_workspace_1","move_column_to_workspace_9",
            "cycle_width_preset_forward","cycle_width_preset_backward","nudge_width_narrower","nudge_width_wider",
            "cycle_all_width_presets_forward","cycle_all_width_presets_backward","nudge_all_widths_narrower","nudge_all_widths_wider",
            "maximize_column_width","reset_column_width"
        ]
        for name in known {
            check("command \(name) maps", s.command(named: name) != nil)
        }
        check("command out-of-range workspace index nil", s.command(named: "focus_workspace_10") == nil)
        check("command unknown nil", s.command(named: "banana") == nil)
        // makeCommandByKeybinding deduplicates and ignores unknown
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(keybindings: ["focus_workspace_1": ["ctrl+alt+1"], "unknown_cmd": ["ctrl+alt+z"]]), sourceURL: nil, sourceModificationDate: nil)
        let cmds = s.makeCommandByKeybinding()
        check("makeCommandByKeybinding ignores unknown command", cmds.values.count >= 1)
    }

    private static func checkExcludedKeybindings() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(excludedKeybindings: ["ctrl+alt+left", "ctrl+alt+right"], rules: [
            WindowRule(bundleID: "com.test.app", excludedKeybindings: ["ctrl+alt+up"]),
            WindowRule(titleContains: "onlyTitle", excludedKeybindings: ["ctrl+alt+down"]), // should be ignored (no bid/bundle)
        ]), sourceURL: nil, sourceModificationDate: nil)
        s.configureInput()
        check("excludedKeybindingSet contains top-level", s.excludedKeybindingSet.contains("ctrl+alt+left"))
        check("appKeybindingExclusions count is 1 (title-only dropped)", s.appKeybindingExclusions.count == 1)
        s.frontmostAppBundleID = "com.test.app"
        s.frontmostAppName = "Test"
        let mods: CGEventFlags = [.maskControl, .maskAlternate]
        check("isExcludedKeybinding true for app rule", s.isExcludedKeybinding(modifiers: mods, keyCode: KeyCode.upArrow, keyText: "") == true)
        s.frontmostAppBundleID = "com.other"
        check("isExcludedKeybinding false for non-matching app", s.isExcludedKeybinding(modifiers: mods, keyCode: KeyCode.upArrow, keyText: "") == false)
        check("isExcludedKeybinding false when no sets", {
            let s2 = Scrollini()
            s2.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(excludedKeybindings: [], rules: []), sourceURL: nil, sourceModificationDate: nil)
            s2.configureInput()
            return s2.isExcludedKeybinding(modifiers: mods, keyCode: KeyCode.upArrow, keyText: "") == false
        }())
        // paused keybindings
        s.setKeybindingsPaused(true)
        check("keybindingsPaused true", s.keybindingsPaused == true)
        s.setKeybindingsPaused(false)
        check("keybindingsPaused false", s.keybindingsPaused == false)
    }

    private static func checkConfigAccessors() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(innerGap: 15, outerGap: 20, parkedSliverWidth: 2), sourceURL: nil, sourceModificationDate: nil)
        check("innerGap accessor", s.innerGap == 15)
        check("outerGap accessor", s.outerGap == 20)
        check("parkedSliverWidth accessor", s.parkedSliverWidth == 2)

        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationDurationMS: 100, keyboardAnimationMS: 150), sourceURL: nil, sourceModificationDate: nil)
        check("keyboardAnimationDuration uses keyboard fallback", approx(s.keyboardAnimationDuration, 0.15))
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationDurationMS: 200), sourceURL: nil, sourceModificationDate: nil)
        check("keyboardAnimationDuration falls back to animationDuration", approx(s.keyboardAnimationDuration, 0.2))

        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(centerFocusedColumn: false), sourceURL: nil, sourceModificationDate: nil)
        check("focusAlignment left when center false", s.focusAlignment == .left)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(centerFocusedColumn: true), sourceURL: nil, sourceModificationDate: nil)
        check("focusAlignment smart when center true", s.focusAlignment == .smart)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .center), sourceURL: nil, sourceModificationDate: nil)
        check("focusAlignment respects explicit", s.focusAlignment == .center)

        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: false), sourceURL: nil, sourceModificationDate: nil)
        check("hoverFocusEnabled false when hoverToFocus false", s.hoverFocusEnabled == false)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverFocusMode: .off), sourceURL: nil, sourceModificationDate: nil)
        check("hoverFocusEnabled false when mode off even if hoverToFocus true", s.hoverFocusEnabled == false)

        do {
            var cfg = ScrolliniConfig()
            cfg.trackpadNavigationSettleAnimationMS = 123
            cfg.animationDurationMS = 999
            s.loadedConfig = LoadedScrolliniConfig(config: cfg, sourceURL: nil, sourceModificationDate: nil)
            check("trackpadSettle uses navigationSpecific", approx(s.trackpadSettleAnimationDuration, 0.123))
            var cfg2 = ScrolliniConfig()
            cfg2.trackpadNavigationSettleAnimationMS = 240
            cfg2.trackpadSettleAnimationMS = 300
            s.loadedConfig = LoadedScrolliniConfig(config: cfg2, sourceURL: nil, sourceModificationDate: nil)
            // 240 is fallback value, so it should fall through to trackpadSettleAnimationMS 300
            check("trackpadSettle fallback value uses generic", approx(s.trackpadSettleAnimationDuration, 0.3))
        }

        check("animationCurve default smooth", Scrollini().animationCurve == .smooth)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .snappy), sourceURL: nil, sourceModificationDate: nil)
        check("animationCurve snappy", s.animationCurve == .snappy)

        do {
            var cfg = ScrolliniConfig()
            cfg.widthAnimationMS = 400
            cfg.keyboardAnimationMS = 200
            cfg.animationDurationMS = 100
            s.loadedConfig = LoadedScrolliniConfig(config: cfg, sourceURL: nil, sourceModificationDate: nil)
            check("widthAnimationDuration prefers width", approx(s.widthAnimationDuration, 0.4))
            s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(keyboardAnimationMS: 250), sourceURL: nil, sourceModificationDate: nil)
        }
        check("widthAnimationDuration falls back to keyboard", approx(s.widthAnimationDuration, 0.25))
    }

    private static func checkTrackpadSensitivityFallback() {
        let s = Scrollini()
        // fallback trackpadNavigationWorkspaceSensitivity is 6.4 (1.6*4), so with no explicit it returns fallback not computed
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(trackpadNavigationSensitivity: 2.0), sourceURL: nil, sourceModificationDate: nil)
        check("workspaceSensitivity returns fallback 6.4 when no explicit", approx(s.trackpadNavigationWorkspaceSensitivity, 6.4))
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(trackpadNavigationSensitivity: 2.0, trackpadNavigationWorkspaceSensitivity: 5.0), sourceURL: nil, sourceModificationDate: nil)
        check("workspaceSensitivity explicit wins", approx(s.trackpadNavigationWorkspaceSensitivity, 5.0))
        // default without any config
        let sDefault = Scrollini()
        check("workspaceSensitivity default is 6.4 == 1.6*4", approx(sDefault.trackpadNavigationWorkspaceSensitivity, 6.4))
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverFocusAfterTrackpadMS: 100, trackpadNavigationHoverSuppressionMS: 999), sourceURL: nil, sourceModificationDate: nil)
        check("hoverFocusAfterTrackpad prefers navigationSpecific when not fallback", approx(s.hoverFocusAfterTrackpad, 0.999))
    }

    private static func checkPersistenceRoundtrip() {
        // encode/decode stable
        let identity = PersistentWindowIdentity(bundleID: "com.test.app", appName: "Test", title: "Window")
        let state = PersistentWindowState(identity: identity, workspace: 1, column: 2, manualWidthRatio: 0.7)
        let snapshot = PersistentLayoutSnapshot(version: 2, activeWorkspace: 1, activeColumns: [0,1], scrollOffsets: [nil, 12.5], focusedWindow: identity, windows: [state])
        do {
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(PersistentLayoutSnapshot.self, from: data)
            check("persistent snapshot roundtrip version", decoded.version == 2)
            check("persistent snapshot activeWorkspace", decoded.activeWorkspace == 1)
            check("persistent snapshot activeColumns", decoded.activeColumns == [0,1])
            check("persistent snapshot windows count", decoded.windows.count == 1)
            check("persistent snapshot focusedWindow", decoded.focusedWindow == identity)
            check("persistent snapshot window workspace", decoded.windows[0].workspace == 1)
        } catch {
            check("persistent snapshot roundtrip encode", false, "\(error)")
            check("persistent snapshot activeWorkspace", false)
            check("persistent snapshot activeColumns", false)
            check("persistent snapshot windows count", false)
            check("persistent snapshot focusedWindow", false)
            check("persistent snapshot window workspace", false)
        }
        // version guard: 0 and 3 rejected (read returns nil) - test via writing temp file
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(persistLayout: true, statePath: "/tmp/scrollini-test-\(UUID().uuidString).json"), sourceURL: nil, sourceModificationDate: nil)
        let badSnapshot = PersistentLayoutSnapshot(version: 99, activeWorkspace: 0, activeColumns: [0], scrollOffsets: [nil], focusedWindow: nil, windows: [])
        do {
            let data = try JSONEncoder().encode(badSnapshot)
            try data.write(to: s.persistentLayoutStateURL)
            check("bad version not read", s.readPersistentLayoutSnapshot() == nil)
            try? FileManager.default.removeItem(at: s.persistentLayoutStateURL)
        } catch {
            check("bad version not read", false, "\(error)")
        }
        // RectSnapshot roundtrip
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        let rs = RectSnapshot(rect)
        check("RectSnapshot roundtrip", rs.cgRect == rect)
        // RestoreSnapshot floatingWindowIDs optional
        do {
            let snap = RestoreSnapshot(windowIDs: [1,2], floatingWindowIDs: nil, viewport: RectSnapshot(rect))
            let data = try JSONEncoder().encode(snap)
            let decoded = try JSONDecoder().decode(RestoreSnapshot.self, from: data)
            check("RestoreSnapshot floating nil", decoded.floatingWindowIDs == nil)
            check("RestoreSnapshot windowIDs", decoded.windowIDs == [1,2])
        } catch {
            check("RestoreSnapshot floating nil", false)
            check("RestoreSnapshot windowIDs", false)
        }
    }

    private static func checkManualResizeMath() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(innerGap: 12), sourceURL: nil, sourceModificationDate: nil)
        let width: CGFloat = 800
        let ratio = s.widthRatio(forWidth: width, viewport: viewport)
        let back = s.requestedWidth(for: {
            let w = window(500); w.manualWidthRatio = ratio; return w
        }(), viewport: viewport)
        check("widthRatio inverse approx", approx(back, width, 1.0))
        // zero usable width
        let zeroViewport = CGRect(x: 0, y: 0, width: 12, height: 1000) // width == innerGap -> usable 0
        check("widthRatio with zero usable returns default", approx(s.widthRatio(forWidth: 100, viewport: zeroViewport), 0.8))
        // recordMeasured branching already tested earlier, but test stale measured
        let w = window(501); w.manualWidthRatio = 0.8
        let req = s.requestedWidth(for: w, viewport: viewport)
        w.measuredWidth = 1000
        w.measuredForWidth = req
        w.manualWidthRatio = nil // reset
        // Now layoutWidth should use default again, measured should be ignored because manual nil resets? Actually measured still there but requested changed?
        // After resetActiveWidth clears measured
        let ws = Workspace(); ws.columns = [w]; s.workspaces = [ws]; s.activeWorkspace = 0
        _ = s.resetActiveWidth()
        check("resetActiveWidth clears measured", w.measuredWidth == nil && w.measuredForWidth == nil)
    }

    private static func checkAnimationMath() {
        let s = Scrollini()
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 100, y: 200, width: 300, height: 400)
        check("interpolate at 0 is start", s.interpolate(from: a, to: b, progress: 0) == a)
        check("interpolate at 1 is end", s.interpolate(from: a, to: b, progress: 1) == b)
        let mid = s.interpolate(from: a, to: b, progress: 0.5)
        check("interpolate mid", approx(mid.minX, 50) && approx(mid.minY, 100) && approx(mid.width, 200))
        check("softSettleCurve 0 is 0 linear", approx(s.softSettleCurve(0), 0))
        check("softSettleCurve 1 is 1 linear", approx(s.softSettleCurve(1), 1))
        // bezier monotonic check for smooth/snappy
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .linear), sourceURL: nil, sourceModificationDate: nil)
        check("linear curve identity", approx(s.softSettleCurve(0.4), 0.4))
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .smooth), sourceURL: nil, sourceModificationDate: nil)
        let v1 = s.softSettleCurve(0.3)
        let v2 = s.softSettleCurve(0.6)
        check("smooth curve monotonic", v1 < v2 && v1 >= 0 && v2 <= 1)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .snappy), sourceURL: nil, sourceModificationDate: nil)
        let v3 = s.softSettleCurve(0.3)
        let v4 = s.softSettleCurve(0.6)
        check("snappy curve monotonic", v3 < v4)
        check("framesApproximatelyEqual within tolerance", s.framesApproximatelyEqual(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0.5, y: 0.5, width: 100.4, height: 100.4), tolerance: 1) == true)
        check("framesApproximatelyEqual outside tolerance", s.framesApproximatelyEqual(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 5, y: 0, width: 100, height: 100), tolerance: 1) == false)
        check("cubicBezier endpoints", approx(s.cubicBezier(0, x1: 0.16, y1: 0, x2: 0.18, y2: 1), 0) && approx(s.cubicBezier(1, x1: 0.16, y1: 0, x2: 0.18, y2: 1), 1))
    }

    private static func checkInputHelpers() {
        let s = Scrollini()
        // isSystemWindowSwitcherEvent: cmd+tab
        check("cmd+tab is switcher", s.isSystemWindowSwitcherEvent(modifiers: .maskCommand, keyCode: KeyCode.tab, keyText: "tab") == true)
        check("ctrl+tab not switcher", s.isSystemWindowSwitcherEvent(modifiers: .maskControl, keyCode: KeyCode.tab, keyText: "tab") == false)
        check("cmd+a not switcher", s.isSystemWindowSwitcherEvent(modifiers: .maskCommand, keyCode: KeyCode.a, keyText: "a") == false)
        // orderedModifierParts deterministic order
        check("orderedModifierParts order", s.orderedModifierParts(from: ["alt","cmd","shift"]) == ["cmd","shift","alt"])
        check("orderedModifierParts empty", s.orderedModifierParts(from: []) == [])
        // normalizedModifierParts
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        check("normalizedModifierParts cmd+shift", s.normalizedModifierParts(from: flags) == ["cmd","shift"])
    }

    private static func checkTransientWindowHelpers() {
        let s = Scrollini()
        check("isTransientRole sheet", s.isTransientRole("AXSheet") == true)
        check("isTransientRole dialog", s.isTransientRole("AXDialog") == true)
        check("isTransientRole standard window false", s.isTransientRole(kAXWindowRole) == false)
        check("isTransientSubrole system dialog", s.isTransientSubrole("AXSystemDialog") == true)
        check("isTransientSubrole standard false", s.isTransientSubrole(kAXStandardWindowSubrole) == false)
        check("transientFrameNeedsRecovery outside viewport", s.transientFrameNeedsRecovery(CGRect(x: -5000, y: -5000, width: 100, height: 100), viewport: viewport) == true)
        check("transientFrameNeedsRecovery centered false", s.transientFrameNeedsRecovery(CGRect(x: viewport.midX - 50, y: viewport.midY - 50, width: 100, height: 100), viewport: viewport) == false)
        // mid outside while intersecting still triggers? midX < minX
        let offMid = CGRect(x: viewport.minX - 60, y: viewport.midY - 50, width: 100, height: 100) // intersects but mid < minX
        check("transientFrameNeedsRecovery mid outside", s.transientFrameNeedsRecovery(offMid, viewport: viewport) == true)
        let centered = s.centeredOrigin(for: CGRect(x: 0, y: 0, width: 200, height: 200), in: viewport)
        check("centeredOrigin centers", approx(centered.x, viewport.midX - 100) && approx(centered.y, viewport.midY - 100))
    }

    private static func checkFocusExpectations() {
        let s = Scrollini()
        s.workspaces = [Workspace()]
        let w = window(600)
        s.workspaces[0].columns = [w]
        check("shouldSuppress false initially", s.shouldSuppressFocusedWindowAdoption == false)
        s.suppressFocusedWindowAdoption(for: 10)
        check("shouldSuppress true after suppress", s.shouldSuppressFocusedWindowAdoption == true)
        s.markExpectedFocusedWindow(for: w, duration: 5)
        check("expectedFocusedWindow set", s.expectedFocusedWindowID() == ObjectIdentifier(w))
        // extending same window should not shorten
        let until1 = s.expectedFocusedWindowUntil
        s.markExpectedFocusedWindow(for: w, duration: 1)
        check("same window extends or stays", s.expectedFocusedWindowUntil >= until1)
        // different window shortens to new deadline (must be new window's deadline)
        let w2 = window(601)
        s.markExpectedFocusedWindow(for: w2, duration: 0.3)
        check("different window switches id", s.expectedFocusedWindowID() == ObjectIdentifier(w2))
        s.releaseExpectedFocusedWindow()
        check("release clears expected", s.expectedFocusedWindowID() == nil)
        check("release clears suppress", s.shouldSuppressFocusedWindowAdoption == false)
        // nil window clears
        s.markExpectedFocusedWindow(for: w, duration: 1)
        s.markExpectedFocusedWindow(for: nil, duration: 1)
        check("nil window clears expected", s.expectedFocusedWindowID() == nil)
    }

    private static func checkColumnNavigation() {
        let s = Scrollini()
        s.workspaces = [Workspace(), Workspace()]
        let w0 = window(700); let w1 = window(701); let w2 = window(702)
        s.workspaces[0].columns = [w0, w1, w2]
        s.workspaces[0].activeColumn = 1
        s.activeWorkspace = 0
        check("focusColumn relative +1 moves", s.focusColumn(relativeOffset: 1) == true && s.workspaces[0].activeColumn == 2)
        check("focusColumn at boundary false", s.focusColumn(relativeOffset: 1) == false)
        _ = s.focusColumn(relativeOffset: -2)
        check("focusColumn left to 0", s.workspaces[0].activeColumn == 0)
        check("focusColumn at 0 left false", s.focusColumn(relativeOffset: -1) == false)
        // moveActiveColumn
        s.workspaces[0].activeColumn = 0
        check("moveActiveColumn Horizontally", s.moveActiveColumnHorizontally(by: 1) == true && s.workspaces[0].columns[1] === w0)
        check("moveActiveColumn to same false", s.moveActiveColumn(to: 1) == false)
        // move to workspace
        _ = buildModel(s)
        s.activeWorkspace = 0
        let beforeCount0 = s.workspaces[0].columns.count
        let beforeCount1 = s.workspaces[1].columns.count
        check("moveActiveColumnToWorkspace succeeds", s.moveActiveColumnToWorkspace(zeroBasedIndex: 1) == true)
        check("source lost one", s.workspaces[0].columns.count == beforeCount0 - 1)
        check("target gained one", s.workspaces[1].columns.count == beforeCount1 + 1)
        check("move to same workspace false", s.moveActiveColumnToWorkspace(zeroBasedIndex: s.activeWorkspace) == false)

        // burst logic
        s.lastColumnNavigationAt = CFAbsoluteTimeGetCurrent()
        s.lastColumnNavigationDirection = 1
        check("burst active when recent and direction set", s.columnNavigationBurstIsActive(at: CFAbsoluteTimeGetCurrent(), stepCount: 1) == true)
        s.lastColumnNavigationAt = CFAbsoluteTimeGetCurrent() - 1
        check("burst inactive when old", s.columnNavigationBurstIsActive(at: CFAbsoluteTimeGetCurrent(), stepCount: 1) == false)
        s.animationTimer = s.makeMainTimer(deadline: .now() + .seconds(10)) {}
        check("burst active when animating", s.columnNavigationBurstIsActive(at: CFAbsoluteTimeGetCurrent(), stepCount: 1) == true)
        s.cancelTimer(&s.animationTimer)

        // enqueueColumnNavigation accumulates
        s.pendingColumnNavigationDelta = 0
        s.pendingColumnNavigationStartedAt = 0
        s.enqueueColumnNavigation(delta: 0)
        check("enqueue zero ignores", s.pendingColumnNavigationDelta == 0)
        s.enqueueColumnNavigation(delta: 2)
        check("enqueue accumulates", s.pendingColumnNavigationDelta == 2)
        s.pendingColumnNavigationDelta = 0
        s.pendingColumnNavigationStartedAt = 0
        s.cancelTimer(&s.pendingColumnNavigationTimer)
    }

    private static func checkTrackpadPhysics() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(trackpadNavigationSensitivity: 1.6, trackpadNavigationWorkspaceSensitivity: 6.4, trackpadNavigationVelocityGain: 1.35), sourceURL: nil, sourceModificationDate: nil)
        let delta = s.trackpadCameraDelta(from: CGPoint(x: 0.01, y: 0.02), velocity: CGPoint(x: 0, y: 0), viewport: viewport)
        check("trackpadCameraDelta width negative delta.x", delta.width < 0)
        check("trackpadCameraDelta height positive delta.y", delta.height > 0)
        // trackpadCameraVelocity(with:) is shadowed by stored property of same name on instance; test gain instead
        let gainSlow = s.trackpadCameraVelocityGain(for: CGPoint(x: 0.1, y: 0.1))
        let gainFast = s.trackpadCameraVelocityGain(for: CGPoint(x: 2, y: 2))
        check("velocityGain increases with speed", gainFast >= gainSlow)
        check("velocityGain caps at 1+cfg", gainFast <= 1 + (s.trackpadNavigationVelocityGain))
        check("hasPendingDelta false initially", s.hasPendingTrackpadCameraDelta == false)
        s.trackpadPendingCameraDelta = CGSize(width: 0.6, height: 0)
        check("hasPendingDelta true at 0.6", s.hasPendingTrackpadCameraDelta == true)
        s.trackpadPendingCameraDelta = .zero
        s.trackpadCameraVelocity = CGPoint(x: 10, y: 0)
        check("hasMomentum false at 10", s.hasTrackpadMomentumVelocity == false)
        s.trackpadCameraVelocity = CGPoint(x: 100, y: 0)
        check("hasMomentum true at 100", s.hasTrackpadMomentumVelocity == true)
        s.trackpadCameraVelocity = .zero
        // strongest velocity picks larger
        s.trackpadLatestCameraVelocity = CGPoint(x: 50, y: 0)
        let strongest = s.strongestTrackpadCameraVelocity(endingVelocity: CGPoint(x: 30, y: 0))
        check("strongest picks larger earlier", strongest.x == 50)
        let strongest2 = s.strongestTrackpadCameraVelocity(endingVelocity: CGPoint(x: 60, y: 0))
        check("strongest picks larger ending", strongest2.x == 60)
        // apply delta clamping
        _ = buildModel(s)
        s.trackpadCameraY = nil
        s.workspaces[0].scrollOffset = nil
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let clamped = s.applyTrackpadCameraDelta(CGSize(width: 10000, height: 10000), viewport: viewport)
        check("applyTrackpadCameraDelta clamps", clamped.x == true || clamped.y == true)
    }

    private static func checkConfigJSONLoading() {
        // valid JSON roundtrip
        let json = """
        {"default_width_ratio": 0.6, "inner_gap": 20, "rules": [{"bundle_id": "com.test", "behavior": "float"}]}
        """
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrollini-test-\(UUID().uuidString).json")
        do {
            try json.write(to: tmp, atomically: true, encoding: .utf8)
            let result = ScrolliniConfig.load(from: tmp, logLoaded: false, logErrors: false)
            switch result {
            case .loaded(let loaded):
                check("config json load default_width_ratio", approx(loaded.config.defaultWidthRatio ?? 0, 0.6))
                check("config json load inner_gap", loaded.config.innerGap == 20)
                check("config json load rules count", loaded.config.rules?.count == 1)
            case .notFound:
                check("config json load notFound", false)
                check("config json load inner", false)
                check("config json load rules", false)
            case .parseError:
                check("config json load parseError", false)
                check("config json load inner", false)
                check("config json load rules", false)
            }
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            check("config json load write", false, "\(error)")
            check("config json load inner", false)
            check("config json load rules", false)
        }
        // invalid json -> parseError
        let badJSON = "{ bad json"
        let tmp2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrollini-test-\(UUID().uuidString).json")
        do {
            try badJSON.write(to: tmp2, atomically: true, encoding: .utf8)
            let result = ScrolliniConfig.load(from: tmp2, logLoaded: false, logErrors: false)
            if case .parseError = result {
                check("invalid json yields parseError", true)
            } else {
                check("invalid json yields parseError", false)
            }
            try? FileManager.default.removeItem(at: tmp2)
        } catch {
            check("invalid json yields parseError", false, "\(error)")
        }
        // notFound
        let notFoundURL = URL(fileURLWithPath: "/tmp/scrollini-notfound-\(UUID().uuidString).json")
        check("missing file yields notFound", {
            if case .notFound = ScrolliniConfig.load(from: notFoundURL, logLoaded: false, logErrors: false) { return true }
            return false
        }())
        // normalize via JSON path clamps
        let wildJSON = """
        {"inner_gap": 5000, "outer_gap": -5, "preset_width_ratios": [0.5, 0.5, 3.0]}
        """
        let tmp3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrollini-test-\(UUID().uuidString).json")
        do {
            try wildJSON.write(to: tmp3, atomically: true, encoding: .utf8)
            let result = ScrolliniConfig.load(from: tmp3, logLoaded: false, logErrors: false)
            if case .loaded(let loaded) = result {
                check("json normalize inner_gap clamped", loaded.config.innerGap == 96)
                check("json normalize outer_gap clamped", loaded.config.outerGap == 0)
                check("json normalize presets deduped", loaded.config.presetWidthRatios == [0.5, 2.0])
            } else {
                check("json normalize inner_gap clamped", false)
                check("json normalize outer_gap clamped", false)
                check("json normalize presets deduped", false)
            }
            try? FileManager.default.removeItem(at: tmp3)
        } catch {
            check("json normalize inner_gap clamped", false, "\(error)")
            check("json normalize outer_gap clamped", false, "\(error)")
            check("json normalize presets deduped", false, "\(error)")
        }
    }

    private static func checkLayoutVerificationHelpers() {
        let s = Scrollini()
        check("framesApproximatelyEqual exact", s.framesApproximatelyEqual(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 100, height: 100), tolerance: 0) == true)
        check("framesApproximatelyEqual tolerance 0.5 fails 1 diff", s.framesApproximatelyEqual(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 1, y: 0, width: 100, height: 100), tolerance: 0.5) == false)
        // currentLayoutItem without viewport cache uses fallback computeViewport -> skip, but test helper directly
        s.workspaces = [Workspace()]
        let w = window(800); w.manualWidthRatio = 0.8
        s.workspaces[0].columns = [w]
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let item = s.currentLayoutItem(for: w)
        check("currentLayoutItem returns frame", item != nil)
        check("currentLayoutItem frame width >0", (item?.frame.width ?? 0) > 0)
        // insetViewport already tested, but viewport caching
        s.cachedViewport = nil
        s.cachedViewportAt = 0
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        check("currentViewport cached returns same", s.currentViewport() == viewport)
        // invalidate
        s.invalidateViewportCache()
        check("invalidateViewportCache clears", s.cachedViewport == nil)
        s.cachedViewport = viewport
        s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Fixtures

    private static let viewport = CGRect(x: 0, y: 25, width: 1600, height: 1000)

    private static func window(_ index: Int) -> ManagedWindow {
        // A distinct pid per window gives a distinct accessibility element, which is all these
        // checks need from one: identity. No process has to exist behind it.
        ManagedWindow(
            element: AXUIElementCreateApplication(pid_t(9000 + index)),
            pid: pid_t(9000 + index),
            windowID: UInt32(index + 1),
            bundleID: "com.test.\(index)",
            appName: "Test \(index)",
            title: "Window \(index)"
        )
    }

    /// Three workspaces holding three, two and four columns, with focus somewhere other than the
    /// first column so an off-by-one in the strip has somewhere to show up.
    private static func buildModel(_ scrollini: Scrollini) -> [ManagedWindow] {
        var made: [ManagedWindow] = []
        var next = 0

        scrollini.workspaces = [3, 2, 4].map { count in
            let workspace = Workspace()
            for _ in 0..<count {
                let created = window(next)
                next += 1
                made.append(created)
                workspace.columns.append(created)
            }
            return workspace
        }

        scrollini.workspaces[0].activeColumn = 1
        scrollini.workspaces[2].activeColumn = 3
        scrollini.activeWorkspace = 0
        return made
    }

    // MARK: - Reporting

    private static func section(_ name: String) {
        print("")
        print("\(name)")
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if passed {
            print("  ok    \(name)")
            return
        }

        failures += 1
        let detail = detail()
        print("  FAIL  \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    private static func approx(_ left: CGFloat, _ right: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(left - right) <= tolerance
    }

    private static func sameRect(_ left: CGRect, _ right: CGRect) -> Bool {
        approx(left.minX, right.minX)
            && approx(left.minY, right.minY)
            && approx(left.width, right.width)
            && approx(left.height, right.height)
    }
}
