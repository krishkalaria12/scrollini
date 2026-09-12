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
            fingers: trackpadNavigationWorkspaceFingers,
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
        case let .changed(delta, velocity):
            moveTrackpadCamera(delta: delta, velocity: velocity)
        case let .ended(moved, velocity):
            guard moved else {
                // The swipe never travelled far enough to move the camera, so there is no
                // workspace to settle on. Beginning the gesture still froze the camera, so
                // release it.
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

    func moveTrackpadCamera(delta: CGFloat, velocity: CGFloat) {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        trackpadPendingCameraDelta += trackpadCameraDelta(from: delta, velocity: velocity, viewport: viewport)
        trackpadLatestCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        trackpadCameraVelocity = trackpadLatestCameraVelocity
        startTrackpadRenderLoop()
    }

    func endTrackpadCamera(velocity: CGFloat) {
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

    func trackpadCameraDelta(from delta: CGFloat, velocity: CGFloat, viewport: CGRect) -> CGFloat {
        delta * viewport.height * trackpadNavigationWorkspaceSensitivity * trackpadCameraVelocityGain(for: velocity)
    }

    func trackpadCameraVelocity(from velocity: CGFloat, viewport: CGRect) -> CGFloat {
        velocity * viewport.height * trackpadNavigationWorkspaceSensitivity * trackpadCameraVelocityGain(for: velocity)
    }

    func trackpadCameraVelocityGain(for velocity: CGFloat) -> CGFloat {
        let extra = min(max((abs(velocity) - 0.35) / 1.4, 0), trackpadNavigationVelocityGain)
        return 1 + extra
    }

    var hasPendingTrackpadCameraDelta: Bool {
        abs(trackpadPendingCameraDelta) >= 0.5
    }

    var hasTrackpadMomentumVelocity: Bool {
        abs(trackpadCameraVelocity) >= trackpadNavigationMomentumMinVelocity
    }

    func strongestTrackpadCameraVelocity(endingVelocity: CGFloat) -> CGFloat {
        abs(endingVelocity) >= abs(trackpadLatestCameraVelocity) ? endingVelocity : trackpadLatestCameraVelocity
    }

    func resetTrackpadCameraMotion(clearCameraY: Bool) {
        trackpadPendingCameraDelta = 0
        trackpadLatestCameraVelocity = 0
        trackpadCameraVelocity = 0
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
            trackpadPendingCameraDelta = 0
            stopTrackpadRenderLoop()
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let delta = trackpadPendingCameraDelta
        trackpadPendingCameraDelta = 0
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
        trackpadCameraVelocity *= decay

        if applyTrackpadCameraDelta(trackpadCameraVelocity * elapsed, viewport: viewport) {
            trackpadCameraVelocity = 0
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

    /// Moves the camera vertically and reports whether the strip of workspaces ran out underneath
    /// it, which is momentum's cue to stop rather than grind against the end.
    @discardableResult
    func applyTrackpadCameraDelta(_ delta: CGFloat, viewport: CGRect) -> Bool {
        let currentY = trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height
        let maxY = max(0, CGFloat(max(workspaces.count - 1, 0)) * viewport.height)
        let nextY = min(max(currentY + delta, 0), maxY)
        trackpadCameraY = nextY
        return abs(nextY - (currentY + delta)) > 0.5
    }

    func settleTrackpadCamera(focusActiveWindow: Bool) {
        guard !workspaces.isEmpty else {
            resetTrackpadCameraMotion(clearCameraY: true)
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let previousState = captureLayoutState()

        // The camera lands on the workspace nearest to where it stopped, and every workspace keeps
        // the column position it already had.
        let targetWorkspace = trackpadCameraWorkspaceIndex(
            cameraY: trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height,
            viewport: viewport
        )
        setActiveWorkspace(targetWorkspace)

        resetTrackpadCameraMotion(clearCameraY: true)
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
            trackpadPendingCameraDelta = 0
        }

        resetTrackpadCameraMotion(clearCameraY: false)
    }
}
