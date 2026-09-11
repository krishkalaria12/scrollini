import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func installTrackpadNavigation() {
        guard trackpadNavigationEnabled else {
            return
        }

        let navigation = ThreeFingerTrackpadNavigation(
            columnFingers: trackpadNavigationColumnFingers,
            workspaceFingers: trackpadNavigationWorkspaceFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY,
            directionLockThreshold: trackpadNavigationDirectionLockThreshold
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleTrackpadNavigationEvent(event)
            }
        }

        guard navigation.start() else { return }

        trackpadNavigation = navigation
    }

    func restartTrackpadNavigation() {
        trackpadNavigation?.stop()
        trackpadNavigation = nil
        clearTrackpadCamera()
        installTrackpadNavigation()
    }
    func handleTrackpadNavigationEvent(_ event: TrackpadNavigationEvent) {
        guard trackpadNavigationEnabled,
              !transientSystemWindowIsActive(),
              trackpadNavigationAllowedForActiveWindow
        else {
            return
        }

        switch event {
        case .began:
            beginTrackpadCamera()
        case let .changed(axis, delta, velocity):
            moveTrackpadCamera(axis: axis, delta: delta, velocity: velocity)
        case let .ended(axis, velocity):
            guard axis != nil else {
                // The swipe never committed to an axis, so there is nothing to settle. Starting
                // the gesture pinned the strip's scroll offset, though, so release it and let the
                // focused column drive the view again.
                if trackpadNavigationSnap == .nearestColumn {
                    activeWorkspaceObject()?.scrollOffset = nil
                }
                clearTrackpadCamera()
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
                return
            }
            endTrackpadCamera(velocity: velocity)
        }
    }

    func beginTrackpadCamera() {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        cancelHoverFocus()
        flushPendingColumnNavigation()
        flushColumnNavigationProjection(animated: false)
        cancelColumnNavigationFocus()
        hoverFocusRequiresRearm = false
        stopTrackpadMomentum()
        stopAnimation(clearPresentation: false)
        rescanWindows(adoptFocused: false)
        resetTrackpadCameraMotion(clearCameraY: false)
        seedTrackpadCamera(viewport: currentViewport())
        startTrackpadRenderLoop()
    }

    func moveTrackpadCamera(axis: TrackpadNavigationAxis, delta: CGPoint, velocity: CGPoint) {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let cameraDelta = trackpadCameraDelta(from: delta, velocity: velocity, viewport: viewport)
        trackpadPendingCameraDelta.width += cameraDelta.width
        trackpadPendingCameraDelta.height += cameraDelta.height
        trackpadLatestCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        trackpadCameraVelocity = trackpadLatestCameraVelocity
        trackpadCameraAxis = axis
        startTrackpadRenderLoop()
    }

    func endTrackpadCamera(velocity: CGPoint) {
        suppressHoverFocusAfterTrackpadMovement()
        flushTrackpadCameraFrame()
        stopTrackpadRenderLoop()
        let viewport = currentViewport()
        trackpadCameraVelocity = strongestTrackpadCameraVelocity(
            endingVelocity: trackpadCameraVelocity(from: velocity, viewport: viewport)
        )

        guard hasTrackpadMomentumVelocity else {
            settleTrackpadCamera(focusActiveWindow: true)
            return
        }

        startTrackpadMomentum()
    }

    func trackpadCameraDelta(from delta: CGPoint, velocity: CGPoint, viewport: CGRect) -> CGSize {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGSize(
            width: -delta.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            height: delta.y * viewport.height * trackpadNavigationWorkspaceSensitivity * multiplier
        )
    }

    func trackpadCameraVelocity(from velocity: CGPoint, viewport: CGRect) -> CGPoint {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGPoint(
            x: -velocity.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            y: velocity.y * viewport.height * trackpadNavigationWorkspaceSensitivity * multiplier
        )
    }

    func trackpadCameraVelocityGain(for velocity: CGPoint) -> CGFloat {
        let speed = hypot(velocity.x, velocity.y)
        let extra = min(max((speed - 0.35) / 1.4, 0), trackpadNavigationVelocityGain)
        return 1 + extra
    }

    var hasPendingTrackpadCameraDelta: Bool {
        abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5
    }

    var hasTrackpadMomentumVelocity: Bool {
        abs(trackpadCameraVelocity.x) >= trackpadNavigationMomentumMinVelocity
            || abs(trackpadCameraVelocity.y) >= trackpadNavigationMomentumMinVelocity
    }

    func strongestTrackpadCameraVelocity(endingVelocity: CGPoint) -> CGPoint {
        CGPoint(
            x: abs(endingVelocity.x) >= abs(trackpadLatestCameraVelocity.x)
                ? endingVelocity.x
                : trackpadLatestCameraVelocity.x,
            y: abs(endingVelocity.y) >= abs(trackpadLatestCameraVelocity.y)
                ? endingVelocity.y
                : trackpadLatestCameraVelocity.y
        )
    }

    func resetTrackpadCameraMotion(clearCameraY: Bool) {
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadCameraVelocity = .zero
        trackpadCameraAxis = nil
        if clearCameraY {
            trackpadCameraY = nil
        }
    }

    func suppressHoverFocusAfterTrackpadMovement() {
        hoverFocusSuppressedUntil = CFAbsoluteTimeGetCurrent() + hoverFocusAfterTrackpad
        cancelHoverFocus()
    }

    func seedTrackpadCamera(viewport: CGRect) {
        if trackpadCameraY == nil {
            trackpadCameraY = CGFloat(activeWorkspace) * viewport.height
        }

        if let workspace = activeWorkspaceObject(), workspace.scrollOffset == nil {
            workspace.scrollOffset = horizontalCameraOffset(for: workspace, viewport: viewport)
        }
    }

    func startTrackpadMomentum() {
        stopTrackpadMomentum()
        trackpadMomentumLastFrameAt = CFAbsoluteTimeGetCurrent()

        trackpadMomentumTimer = makeMainTimer(
            deadline: .now(),
            repeating: frameTimerInterval,
            leeway: frameTimerLeeway
        ) { [weak self] in
            self?.stepTrackpadMomentum()
        }
    }

    func startTrackpadRenderLoop() {
        guard trackpadRenderTimer == nil else {
            return
        }

        trackpadRenderTimer = makeMainTimer(
            deadline: .now(),
            repeating: frameTimerInterval,
            leeway: frameTimerLeeway
        ) { [weak self] in
            self?.flushTrackpadCameraFrame()
        }
    }

    func stopTrackpadRenderLoop() {
        cancelTimer(&trackpadRenderTimer)
    }

    func flushTrackpadCameraFrame() {
        guard hasPendingTrackpadCameraDelta else {
            return
        }

        guard manualResizeElement == nil else {
            trackpadPendingCameraDelta = .zero
            stopTrackpadRenderLoop()
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let delta = trackpadPendingCameraDelta
        trackpadPendingCameraDelta = .zero
        _ = applyTrackpadCameraDelta(delta, viewport: viewport)
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0, snapshotTiming: .deferred)
    }

    func stepTrackpadMomentum() {
        suppressHoverFocusAfterTrackpadMovement()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = min(max(now - trackpadMomentumLastFrameAt, 1.0 / 120.0), 1.0 / 20.0)
        trackpadMomentumLastFrameAt = now

        let viewport = currentViewport()
        let decay = exp(-trackpadNavigationDeceleration * elapsed)
        trackpadCameraVelocity.x *= decay
        trackpadCameraVelocity.y *= decay

        let cameraDelta = CGSize(
            width: trackpadCameraVelocity.x * elapsed,
            height: trackpadCameraVelocity.y * elapsed
        )
        let clamped = applyTrackpadCameraDelta(cameraDelta, viewport: viewport)
        if clamped.x {
            trackpadCameraVelocity.x = 0
        }
        if clamped.y {
            trackpadCameraVelocity.y = 0
        }

        projectLayout(focusActiveWindow: false, layoutLockDelay: 0, snapshotTiming: .deferred)

        if !hasTrackpadMomentumVelocity {
            stopTrackpadMomentum()
            settleTrackpadCamera(focusActiveWindow: true)
        }
    }

    func stopTrackpadMomentum() {
        cancelTimer(&trackpadMomentumTimer)
    }

    @discardableResult
    func applyTrackpadCameraDelta(_ delta: CGSize, viewport: CGRect) -> (x: Bool, y: Bool) {
        let currentY = trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height
        let maxY = max(0, CGFloat(max(workspaces.count - 1, 0)) * viewport.height)
        let nextY = min(max(currentY + delta.height, 0), maxY)
        trackpadCameraY = nextY

        // A direction-locked vertical swipe carries no horizontal delta, and must not pin the
        // scroll offset of every workspace the camera passes over on the way.
        guard abs(delta.width) > 0.01 else {
            return (false, abs(nextY - (currentY + delta.height)) > 0.5)
        }

        let workspaceIndex = trackpadCameraWorkspaceIndex(cameraY: nextY, viewport: viewport)
        var clampedX = false
        if workspaces.indices.contains(workspaceIndex) {
            let workspace = workspaces[workspaceIndex]
            if !workspace.columns.isEmpty {
                let currentX = horizontalCameraOffset(for: workspace, viewport: viewport)
                let maxX = maxHorizontalCameraOffset(for: workspace, viewport: viewport)
                let nextX = min(max(currentX + delta.width, 0), maxX)
                workspace.scrollOffset = nextX
                clampedX = abs(nextX - (currentX + delta.width)) > 0.5
            } else {
                clampedX = abs(delta.width) > 0.5
            }
        } else {
            clampedX = abs(delta.width) > 0.5
        }

        let clampedY = abs(nextY - (currentY + delta.height)) > 0.5
        return (clampedX, clampedY)
    }

    func settleTrackpadCamera(focusActiveWindow: Bool) {
        guard !workspaces.isEmpty else {
            resetTrackpadCameraMotion(clearCameraY: true)
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let previousState = captureLayoutState()

        // Settle only the axis the swipe committed to. A vertical swipe lands on a workspace and
        // leaves each workspace's column position exactly where it was; a horizontal swipe lands
        // on a column without ever changing workspace.
        let axis = trackpadCameraAxis ?? .horizontal
        if axis == .vertical {
            let targetWorkspace = trackpadCameraWorkspaceIndex(
                cameraY: trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height,
                viewport: viewport
            )
            setActiveWorkspace(targetWorkspace)
        }

        if axis == .horizontal, let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty {
            let offset = horizontalCameraOffset(for: workspace, viewport: viewport)
            switch trackpadNavigationSnap {
            case .nearestColumn:
                workspace.activeColumn = closestColumn(to: offset, in: workspace, viewport: viewport)
                workspace.scrollOffset = nil
            case .nearestVisible:
                workspace.activeColumn = mostVisibleColumn(in: workspace, viewport: viewport, scrollOffset: offset)
                workspace.scrollOffset = offset
            case .none:
                workspace.activeColumn = mostVisibleColumn(in: workspace, viewport: viewport, scrollOffset: offset)
                workspace.scrollOffset = offset
            }
        }

        resetTrackpadCameraMotion(clearCameraY: trackpadNavigationSnap != .none)
        hoverFocusRequiresRearm = true
        suppressHoverFocusAfterTrackpadMovement()

        let targetState = captureLayoutState()
        projectLayout(
            focusActiveWindow: focusActiveWindow,
            animated: previousState != targetState,
            from: previousState,
            animationDuration: trackpadSettleAnimationDuration,
            layoutLockDelay: 0.04
        )
    }

    func clearTrackpadCamera() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()
        resetTrackpadCameraMotion(clearCameraY: true)
    }

    func freezeTrackpadCameraForTransition() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()

        if hasPendingTrackpadCameraDelta {
            let viewport = currentViewport()
            seedTrackpadCamera(viewport: viewport)
            _ = applyTrackpadCameraDelta(trackpadPendingCameraDelta, viewport: viewport)
            trackpadPendingCameraDelta = .zero
        }

        resetTrackpadCameraMotion(clearCameraY: false)
    }
}
