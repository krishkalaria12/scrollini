import Foundation
import CoreGraphics
import ApplicationServices
@testable import Scrollini

let testViewport = CGRect(x: 0, y: 25, width: 1600, height: 1000)

func makeWindow(_ index: Int, bundleID: String? = nil, appName: String? = nil, title: String? = nil) -> ManagedWindow {
    ManagedWindow(
        element: AXUIElementCreateApplication(pid_t(9000 + index)),
        pid: pid_t(9000 + index),
        windowID: UInt32(index + 1),
        bundleID: bundleID ?? "com.test.\(index)",
        appName: appName ?? "Test \(index)",
        title: title ?? "Window \(index)"
    )
}

func makeScrolliniWithModel() -> (Scrollini, [ManagedWindow]) {
    let s = Scrollini()
    var made: [ManagedWindow] = []
    var next = 0
    s.workspaces = [3, 2, 4].map { count in
        let ws = Workspace()
        for _ in 0..<count {
            let w = makeWindow(next)
            next += 1
            made.append(w)
            ws.columns.append(w)
        }
        return ws
    }
    s.workspaces[0].activeColumn = 1
    s.workspaces[2].activeColumn = 3
    s.activeWorkspace = 0
    return (s, made)
}

func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.001) -> Bool {
    abs(a - b) <= tol
}

func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
    approx(a.minX, b.minX) && approx(a.minY, b.minY) && approx(a.width, b.width) && approx(a.height, b.height)
}
