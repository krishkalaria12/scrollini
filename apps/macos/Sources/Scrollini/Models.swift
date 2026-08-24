import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    let windowID: UInt32?
    var bundleID: String?
    var appName: String
    var title: String
    var manualWidthRatio: CGFloat?
    /// Width this column had before it was maximized, so maximizing twice toggles back.
    var preMaximizeWidthRatio: CGFloat?

    /// Width macOS actually granted the last time this window was sized, recorded only when the
    /// app refused the width it was asked for (minimum sizes, character-cell increments, and so
    /// on). Columns pack against this so a stubborn app does not leave a hole in the strip, which
    /// mirrors niri caching each column's real width rather than its requested proportion.
    var measuredWidth: CGFloat?
    /// The width that was requested when `measuredWidth` was taken. The measurement is only
    /// trusted while the request behind it still stands, so changing a column's width always
    /// re-asks the app instead of reusing a stale clamp.
    var measuredForWidth: CGFloat?

    init(element: AXUIElement, pid: pid_t, windowID: UInt32?, bundleID: String?, appName: String, title: String) {
        self.element = element
        self.pid = pid
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

final class Workspace {
    var columns: [ManagedWindow] = []
    var activeColumn: Int = 0
    var scrollOffset: CGFloat?

    var isEmpty: Bool {
        columns.isEmpty
    }

    func clampFocus() {
        if columns.isEmpty {
            activeColumn = 0
            scrollOffset = nil
        } else {
            activeColumn = min(max(activeColumn, 0), columns.count - 1)
        }
    }
}

struct RestoreSnapshot: Codable {
    var windowIDs: [UInt32]
    var floatingWindowIDs: [UInt32]?
    var viewport: RectSnapshot
}

struct PersistentLayoutSnapshot: Codable {
    var version: Int
    var activeWorkspace: Int
    var activeColumns: [Int]
    var scrollOffsets: [CGFloat?]?
    var focusedWindow: PersistentWindowIdentity?
    var windows: [PersistentWindowState]
}

struct PersistentWindowState: Codable {
    var identity: PersistentWindowIdentity
    var workspace: Int
    var column: Int
    var manualWidthRatio: CGFloat?
}

struct PersistentWindowIdentity: Codable, Hashable {
    var bundleID: String?
    var appName: String
    var title: String
}

struct RectSnapshot: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct LayoutState: Equatable {
    var activeWorkspace: Int
    var activeColumns: [Int]
    var scrollOffsets: [CGFloat?]
    var cameraY: CGFloat?
}

struct LayoutItem {
    var window: ManagedWindow
    var frame: CGRect
    var visible: Bool
}

struct WindowMotion {
    var window: ManagedWindow
    var startFrame: CGRect
    var endFrame: CGRect
    var startsVisible: Bool
    var endsVisible: Bool
    var participates: Bool
    var sizeStable: Bool
}
