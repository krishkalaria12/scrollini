import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func animateLayout(
        from previousState: LayoutState,
        to targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        prefocusActiveWindow: Bool,
        duration: TimeInterval,
        verifyActiveLayout: Bool
    ) {
        stopAnimation(clearPresentation: false)
        let generation = nextAnimationGeneration()
        beginLayoutLock()

        let startLayout = layoutItems(viewport: viewport, state: previousState, parkHidden: false)
        let targetProjectedLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: false)
        let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        let startByWindow = layoutByWindow(startLayout)
        let targetByWindow = layoutByWindow(targetProjectedLayout)
        let windowIDs = Set(startByWindow.keys).union(targetByWindow.keys)

        let motions = windowIDs.compactMap { id -> WindowMotion? in
            guard let window = startByWindow[id]?.window ?? targetByWindow[id]?.window else {
                return nil
            }
            let startFrame = presentationFrames[id] ?? startByWindow[id]?.frame ?? targetByWindow[id]?.frame
            let endFrame = targetByWindow[id]?.frame ?? startFrame
            guard let startFrame, let endFrame else {
                return nil
            }
            let participates = startFrame.intersects(viewport) || endFrame.intersects(viewport)
            return WindowMotion(
                window: window,
                startFrame: startFrame,
                endFrame: endFrame,
                startsVisible: startByWindow[id]?.visible ?? false,
                endsVisible: targetByWindow[id]?.visible ?? false,
                participates: participates
            )
        }

        guard !motions.isEmpty else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow, forceFocusedFrame: focusActiveWindow)
            if verifyActiveLayout {
                scheduleActiveLayoutVerification(focusActiveWindow: focusActiveWindow)
            }
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]
        for motion in motions where motion.participates {
            applyFrame(motion.startFrame, to: motion)
            nextPresentationFrames[ObjectIdentifier(motion.window)] = motion.startFrame
        }
        presentationFrames = nextPresentationFrames

        primeAnimationVisibility(for: motions)
        if prefocusActiveWindow, focusActiveWindow, let activeWindow = self.activeWindow() {
            focus(activeWindow, verify: false, reveal: false)
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        animationTimer = makeMainTimer(
            deadline: .now() + frameTimerInterval,
            repeating: frameTimerInterval,
            leeway: frameTimerLeeway
        ) { [weak self] in
            guard let self else {
                return
            }
            guard generation == animationGeneration else {
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - startedAt
            let linearProgress = min(max(elapsed / duration, 0), 1)
            let easedProgress = softSettleCurve(CGFloat(linearProgress))
            let isFinalFrame = linearProgress >= 1
            applyAnimationFrame(
                motions,
                progress: easedProgress,
                viewport: viewport
            )
            restoreFloatingVisibility()

            if isFinalFrame {
                cancelTimer(&animationTimer)
                animationGeneration &+= 1
                applyLayout(
                    finalLayout,
                    focusActiveWindow: focusActiveWindow,
                    focusDelay: focusActiveWindow ? 0.035 : 0,
                    forceFocusedFrame: focusActiveWindow
                )
                if verifyActiveLayout {
                    scheduleActiveLayoutVerification(focusActiveWindow: focusActiveWindow)
                }
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
            }
        }
    }

    func layoutByWindow(_ layout: [LayoutItem]) -> [ObjectIdentifier: LayoutItem] {
        Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0) })
    }

    func applyAnimationFrame(
        _ motions: [WindowMotion],
        progress: CGFloat,
        viewport: CGRect
    ) {
        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]

        for motion in motions {
            guard motion.participates else {
                continue
            }

            let frame = interpolate(from: motion.startFrame, to: motion.endFrame, progress: progress)
            nextPresentationFrames[ObjectIdentifier(motion.window)] = frame
            applyFrame(frame, to: motion)
            applyAnimationVisibility(for: motion, progress: progress)
        }

        presentationFrames = nextPresentationFrames
    }

    func primeAnimationVisibility(for motions: [WindowMotion]) {
        for motion in motions {
            let alpha: Float = motion.participates && motion.startsVisible ? 1 : 0
            setWindowAlpha(alpha, for: motion.window.windowID)
        }
    }

    func applyAnimationVisibility(for motion: WindowMotion, progress: CGFloat) {
        guard motion.participates else {
            return
        }

        if motion.startsVisible {
            setWindowAlpha(1, for: motion.window.windowID)
            return
        }

        let shouldReveal = motion.endsVisible && progress >= 0.08
        setWindowAlpha(shouldReveal ? 1 : 0, for: motion.window.windowID)
    }

    func applyFrame(_ frame: CGRect, to motion: WindowMotion) {
        applyFrame(frame, to: motion.window)
    }

    func applyFrame(
        _ frame: CGRect,
        to window: ManagedWindow,
        force: Bool = false
    ) {
        let id = ObjectIdentifier(window)
        if !force,
           let previous = appliedFrames[id],
           framesApproximatelyEqual(previous, frame, tolerance: 0.5)
        {
            return
        }

        // A window that is only sliding needs one accessibility write, not the three
        // `setAXFrame` spends reconciling a simultaneous move and resize. Scrolling the strip is
        // exactly that case for every column on screen, every frame, so the size check is made
        // here against what was last written rather than being left to the caller to assert:
        // `applyLayout` has no way to know, and defaulting it to false tripled the cost of the
        // hottest loop in the program.
        let previousFrame = force ? nil : appliedFrames[id]
        let sizeUnchanged = previousFrame.map {
            abs($0.width - frame.width) < 0.5 && abs($0.height - frame.height) < 0.5
        } ?? false

        let succeeded: Bool
        if sizeUnchanged {
            succeeded = setAXPosition(frame.origin, for: window.element)
        } else {
            succeeded = setAXFrame(frame, for: window.element)
        }

        if succeeded {
            appliedFrames[id] = frame
        }
    }

    func stopAnimation(clearPresentation: Bool) {
        animationGeneration &+= 1
        cancelTimer(&animationTimer)
        if clearPresentation {
            presentationFrames.removeAll()
        }
        layoutLockGeneration &+= 1
        isApplyingLayout = false
    }

    func nextAnimationGeneration() -> UInt64 {
        animationGeneration &+= 1
        return animationGeneration
    }

    func beginLayoutLock() {
        layoutLockGeneration &+= 1
        isApplyingLayout = true
    }

    func releaseLayoutLock(after delay: TimeInterval = 0.08) {
        let generation = layoutLockGeneration
        guard delay > 0 else {
            if generation == layoutLockGeneration {
                isApplyingLayout = false
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == layoutLockGeneration,
                  animationTimer == nil
            else {
                return
            }
            isApplyingLayout = false
        }
    }

    func softSettleCurve(_ progress: CGFloat) -> CGFloat {
        switch animationCurve {
        case .linear:
            return progress
        case .snappy:
            return cubicBezier(progress, x1: 0.2, y1: 0.0, x2: 0.0, y2: 1.0)
        case .smooth:
            return cubicBezier(progress, x1: 0.16, y1: 0.0, x2: 0.18, y2: 1.0)
        }
    }

    func cubicBezier(_ progress: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGFloat {
        guard progress > 0 else {
            return 0
        }
        guard progress < 1 else {
            return 1
        }

        var t = progress
        for _ in 0..<5 {
            let x = bezierCoordinate(t, p1: x1, p2: x2) - progress
            let derivative = bezierDerivative(t, p1: x1, p2: x2)
            if abs(derivative) < 0.0001 {
                break
            }
            t = min(max(t - x / derivative, 0), 1)
        }

        return bezierCoordinate(t, p1: y1, p2: y2)
    }

    func bezierCoordinate(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t
    }

    func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * p1
            + 6 * inverse * t * (p2 - p1)
            + 3 * t * t * (1 - p2)
    }

    func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }
}
