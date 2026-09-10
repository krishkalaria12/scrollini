import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@discardableResult
func setAXFrame(_ frame: CGRect, for element: AXUIElement) -> Bool {
    // AppKit clamps a new position against the window's *current* size, and clamps a new size
    // against the app's own constraints. A single position-then-size pass therefore lands wrong
    // whenever a window has to move and shrink at once: the move is refused while the window is
    // still wide, then the shrink succeeds and leaves the window at the old origin. Shrinking
    // first frees the room the move needs, and the trailing size pass re-asserts the width for
    // apps that snap back while being dragged across a screen edge.
    var succeeded = setAXSize(frame.size, for: element)
    succeeded = setAXPosition(frame.origin, for: element) && succeeded
    succeeded = setAXSize(frame.size, for: element) && succeeded
    return succeeded
}

@discardableResult
func setAXPosition(_ origin: CGPoint, for element: AXUIElement) -> Bool {
    var origin = origin
    if let positionValue = AXValueCreate(.cgPoint, &origin) {
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue) == .success
    }
    return false
}

@discardableResult
func setAXSize(_ size: CGSize, for element: AXUIElement) -> Bool {
    var size = size
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) == .success
    }
    return false
}

func axFrame(of element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
    else {
        return nil
    }

    var origin = CGPoint.zero
    var size = CGSize.zero
    guard let positionValue = positionRef, let sizeValue = sizeRef,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID(),
          AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
        return nil
    }

    return CGRect(origin: origin, size: size)
}

func currentExecutableURL() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)

    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
    defer {
        buffer.deallocate()
    }

    guard _NSGetExecutablePath(buffer, &size) == 0 else {
        return nil
    }

    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}

/// Bridges a value read off an AX attribute to an `AXUIElement`. Attributes are typed by
/// convention, not by contract: an app is free to answer `kAXFocusedWindow` with a string, a
/// number, or nothing useful at all, and an unconditional cast turns that into a crash. Every
/// element-valued read goes through here so a badly behaved app costs one skipped window instead
/// of the whole session.
func asAXUIElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

/// Caps how long any accessibility call may block this process.
///
/// Every AX read and write scrollini makes is a synchronous Mach round trip, issued from the main
/// thread, and the main thread is also what services the CGEvent tap that carries every keystroke
/// and pointer move. Left unbounded, one beachballing app stalls that thread for as long as it
/// takes to recover, macOS disables the tap for exceeding its own deadline, and the user loses
/// keyboard input to an app they were not even using. A quarter second is far longer than a
/// healthy app needs to answer, and a window that misses it is simply skipped until the next
/// rescan. Applied to the system-wide element, which per the AX headers sets the timeout for the
/// whole process rather than for one element.
func boundAccessibilityMessagingTimeout(_ seconds: Float = 0.25) {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
}

/// Hashable wrapper so accessibility elements can key a dictionary. `AXUIElement` is a CoreFoundation
/// type with equality and hashing supplied by HIServices, but Swift will not use them for a
/// `Dictionary` key without being told.
struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (left: AXElementKey, right: AXElementKey) -> Bool {
        CFEqual(left.element, right.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
