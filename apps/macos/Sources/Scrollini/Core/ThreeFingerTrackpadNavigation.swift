import CoreGraphics
import Darwin
import Foundation

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var unknown4: MTVector
    var unknown5_0: Int32
    var unknown5_1: Int32
    var unknown6: Float
}

private typealias MTContactCallbackFunction = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private let scrolliniTrackpadContactCallback: MTContactCallbackFunction = { _, touches, count, _, _ in
    ThreeFingerTrackpadNavigation.handleContacts(touches: touches, count: Int(count))
    return 0
}

private final class MultitouchSupport {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias RegisterContactFrameCallback = @convention(c) (MTDeviceRef?, MTContactCallbackFunction) -> Void
    typealias UnregisterContactFrameCallback = @convention(c) (MTDeviceRef?, MTContactCallbackFunction) -> Void
    typealias DeviceStart = @convention(c) (MTDeviceRef?, Int32) -> Void
    typealias DeviceStop = @convention(c) (MTDeviceRef?) -> Void

    let handle: UnsafeMutableRawPointer
    let createList: CreateList
    let registerContactFrameCallback: RegisterContactFrameCallback
    let deviceStart: DeviceStart
    /// Optional: present on every macOS this runs on, but teardown degrades to leaving the device
    /// running rather than failing to start if a future release drops them.
    let unregisterContactFrameCallback: UnregisterContactFrameCallback?
    let deviceStop: DeviceStop?

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            return nil
        }

        guard let createListSymbol = dlsym(handle, "MTDeviceCreateList"),
              let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSymbol = dlsym(handle, "MTDeviceStart")
        else {
            dlclose(handle)
            return nil
        }

        // The handle is deliberately never closed. MultitouchSupport runs its own contact thread,
        // and unloading the framework out from under it while a device is still live is a crash
        // waiting for the next swipe.
        self.handle = handle
        createList = unsafeBitCast(createListSymbol, to: CreateList.self)
        registerContactFrameCallback = unsafeBitCast(registerSymbol, to: RegisterContactFrameCallback.self)
        deviceStart = unsafeBitCast(startSymbol, to: DeviceStart.self)
        unregisterContactFrameCallback = dlsym(handle, "MTUnregisterContactFrameCallback")
            .map { unsafeBitCast($0, to: UnregisterContactFrameCallback.self) }
        deviceStop = dlsym(handle, "MTDeviceStop").map { unsafeBitCast($0, to: DeviceStop.self) }
    }
}

/// Reads raw contact frames rather than AppKit gesture events. The system owns most multi-finger
/// gestures, so matching the contact count here lets Scrollini claim a four-finger swipe for
/// workspaces while two- and three-finger scrolling still belongs to the app under the cursor.
final class ThreeFingerTrackpadNavigation: @unchecked Sendable {
    private struct GestureState {
        var active = false
        var lastCentroid = CGPoint.zero
        var lastTimestamp: CFAbsoluteTime = 0
        var velocity: CGFloat = 0
        /// Travel since the gesture started, held until the movement is deliberate.
        var cumulative = CGPoint.zero
        /// False until the swipe has travelled far enough to move the camera.
        var moved = false
    }

    private let fingers: Int
    private let invertY: Bool
    private let directionLockThreshold: CGFloat
    private let onEvent: (TrackpadNavigationEvent) -> Void
    private let lock = NSLock()
    private var state = GestureState()
    private var framework: MultitouchSupport?
    private var deviceList: CFArray?
    private var devices: [MTDeviceRef] = []

    nonisolated(unsafe) private static weak var active: ThreeFingerTrackpadNavigation?

    init(
        fingers: Int,
        invertY: Bool,
        directionLockThreshold: CGFloat,
        onEvent: @escaping (TrackpadNavigationEvent) -> Void
    ) {
        self.fingers = fingers
        self.invertY = invertY
        self.directionLockThreshold = max(directionLockThreshold, 0.0001)
        self.onEvent = onEvent
    }

    func start() -> Bool {
        guard let framework = MultitouchSupport(),
              let unmanagedDeviceList = framework.createList()
        else {
            return false
        }

        let deviceList = unmanagedDeviceList.takeRetainedValue()
        let count = CFArrayGetCount(deviceList)
        guard count > 0 else {
            return false
        }

        var devices: [MTDeviceRef] = []
        for index in 0..<count {
            guard let rawDevice = CFArrayGetValueAtIndex(deviceList, index) else {
                continue
            }

            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            framework.registerContactFrameCallback(device, scrolliniTrackpadContactCallback)
            framework.deviceStart(device, 0)
            devices.append(device)
        }

        guard !devices.isEmpty else {
            return false
        }

        self.framework = framework
        self.deviceList = deviceList
        self.devices = devices
        Self.active = self
        return true
    }

    func stop() {
        lock.lock()
        resetGesture()
        lock.unlock()

        if Self.active === self {
            Self.active = nil
        }

        // Every device has to be unregistered and stopped before the references go. Without this
        // a restart registered the same callback on the same device a second time, so each
        // reload of trackpad settings doubled the deltas every swipe reported.
        if let framework {
            for device in devices {
                framework.unregisterContactFrameCallback?(device, scrolliniTrackpadContactCallback)
                framework.deviceStop?(device)
            }
        }

        devices.removeAll()
        deviceList = nil
        framework = nil
    }

    fileprivate static func handleContacts(touches: UnsafeMutableRawPointer?, count: Int) {
        active?.handleContacts(touches: touches, count: count)
    }

    private func handleContacts(touches: UnsafeMutableRawPointer?, count: Int) {
        let event: TrackpadNavigationEvent?

        lock.lock()
        // A finger joining or leaving ends the gesture rather than retargeting it, so a swipe that
        // passes through the right contact count on its way to another one does not move anything.
        if count != fingers || touches == nil {
            event = endGesture()
        } else {
            event = updateGesture(touches: touches!.assumingMemoryBound(to: MTTouch.self), count: count)
        }
        lock.unlock()

        if let event {
            onEvent(event)
        }
    }

    private func updateGesture(touches: UnsafeMutablePointer<MTTouch>, count: Int) -> TrackpadNavigationEvent? {
        let centroid = centroid(of: touches, count: count)
        let now = CFAbsoluteTimeGetCurrent()
        guard state.active else {
            state.active = true
            state.lastCentroid = centroid
            state.lastTimestamp = now
            state.velocity = 0
            state.cumulative = .zero
            state.moved = false
            return .began
        }

        let deltaX = centroid.x - state.lastCentroid.x
        var deltaY = centroid.y - state.lastCentroid.y
        if invertY {
            deltaY *= -1
        }

        let elapsed = max(now - state.lastTimestamp, 1.0 / 120.0)
        state.lastCentroid = centroid
        state.lastTimestamp = now
        guard abs(deltaX) > 0.00005 || abs(deltaY) > 0.00005 else {
            return nil
        }

        state.cumulative.x += deltaX
        state.cumulative.y += deltaY

        // Hold everything back until the swipe has travelled far enough to read as deliberate,
        // then release the travel banked so far. The contact count has already claimed the
        // gesture, so only the vertical half of that travel matters and a swipe that wanders
        // sideways still lands on a workspace.
        if !state.moved {
            guard hypot(state.cumulative.x, state.cumulative.y) >= directionLockThreshold else {
                return nil
            }

            state.moved = true
            deltaY = state.cumulative.y
        }

        let instantVelocity = deltaY / elapsed
        state.velocity = state.velocity * 0.65 + instantVelocity * 0.35
        return .changed(delta: deltaY, velocity: state.velocity)
    }

    private func centroid(of touches: UnsafeMutablePointer<MTTouch>, count: Int) -> CGPoint {
        var x: CGFloat = 0
        var y: CGFloat = 0

        for index in 0..<count {
            let touch = touches[index]
            x += CGFloat(touch.normalized.position.x)
            y += CGFloat(touch.normalized.position.y)
        }

        return CGPoint(x: x / CGFloat(count), y: y / CGFloat(count))
    }

    private func endGesture() -> TrackpadNavigationEvent? {
        guard state.active else {
            return nil
        }

        // A swipe that never passed the threshold has no motion to carry into momentum.
        let moved = state.moved
        let velocity = moved ? state.velocity : 0

        resetGesture()
        return .ended(moved: moved, velocity: velocity)
    }

    private func resetGesture() {
        state.active = false
        state.lastCentroid = .zero
        state.lastTimestamp = 0
        state.velocity = 0
        state.cumulative = .zero
        state.moved = false
    }
}
