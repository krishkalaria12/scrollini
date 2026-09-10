#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class PersistenceTests: XCTestCase {

    func testRoundtrip() throws {
        let id = PersistentWindowIdentity(bundleID: "com.test.app", appName: "Test", title: "Window")
        let state = PersistentWindowState(identity: id, workspace: 1, column: 2, manualWidthRatio: 0.7)
        let snap = PersistentLayoutSnapshot(version: 2, activeWorkspace: 1, activeColumns: [0,1], scrollOffsets: [nil, 12.5], focusedWindow: id, windows: [state])
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PersistentLayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.activeWorkspace, 1)
        XCTAssertEqual(decoded.activeColumns, [0,1])
        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.focusedWindow, id)
    }

    func testBadVersionNotRead() throws {
        let s = Scrollini()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(persistLayout: true, statePath: url.path), sourceURL: nil, sourceModificationDate: nil)
        let bad = PersistentLayoutSnapshot(version: 99, activeWorkspace: 0, activeColumns: [0], scrollOffsets: [nil], focusedWindow: nil, windows: [])
        try JSONEncoder().encode(bad).write(to: url)
        XCTAssertNil(s.readPersistentLayoutSnapshot())
        try? FileManager.default.removeItem(at: url)
    }

    func testRectSnapshot() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 400)
        XCTAssertEqual(RectSnapshot(r).cgRect, r)
    }

    func testRestoreSnapshotOptional() throws {
        let r = CGRect(x: 0,y: 0,width: 100,height: 100)
        let snap = RestoreSnapshot(windowIDs: [1,2], floatingWindowIDs: nil, viewport: RectSnapshot(r))
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(RestoreSnapshot.self, from: data)
        XCTAssertNil(decoded.floatingWindowIDs)
        XCTAssertEqual(decoded.windowIDs, [1,2])
    }

    func testPersistentStateURLRespectsXDG() {
        let s = Scrollini()
        let tmp = "/tmp/custom-\(UUID().uuidString).json"
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(statePath: tmp), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.persistentLayoutStateURL.path, tmp)
    }
}

#endif
