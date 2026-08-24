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
