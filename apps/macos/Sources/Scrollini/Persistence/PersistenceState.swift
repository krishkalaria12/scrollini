import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    var persistLayoutEnabled: Bool {
        config.persistLayout ?? ScrolliniConfig.fallback.persistLayout ?? true
    }

    var persistentLayoutStateURL: URL {
        if let statePath = config.statePath, !statePath.isEmpty {
            return URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
        }

        let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local")
                .appendingPathComponent("state")
        return stateHome
            .appendingPathComponent("scrollini", isDirectory: true)
            .appendingPathComponent("layout.json")
    }
}
