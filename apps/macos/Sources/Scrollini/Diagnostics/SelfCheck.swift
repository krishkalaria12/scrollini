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

        section("width presets")
        checkWidthPresets()
        checkMaximizeToggle()

        section("workspace bookkeeping")
        checkWorkspaceInvariants()

        section("keybindings")
        checkKeybindingNormalization()

        section("config normalization")
        checkConfigClamping()

        section("hover focus")
        checkHoverFocusStaysOnActiveWorkspace()

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
