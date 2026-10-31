import XCTest
@testable import DeskCore

final class DeskModelTests: XCTestCase {

    // MARK: - A1 & A5: Join vs Insert-Below
    func testJoinVsInsertBelow() {
        let model = DeskModel()
        XCTAssertEqual(model.desks.count, 1)
        XCTAssertEqual(model.desks[0].rows.count, 0)

        // First window creates first row
        model.addWindow(100)
        XCTAssertEqual(model.desks[0].rows.count, 1)
        XCTAssertEqual(model.desks[0].rows[0].wins, [100])
        XCTAssertEqual(model.desks[0].rows[0].ratios, [1.0])
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 100)

        // Second window joins active row (fewer than 2 windows: count was 1)
        model.addWindow(101)
        XCTAssertEqual(model.desks[0].rows.count, 1)
        XCTAssertEqual(model.desks[0].rows[0].wins, [100, 101])
        XCTAssertEqual(model.desks[0].rows[0].ratios, [0.5, 0.5])
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 101)

        // Third window: active row has 2 windows, so a new row is inserted right below and becomes active
        model.addWindow(102)
        XCTAssertEqual(model.desks[0].rows.count, 2)
        XCTAssertEqual(model.desks[0].rows[0].wins, [100, 101])
        XCTAssertEqual(model.desks[0].rows[0].ratios, [0.5, 0.5])
        XCTAssertEqual(model.desks[0].rows[1].wins, [102])
        XCTAssertEqual(model.desks[0].rows[1].ratios, [1.0])
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 102)

        // Adding when active row is row 0: insert below row 0 (at index 1)
        model.active.row = 0
        model.active.win = 100
        model.addWindow(103)
        // Since row 0 had 2 windows, row is inserted right below row 0, which is at index 1
        XCTAssertEqual(model.desks[0].rows.count, 3)
        XCTAssertEqual(model.desks[0].rows[0].wins, [100, 101])
        XCTAssertEqual(model.desks[0].rows[1].wins, [103])
        XCTAssertEqual(model.desks[0].rows[2].wins, [102])
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 103)
    }

    // MARK: - A1 & A5: Close Window Falls Back Up Then Down
    func testCloseOfActiveRowFallsBackUpThenDown() {
        let desk = Desk(
            id: "d1",
            name: "Desk 1",
            rows: [
                DeskRow(wins: [10], ratios: [1.0]),
                DeskRow(wins: [20], ratios: [1.0]),
                DeskRow(wins: [30], ratios: [1.0])
            ]
        )
        let model = DeskModel(desks: [desk], activeDesk: "d1", activeRow: 1, activeWin: 20)

        // Close window 20 in row 1 (active row).
        // Row 1 is emptied and removed.
        // Falls back to row above (row 0).
        model.removeWindow(20)
        XCTAssertEqual(model.desks[0].rows.count, 2)
        XCTAssertEqual(model.desks[0].rows[0].wins, [10])
        XCTAssertEqual(model.desks[0].rows[1].wins, [30])
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 10)

        // Now active row is 0 (window 10).
        // Close window 10. Row 0 is emptied and removed.
        // No row above, so falls back to row below (old row 1, now row 0 containing [30]).
        model.removeWindow(10)
        XCTAssertEqual(model.desks[0].rows.count, 1)
        XCTAssertEqual(model.desks[0].rows[0].wins, [30])
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 30)

        // Close window 30: desk becomes empty
        model.removeWindow(30)
        XCTAssertEqual(model.desks[0].rows.count, 0)
        XCTAssertEqual(model.active.row, 0)
        XCTAssertNil(model.active.win)
    }

    // MARK: - A1 & A5: Adopt Drops Unknown and Appends Missing
    func testAdoptDropsUnknownAndAppendsMissing() {
        // Initial model knows windows [100, 101, 102]
        let desk = Desk(
            id: "d1",
            name: "Desk 1",
            rows: [
                DeskRow(wins: [100], ratios: [1.0]),
                DeskRow(wins: [101, 102], ratios: [0.5, 0.5])
            ]
        )
        let model = DeskModel(desks: [desk], activeDesk: "d1", activeRow: 0, activeWin: 100)

        // Incoming layout from page has:
        // - Row 0: [100, 999] (999 is unknown and must be dropped)
        // - Missing from message: [101, 102]
        let incomingDesk = Desk(
            id: "d1",
            name: "Desk 1",
            rows: [
                DeskRow(wins: [100, 999], ratios: [0.5, 0.5])
            ]
        )

        model.adoptLayout([incomingDesk])

        // 999 is dropped, leaving Row 0 with [100].
        // Missing [101, 102] are appended by new-window rule:
        // 101 joins Row 0 (count was 1 < 2) -> Row 0 becomes [100, 101] with ratios [0.5, 0.5]
        // 102 creates new row inserted below Row 0 -> Row 1 becomes [102] with ratio [1.0]
        XCTAssertEqual(model.desks.count, 1)
        XCTAssertEqual(model.desks[0].rows.count, 2)
        XCTAssertEqual(model.desks[0].rows[0].wins, [100, 101])
        XCTAssertEqual(model.desks[0].rows[0].ratios, [0.5, 0.5])
        XCTAssertEqual(model.desks[0].rows[1].wins, [102])
        XCTAssertEqual(model.desks[0].rows[1].ratios, [1.0])
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 102)
    }

    // MARK: - A1 & A5: Ratios Renormalised
    func testRatiosRenormalised() {
        let row = DeskRow(wins: [1, 2, 3], ratios: [2.0, 3.0, 5.0])
        XCTAssertEqual(row.ratios, [0.2, 0.3, 0.5])

        let desk = Desk(id: "d1", name: "Desk 1", rows: [row])
        let model = DeskModel(desks: [desk], activeDesk: "d1", activeRow: 0, activeWin: 1)

        // Remove window 2: remaining ratios [0.2, 0.5] renormalized to sum to 1.0 (2/7 and 5/7)
        model.removeWindow(2)
        let expected0 = 0.2 / 0.7
        let expected1 = 0.5 / 0.7
        XCTAssertEqual(model.desks[0].rows[0].wins, [1, 3])
        XCTAssertEqual(model.desks[0].rows[0].ratios[0], expected0, accuracy: 1e-6)
        XCTAssertEqual(model.desks[0].rows[0].ratios[1], expected1, accuracy: 1e-6)
        XCTAssertEqual(model.desks[0].rows[0].ratios.reduce(0, +), 1.0, accuracy: 1e-6)
    }

    // MARK: - A2 & A5: No-Wrap Navigation
    func testNoWrapNavigation() {
        let desk1 = Desk(
            id: "d1",
            name: "Desk 1",
            rows: [
                DeskRow(wins: [10], ratios: [1.0]),
                DeskRow(wins: [20], ratios: [1.0])
            ]
        )
        let desk2 = Desk(
            id: "d2",
            name: "Desk 2",
            rows: [
                DeskRow(wins: [30], ratios: [1.0])
            ]
        )
        let model = DeskModel(desks: [desk1, desk2], activeDesk: "d1", activeRow: 0, activeWin: 10)

        // Row navigation: at row 0, up does not wrap
        model.navigateRowUp()
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 10)

        // Down goes to row 1
        model.navigateRowDown()
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 20)

        // At row 1, down does not wrap
        model.navigateRowDown()
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 20)

        // Desk navigation: at desk 0 ("d1"), left does not wrap
        model.navigateDeskLeft()
        XCTAssertEqual(model.active.desk, "d1")

        // Right goes to desk 1 ("d2")
        model.navigateDeskRight()
        XCTAssertEqual(model.active.desk, "d2")
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 30)

        // At desk 1, right does not wrap
        model.navigateDeskRight()
        XCTAssertEqual(model.active.desk, "d2")
    }

    // MARK: - A2 & A5: Desk Switch Restores Last Active Row
    func testDeskSwitchRestoresLastRow() {
        let desk1 = Desk(
            id: "d1",
            name: "Desk 1",
            rows: [
                DeskRow(wins: [10], ratios: [1.0]),
                DeskRow(wins: [11], ratios: [1.0]),
                DeskRow(wins: [12], ratios: [1.0])
            ]
        )
        let desk2 = Desk(
            id: "d2",
            name: "Desk 2",
            rows: [
                DeskRow(wins: [20], ratios: [1.0]),
                DeskRow(wins: [21], ratios: [1.0])
            ]
        )
        let model = DeskModel(desks: [desk1, desk2], activeDesk: "d1", activeRow: 0, activeWin: 10)

        // On Desk 1, navigate down to row 2
        model.navigateRowDown() // row 1
        model.navigateRowDown() // row 2
        XCTAssertEqual(model.active.row, 2)
        XCTAssertEqual(model.active.win, 12)

        // Switch to Desk 2: Desk 2's last active row was 0
        model.navigateDeskRight()
        XCTAssertEqual(model.active.desk, "d2")
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 20)

        // In Desk 2, navigate to row 1
        model.navigateRowDown()
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 21)

        // Switch back to Desk 1: restores row 2 and focused window 12!
        model.navigateDeskLeft()
        XCTAssertEqual(model.active.desk, "d1")
        XCTAssertEqual(model.active.row, 2)
        XCTAssertEqual(model.active.win, 12)

        // Switch back to Desk 2: restores row 1 and focused window 21!
        model.navigateDeskRight()
        XCTAssertEqual(model.active.desk, "d2")
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 21)
    }

    // MARK: - A1 & A5: First Launch Two Per Row
    func testFirstLaunchTwoPerRow() {
        let windows: [WindowID] = [10, 20, 30, 40, 50]
        let model = DeskModel.firstLaunch(windows: windows)

        XCTAssertEqual(model.desks.count, 1)
        let desk = model.desks[0]
        XCTAssertEqual(desk.id, "d1")
        XCTAssertEqual(desk.name, "Desk 1")
        XCTAssertEqual(desk.rows.count, 3)

        // Row 0 has first two windows with 0.5/0.5
        XCTAssertEqual(desk.rows[0].wins, [10, 20])
        XCTAssertEqual(desk.rows[0].ratios, [0.5, 0.5])

        // Row 1 has next two windows with 0.5/0.5
        XCTAssertEqual(desk.rows[1].wins, [30, 40])
        XCTAssertEqual(desk.rows[1].ratios, [0.5, 0.5])

        // Row 2 has final odd window with 1.0
        XCTAssertEqual(desk.rows[2].wins, [50])
        XCTAssertEqual(desk.rows[2].ratios, [1.0])

        // Active desk and row
        XCTAssertEqual(model.active.desk, "d1")
        XCTAssertEqual(model.active.row, 0)
        XCTAssertEqual(model.active.win, 10)
    }

    // MARK: - A3: Persistence and Codable
    func testCodableAndPersistence() throws {
        let desk = Desk(
            id: "d1",
            name: "Desk 1",
            rows: [
                DeskRow(wins: [100, 200], ratios: [0.5, 0.5]),
                DeskRow(wins: [300], ratios: [1.0])
            ]
        )
        let model = DeskModel(desks: [desk], activeDesk: "d1", activeRow: 0, activeWin: 100)

        // Encode and check JSON shape
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(model)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["desks"])
        XCTAssertNotNil(json?["active"])

        let activeDict = json?["active"] as? [String: Any]
        XCTAssertEqual(activeDict?["desk"] as? String, "d1")
        XCTAssertEqual(activeDict?["row"] as? Int, 0)
        XCTAssertEqual(activeDict?["win"] as? UInt32, 100)

        // Save to file and load with liveWindowIDs filtering out window 200 and 300
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("layout.json")

        try model.save(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        // Window 300 is dead; 200 is dead; only 100 is alive
        let loaded = try DeskModel.load(from: tempURL, liveWindowIDs: [100])
        XCTAssertEqual(loaded.desks.count, 1)
        // Row 1 (which had only 300) was emptied and removed!
        XCTAssertEqual(loaded.desks[0].rows.count, 1)
        // Row 0 has only window 100 with ratio 1.0
        XCTAssertEqual(loaded.desks[0].rows[0].wins, [100])
        XCTAssertEqual(loaded.desks[0].rows[0].ratios, [1.0])
        XCTAssertEqual(loaded.active.win, 100)

        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    // MARK: - Window Focus
    func testFocusWindow() {
        let desk1 = Desk(id: "d1", name: "Desk 1", rows: [DeskRow(wins: [10], ratios: [1.0])])
        let desk2 = Desk(id: "d2", name: "Desk 2", rows: [DeskRow(wins: [20], ratios: [1.0]), DeskRow(wins: [30], ratios: [1.0])])
        let model = DeskModel(desks: [desk1, desk2], activeDesk: "d1", activeRow: 0, activeWin: 10)

        model.focus(windowID: 30)
        XCTAssertEqual(model.active.desk, "d2")
        XCTAssertEqual(model.active.row, 1)
        XCTAssertEqual(model.active.win, 30)
        XCTAssertEqual(model.desks[1].lastActiveRow, 1)
        XCTAssertEqual(model.desks[1].lastFocusedWindowID, 30)
    }

    // MARK: - Desks follow macOS Spaces
    func testSyncSpacesMirrorsSpacesAndKeepsOrder() {
        // Layout from before Spaces were tracked: everything in one desk
        let model = DeskModel.firstLaunch(windows: [177, 603, 60, 63])
        model.focus(windowID: 60)

        XCTAssertTrue(model.syncSpaces([
            SpaceDesk(id: "s3", name: "Desktop 1", wins: [63]),
            SpaceDesk(id: "s4", name: "Desktop 2", wins: [603, 177, 60]),
        ]))
        XCTAssertEqual(model.desks.map(\.id), ["s3", "s4"])
        XCTAssertEqual(model.desks.map(\.name), ["Desktop 1", "Desktop 2"])
        XCTAssertEqual(model.desks[0].rows.map(\.wins), [[63]])
        XCTAssertEqual(model.desks[1].rows.map(\.wins), [[603, 177], [60]])
        XCTAssertEqual(model.active, ActivePosition(desk: "s4", row: 1, win: 60))

        // Same Spaces in a new front-to-back order: nothing moves
        XCTAssertFalse(model.syncSpaces([
            SpaceDesk(id: "s3", name: "Desktop 1", wins: [63]),
            SpaceDesk(id: "s4", name: "Desktop 2", wins: [60, 177, 603]),
        ]))

        // A window goes full screen into its own Space, another closes, an empty desktop stays
        XCTAssertTrue(model.syncSpaces([
            SpaceDesk(id: "s3", name: "Desktop 1", wins: []),
            SpaceDesk(id: "s4", name: "Desktop 2", wins: [603, 177]),
            SpaceDesk(id: "s9", name: "Preview", wins: [60]),
        ]))
        XCTAssertEqual(model.desks.map(\.id), ["s3", "s4", "s9"])
        XCTAssertEqual(model.desks[0].rows, [])
        XCTAssertEqual(model.desks[1].rows.map(\.wins), [[603], [177]])
        XCTAssertEqual(model.active, ActivePosition(desk: "s9", row: 0, win: 60))
    }

    func testSyncSpacesFollowsMissionControlOrder() {
        let model = DeskModel.firstLaunch(windows: [63, 603])
        model.syncSpaces([
            SpaceDesk(id: "s3", name: "Desktop 1", wins: [63]),
            SpaceDesk(id: "s4", name: "Desktop 2", wins: [603]),
        ])
        // A full-screen Space opens after Desktop 2, then a desktop is added after it
        model.syncSpaces([
            SpaceDesk(id: "s3", name: "Desktop 1", wins: [63]),
            SpaceDesk(id: "s4", name: "Desktop 2", wins: []),
            SpaceDesk(id: "s9", name: "VidHub", wins: [603]),
            SpaceDesk(id: "s6", name: "Desktop 3", wins: []),
        ])
        XCTAssertEqual(model.desks.map(\.id), ["s3", "s4", "s9", "s6"])
    }
}
