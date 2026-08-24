import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func perform(_ command: Command) {
        clearTrackpadCamera()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false
        rescanWindows(adoptFocused: false)
        let previousState = captureLayoutState()
        var animated = false
        var frameAnimated = false
        var duration = keyboardAnimationDuration
        func runAnimatedChange(
            duration changeDuration: TimeInterval,
            frameChange: Bool = false,
            _ change: () -> Bool
        ) -> Bool {
            duration = changeDuration
            guard performAnimatedLayoutChange(from: previousState, change) else {
                return false
            }
            animated = true
            frameAnimated = frameAnimated || frameChange
            return true
        }

        switch command {
        case .focusWorkspace(let oneBasedIndex):
            guard focusWorkspace(oneBasedIndex) else {
                return
            }
        case .focusPreviousWorkspace:
            guard focusPreviousWorkspace() else {
                return
            }
        case .workspaceDown:
            guard setActiveWorkspace(activeWorkspace + 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
        case .workspaceUp:
            guard setActiveWorkspace(activeWorkspace - 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
        case .columnLeft:
            guard focusColumn(relativeOffset: -1) else {
                return
            }
            animated = true
        case .columnRight:
            guard focusColumn(relativeOffset: 1) else {
                return
            }
            animated = true
        case .columnFirst:
            guard focusColumn(at: 0) else {
                return
            }
            animated = true
        case .columnLast:
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            guard focusColumn(at: workspace.columns.count - 1) else {
                return
            }
            animated = true
        case .moveColumnLeft:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnHorizontally(by: -1)
            }) else {
                return
            }
        case .moveColumnRight:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnHorizontally(by: 1)
            }) else {
                return
            }
        case .moveColumnToFirst:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumn(to: 0)
            }) else {
                return
            }
        case .moveColumnToLast:
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumn(to: workspace.columns.count - 1)
            }) else {
                return
            }
        case .moveColumnToWorkspace(let oneBasedIndex):
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnToWorkspace(oneBasedIndex: oneBasedIndex)
            }) else {
                return
            }
        case .moveColumnToWorkspaceDown:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnToWorkspace(relativeOffset: 1)
            }) else {
                return
            }
        case .moveColumnToWorkspaceUp:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnToWorkspace(relativeOffset: -1)
            }) else {
                return
            }
        case .cycleWidthPresetBackward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleActiveWidthPreset(direction: -1)
            }) else {
                return
            }
        case .cycleWidthPresetForward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleActiveWidthPreset(direction: 1)
            }) else {
                return
            }
        case .nudgeWidthNarrower:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeActiveWidth(by: -0.1)
            }) else {
                return
            }
        case .nudgeWidthWider:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeActiveWidth(by: 0.1)
            }) else {
                return
            }
        case .cycleAllWidthPresetsBackward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleAllWidthPresets(direction: -1)
            }) else {
                return
            }
        case .cycleAllWidthPresetsForward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleAllWidthPresets(direction: 1)
            }) else {
                return
            }
        case .nudgeAllWidthsNarrower:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeAllWidths(by: -0.1)
            }) else {
                return
            }
        case .nudgeAllWidthsWider:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeAllWidths(by: 0.1)
            }) else {
                return
            }
        case .maximizeColumnWidth:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                toggleMaximizeActiveWidth()
            }) else {
                return
            }
        case .resetColumnWidth:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                resetActiveWidth()
            }) else {
                return
            }
        }

        let newState = captureLayoutState()
        projectLayout(
            focusActiveWindow: true,
            animated: animated && (previousState != newState || frameAnimated),
            from: previousState,
            animationDuration: duration
        )
    }

    func performAnimatedLayoutChange(from state: LayoutState, _ change: () -> Bool) -> Bool {
        // LayoutState stores focus and camera state, not pre-mutation window order or width.
        seedPresentationFrames(from: state)
        guard change() else {
            presentationFrames.removeAll()
            return false
        }
        return true
    }
    func focusWorkspace(_ oneBasedIndex: Int) -> Bool {
        guard !workspaces.isEmpty else {
            return false
        }

        let requestedIndex = min(max(oneBasedIndex - 1, 0), workspaces.count - 1)
        let targetIndex = workspaceAutoBackAndForth && requestedIndex == activeWorkspace
            ? previousWorkspaceIndex() ?? requestedIndex
            : requestedIndex

        guard setActiveWorkspace(targetIndex) else {
            return false
        }
        activeWorkspaceObject()?.clampFocus()
        return true
    }

    func focusPreviousWorkspace() -> Bool {
        guard let previousIndex = previousWorkspaceIndex(),
              previousIndex != activeWorkspace
        else {
            return false
        }

        setActiveWorkspace(previousIndex)
        activeWorkspaceObject()?.clampFocus()
        return true
    }

    @discardableResult
    func setActiveWorkspace(_ requestedIndex: Int, rememberPrevious: Bool = true) -> Bool {
        guard !workspaces.isEmpty else {
            activeWorkspace = 0
            previousWorkspace = nil
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let currentWorkspace = activeWorkspaceObject()
        activeWorkspace = targetIndex
        if rememberPrevious {
            previousWorkspace = currentWorkspace
        }
        return true
    }

    func previousWorkspaceIndex() -> Int? {
        guard let previousWorkspace else {
            return nil
        }

        return workspaces.firstIndex(where: { $0 === previousWorkspace })
    }

    func focusColumn(at requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard targetIndex != workspace.activeColumn || workspace.scrollOffset != nil else {
            return false
        }

        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    func focusColumn(relativeOffset delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(sourceIndex + delta, 0), workspace.columns.count - 1)
        guard targetIndex != sourceIndex else {
            return false
        }

        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    func moveActiveColumnHorizontally(by delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        return moveActiveColumn(to: workspace.activeColumn + delta)
    }

    func moveActiveColumn(to requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard sourceIndex != targetIndex else {
            return false
        }

        let window = workspace.columns.remove(at: sourceIndex)
        workspace.columns.insert(window, at: targetIndex)
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    func cycleActiveWidthPreset(direction: Int) -> Bool {
        guard let window = activeWindow() else {
            return false
        }

        guard let target = widthPreset(after: widthRatio(for: window), direction: direction) else {
            return false
        }

        return setActiveWindowWidthRatio(target)
    }

    func cycleAllWidthPresets(direction: Int) -> Bool {
        guard let window = activeWindow(),
              let target = widthPreset(after: widthRatio(for: window), direction: direction)
        else {
            return false
        }

        return setAllWindowWidthRatios(target)
    }

    func widthPreset(after current: CGFloat, direction: Int) -> CGFloat? {
        let presets = widthPresetRatios
        guard !presets.isEmpty else {
            return nil
        }

        if direction >= 0 {
            return presets.first(where: { $0 > current + 0.005 }) ?? presets[0]
        }

        return presets.last(where: { $0 < current - 0.005 }) ?? presets[presets.count - 1]
    }

    /// niri's `maximize-column`: fill the working area, and toggle back to the width the column
    /// had before on a second press.
    func toggleMaximizeActiveWidth() -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let window = workspace.columns[workspace.activeColumn]
        if let restored = window.preMaximizeWidthRatio {
            window.preMaximizeWidthRatio = nil
            return setActiveWindowWidthRatio(restored)
        }

        let current = widthRatio(for: window)
        guard current < 1.0 - 0.005 else {
            return false
        }

        guard setActiveWindowWidthRatio(1.0) else {
            return false
        }
        window.preMaximizeWidthRatio = current
        return true
    }

    /// niri's `reset-window-width`: drop the column back to whatever the config says it should be.
    func resetActiveWidth() -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let window = workspace.columns[workspace.activeColumn]
        guard window.manualWidthRatio != nil || window.measuredWidth != nil else {
            return false
        }

        window.manualWidthRatio = nil
        window.preMaximizeWidthRatio = nil
        window.measuredWidth = nil
        window.measuredForWidth = nil
        workspace.scrollOffset = nil
        return true
    }

    func nudgeActiveWidth(by delta: CGFloat) -> Bool {
        guard let window = activeWindow() else {
            return false
        }
        return setActiveWindowWidthRatio(nudgedWidthRatio(from: widthRatio(for: window), by: delta))
    }

    func nudgeAllWidths(by delta: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(nudgedWidthRatio(from: widthRatio(for: window), by: delta), for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
    }

    func nudgedWidthRatio(from ratio: CGFloat, by delta: CGFloat) -> CGFloat {
        let nudgedRatio = ratio + delta
        if ratio <= 1.0, delta > 0 {
            return min(nudgedRatio, 1.0)
        }
        return nudgedRatio.clampedManualWidthRatio
    }

    func setActiveWindowWidthRatio(_ ratio: CGFloat) -> Bool {
        guard let workspace = activeWorkspaceObject(),
              !workspace.columns.isEmpty
        else {
            return false
        }

        workspace.clampFocus()
        let window = workspace.columns[workspace.activeColumn]
        guard setWidthRatio(ratio, for: window) else {
            return false
        }

        workspace.scrollOffset = nil
        return true
    }

    func setAllWindowWidthRatios(_ ratio: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(ratio, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
    }

    func setWidthRatio(_ ratio: CGFloat, for window: ManagedWindow) -> Bool {
        let oldRatio = widthRatio(for: window)
        let newRatio = ratio.clampedManualWidthRatio
        guard abs(oldRatio - newRatio) >= 0.005 else {
            return false
        }

        window.manualWidthRatio = newRatio
        // Any other width change makes the remembered pre-maximize width meaningless. The maximize
        // toggle re-arms it right after calling through here.
        window.preMaximizeWidthRatio = nil
        return true
    }
    @discardableResult
    func moveActiveColumnToWorkspace(relativeOffset: Int) -> Bool {
        let targetIndex = activeWorkspace + relativeOffset
        return moveActiveColumnToWorkspace(zeroBasedIndex: targetIndex)
    }

    @discardableResult
    func moveActiveColumnToWorkspace(oneBasedIndex: Int) -> Bool {
        let zeroBased = max(0, oneBasedIndex - 1)
        return moveActiveColumnToWorkspace(zeroBasedIndex: zeroBased)
    }

    @discardableResult
    func moveActiveColumnToWorkspace(zeroBasedIndex requestedIndex: Int) -> Bool {
        guard workspaces.indices.contains(activeWorkspace),
              let sourceWorkspace = activeWorkspaceObject(),
              !sourceWorkspace.columns.isEmpty
        else {
            return false
        }

        sourceWorkspace.clampFocus()
        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let targetWorkspace = workspaces[targetIndex]
        let movingWindow = sourceWorkspace.columns.remove(at: sourceWorkspace.activeColumn)
        sourceWorkspace.scrollOffset = nil
        sourceWorkspace.clampFocus()

        targetWorkspace.clampFocus()
        let insertionIndex = targetWorkspace.columns.isEmpty
            ? 0
            : min(targetWorkspace.activeColumn + 1, targetWorkspace.columns.count)
        targetWorkspace.columns.insert(movingWindow, at: insertionIndex)
        targetWorkspace.activeColumn = insertionIndex
        targetWorkspace.scrollOffset = nil

        setActiveWorkspace(targetIndex)
        ensureTrailingEmptyWorkspace()
        activeWorkspace = workspaces.firstIndex(where: { $0 === targetWorkspace }) ?? activeWorkspace
        return true
    }
}
