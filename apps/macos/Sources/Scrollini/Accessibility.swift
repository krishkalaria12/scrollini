import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@discardableResult
func setAXFrame(_ frame: CGRect, for element: AXUIElement) -> Bool {
    var succeeded = true
    var origin = CGPoint(x: frame.minX, y: frame.minY)
    if let positionValue = AXValueCreate(.cgPoint, &origin) {
        succeeded = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue) == .success
            && succeeded
    } else {
        succeeded = false
    }

    var size = CGSize(width: frame.width, height: frame.height)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        succeeded = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) == .success
            && succeeded
    } else {
        succeeded = false
    }

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
