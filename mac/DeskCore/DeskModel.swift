import CoreGraphics
import Foundation

public typealias WindowID = CGWindowID

public struct DeskRow: Codable, Equatable {
    public var wins: [WindowID]
    public var ratios: [Double]

    public init(wins: [WindowID] = [], ratios: [Double] = []) {
        self.wins = wins
        self.ratios = ratios
        normalizeRatios()
    }

    public mutating func normalizeRatios() {
        guard !wins.isEmpty else {
            ratios = []
            return
        }
        if ratios.count != wins.count {
            let equal = 1.0 / Double(wins.count)
            ratios = Array(repeating: equal, count: wins.count)
            return
        }
        let sum = ratios.reduce(0.0, +)
        if sum > 0.0 {
            ratios = ratios.map { $0 / sum }
        } else {
            let equal = 1.0 / Double(wins.count)
            ratios = Array(repeating: equal, count: wins.count)
        }
    }
}

public struct Desk: Codable, Equatable {
    public var id: String
    public var name: String
    public var rows: [DeskRow]
    public var lastActiveRow: Int
    public var lastFocusedWindowID: WindowID?

    public init(
        id: String,
        name: String,
        rows: [DeskRow] = [],
        lastActiveRow: Int = 0,
        lastFocusedWindowID: WindowID? = nil
    ) {
        self.id = id
        self.name = name
        self.rows = rows
        self.lastActiveRow = lastActiveRow
        self.lastFocusedWindowID = lastFocusedWindowID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rows
        case lastActiveRow
        case lastFocusedWindowID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.rows = try container.decodeIfPresent([DeskRow].self, forKey: .rows) ?? []
        self.lastActiveRow = try container.decodeIfPresent(Int.self, forKey: .lastActiveRow) ?? 0
        self.lastFocusedWindowID = try container.decodeIfPresent(WindowID.self, forKey: .lastFocusedWindowID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(rows, forKey: .rows)
        // Matches the page's state.desks shape (id, name, rows)
    }
}

public struct ActivePosition: Codable, Equatable {
    public var desk: String
    public var row: Int
    public var win: WindowID?

    public init(desk: String = "", row: Int = 0, win: WindowID? = nil) {
        self.desk = desk
        self.row = row
        self.win = win
    }
}

/// A macOS Space as the window server reports it: its windows front to back
public struct SpaceDesk: Equatable {
    public var id: String
    public var name: String
    public var wins: [WindowID]

    public init(id: String, name: String, wins: [WindowID]) {
        self.id = id
        self.name = name
        self.wins = wins
    }
}

public final class DeskModel: Codable, Equatable {
    public var desks: [Desk]
    public var active: ActivePosition

    private enum CodingKeys: String, CodingKey {
        case desks
        case active
    }

    public static func == (lhs: DeskModel, rhs: DeskModel) -> Bool {
        lhs.desks == rhs.desks && lhs.active == rhs.active
    }

    public init(desks: [Desk] = [], active: ActivePosition = ActivePosition()) {
        self.desks = desks
        self.active = active
        normalizeState()
    }

    public convenience init(
        desks: [Desk],
        activeDesk: String,
        activeRow: Int = 0,
        activeWin: WindowID? = nil
    ) {
        self.init(desks: desks, active: ActivePosition(desk: activeDesk, row: activeRow, win: activeWin))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.desks = try container.decodeIfPresent([Desk].self, forKey: .desks) ?? []
        if let active = try container.decodeIfPresent(ActivePosition.self, forKey: .active) {
            self.active = active
        } else {
            let firstDesk = self.desks.first
            let firstRow = firstDesk?.rows.first
            self.active = ActivePosition(desk: firstDesk?.id ?? "", row: 0, win: firstRow?.wins.first)
        }
        if let deskIndex = self.desks.firstIndex(where: { $0.id == self.active.desk }) {
            self.desks[deskIndex].lastActiveRow = self.active.row
            self.desks[deskIndex].lastFocusedWindowID = self.active.win
        }
        normalizeState()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(desks, forKey: .desks)
        try container.encode(active, forKey: .active)
    }

    // MARK: - First Launch

    /// On first launch with no saved layout, all windows go into 'Desk 1' in front-to-back order, two per row.
    public static func firstLaunch(windows: [WindowID]) -> DeskModel {
        var rows: [DeskRow] = []
        var i = 0
        while i < windows.count {
            if i + 1 < windows.count {
                rows.append(DeskRow(wins: [windows[i], windows[i + 1]], ratios: [0.5, 0.5]))
                i += 2
            } else {
                rows.append(DeskRow(wins: [windows[i]], ratios: [1.0]))
                i += 1
            }
        }
        let desk = Desk(
            id: "d1",
            name: "Desk 1",
            rows: rows,
            lastActiveRow: 0,
            lastFocusedWindowID: windows.first
        )
        let active = ActivePosition(
            desk: "d1",
            row: 0,
            win: windows.first
        )
        return DeskModel(desks: [desk], active: active)
    }

    // MARK: - Window Management (Layout Rules)

    /// New window (created, restored from minimised, or found on launch):
    /// if the active row has fewer than 2 windows it joins that row with equal ratios;
    /// otherwise a new row is inserted right below the active row and becomes active.
    public func addWindow(_ id: WindowID) {
        if let _ = findWindow(id) {
            focus(windowID: id)
            return
        }

        if desks.isEmpty {
            let row = DeskRow(wins: [id], ratios: [1.0])
            let desk = Desk(id: "d1", name: "Desk 1", rows: [row], lastActiveRow: 0, lastFocusedWindowID: id)
            desks.append(desk)
            active = ActivePosition(desk: "d1", row: 0, win: id)
            return
        }

        let deskIndex: Int
        if let idx = desks.firstIndex(where: { $0.id == active.desk }) {
            deskIndex = idx
        } else {
            deskIndex = 0
            active.desk = desks[0].id
        }

        if desks[deskIndex].rows.isEmpty {
            let row = DeskRow(wins: [id], ratios: [1.0])
            desks[deskIndex].rows.append(row)
            active.row = 0
            active.win = id
            desks[deskIndex].lastActiveRow = 0
            desks[deskIndex].lastFocusedWindowID = id
            return
        }

        let currentRow = min(max(0, active.row), desks[deskIndex].rows.count - 1)

        if desks[deskIndex].rows[currentRow].wins.count < 2 {
            desks[deskIndex].rows[currentRow].wins.append(id)
            desks[deskIndex].rows[currentRow].normalizeRatios()
            active.row = currentRow
            active.win = id
            desks[deskIndex].lastActiveRow = currentRow
            desks[deskIndex].lastFocusedWindowID = id
        } else {
            let newRow = DeskRow(wins: [id], ratios: [1.0])
            let newRowIndex = currentRow + 1
            desks[deskIndex].rows.insert(newRow, at: newRowIndex)
            active.row = newRowIndex
            active.win = id
            desks[deskIndex].lastActiveRow = newRowIndex
            desks[deskIndex].lastFocusedWindowID = id
        }
    }

    /// Closed window: removed; an emptied row is removed;
    /// if it was the active row, the row above (or below when none) becomes active.
    public func removeWindow(_ id: WindowID) {
        guard let loc = findWindow(id) else { return }
        let dIdx = loc.deskIndex
        let rIdx = loc.rowIndex
        let wIdx = loc.winIndex

        desks[dIdx].rows[rIdx].wins.remove(at: wIdx)
        if wIdx < desks[dIdx].rows[rIdx].ratios.count {
            desks[dIdx].rows[rIdx].ratios.remove(at: wIdx)
        }

        if !desks[dIdx].rows[rIdx].wins.isEmpty {
            desks[dIdx].rows[rIdx].normalizeRatios()

            if desks[dIdx].id == active.desk && active.row == rIdx && active.win == id {
                active.win = desks[dIdx].rows[rIdx].wins.first
                desks[dIdx].lastFocusedWindowID = active.win
            } else if desks[dIdx].lastFocusedWindowID == id {
                desks[dIdx].lastFocusedWindowID = desks[dIdx].rows[rIdx].wins.first
            }
        } else {
            // Emptied row is removed
            desks[dIdx].rows.remove(at: rIdx)

            let isActiveDesk = (desks[dIdx].id == active.desk)
            let wasActiveRow = isActiveDesk && (active.row == rIdx)

            if wasActiveRow {
                if rIdx > 0 {
                    // Row above
                    let newRow = rIdx - 1
                    active.row = newRow
                    active.win = desks[dIdx].rows[newRow].wins.first
                    desks[dIdx].lastActiveRow = newRow
                    desks[dIdx].lastFocusedWindowID = active.win
                } else {
                    // rIdx == 0: row below when none
                    if !desks[dIdx].rows.isEmpty {
                        active.row = 0
                        active.win = desks[dIdx].rows[0].wins.first
                        desks[dIdx].lastActiveRow = 0
                        desks[dIdx].lastFocusedWindowID = active.win
                    } else {
                        active.row = 0
                        active.win = nil
                        desks[dIdx].lastActiveRow = 0
                        desks[dIdx].lastFocusedWindowID = nil
                    }
                }
            } else if isActiveDesk {
                if rIdx < active.row {
                    active.row -= 1
                    desks[dIdx].lastActiveRow = active.row
                }
            } else {
                if desks[dIdx].lastActiveRow == rIdx {
                    if rIdx > 0 {
                        desks[dIdx].lastActiveRow = rIdx - 1
                    } else {
                        desks[dIdx].lastActiveRow = 0
                    }
                    if !desks[dIdx].rows.isEmpty {
                        desks[dIdx].lastFocusedWindowID = desks[dIdx].rows[desks[dIdx].lastActiveRow].wins.first
                    } else {
                        desks[dIdx].lastFocusedWindowID = nil
                    }
                } else if rIdx < desks[dIdx].lastActiveRow {
                    desks[dIdx].lastActiveRow -= 1
                }
            }
        }
    }

    /// Adopting a page layout:
    /// ids that no longer exist are dropped, empty rows and empty desks with no name change are kept
    /// as the page sent them, windows missing from the message are appended to the active desk by
    /// the new-window rule. Ratios are renormalised to sum to 1.
    public func adoptLayout(_ incomingDesks: [Desk]) {
        let currentlyKnownIDs = allWindowIDs()
        let knownSet = Set(currentlyKnownIDs)

        var adoptedDesks: [Desk] = []
        var seenInIncoming = Set<WindowID>()

        for incomingDesk in incomingDesks {
            var filteredRows: [DeskRow] = []
            for row in incomingDesk.rows {
                var survivingWins: [WindowID] = []
                var survivingRatios: [Double] = []
                for (wIdx, wid) in row.wins.enumerated() {
                    if knownSet.contains(wid) {
                        survivingWins.append(wid)
                        seenInIncoming.insert(wid)
                        if wIdx < row.ratios.count {
                            survivingRatios.append(row.ratios[wIdx])
                        }
                    }
                }
                var filteredRow = DeskRow(wins: survivingWins, ratios: survivingRatios)
                filteredRow.normalizeRatios()
                filteredRows.append(filteredRow)
            }
            var adoptedDesk = Desk(
                id: incomingDesk.id,
                name: incomingDesk.name,
                rows: filteredRows,
                lastActiveRow: incomingDesk.lastActiveRow,
                lastFocusedWindowID: incomingDesk.lastFocusedWindowID
            )
            if !filteredRows.isEmpty {
                adoptedDesk.lastActiveRow = min(max(0, adoptedDesk.lastActiveRow), filteredRows.count - 1)
            } else {
                adoptedDesk.lastActiveRow = 0
            }
            adoptedDesks.append(adoptedDesk)
        }

        if adoptedDesks.isEmpty {
            adoptedDesks = [Desk(id: "d1", name: "Desk 1", rows: [])]
        }

        self.desks = adoptedDesks

        if !desks.contains(where: { $0.id == active.desk }) {
            active.desk = desks[0].id
        }
        let activeDeskIdx = desks.firstIndex(where: { $0.id == active.desk }) ?? 0
        if !desks[activeDeskIdx].rows.isEmpty {
            active.row = min(max(0, active.row), desks[activeDeskIdx].rows.count - 1)
            active.win = desks[activeDeskIdx].rows[active.row].wins.first
        } else {
            active.row = 0
            active.win = nil
        }
        desks[activeDeskIdx].lastActiveRow = active.row
        desks[activeDeskIdx].lastFocusedWindowID = active.win

        // Missing windows are appended by the new-window rule
        let missingIDs = currentlyKnownIDs.filter { !seenInIncoming.contains($0) }
        for missingID in missingIDs {
            addWindow(missingID)
        }
    }

    // MARK: - Navigation

    /// Previous row of the active desk (no wrap)
    public func navigateRowUp() {
        guard let deskIdx = desks.firstIndex(where: { $0.id == active.desk }) else { return }
        let rowCount = desks[deskIdx].rows.count
        guard rowCount > 0 else { return }
        if active.row > 0 {
            active.row -= 1
            active.win = desks[deskIdx].rows[active.row].wins.first
            desks[deskIdx].lastActiveRow = active.row
            desks[deskIdx].lastFocusedWindowID = active.win
        }
    }

    /// Next row of the active desk (no wrap)
    public func navigateRowDown() {
        guard let deskIdx = desks.firstIndex(where: { $0.id == active.desk }) else { return }
        let rowCount = desks[deskIdx].rows.count
        guard rowCount > 0 else { return }
        if active.row < rowCount - 1 {
            active.row += 1
            active.win = desks[deskIdx].rows[active.row].wins.first
            desks[deskIdx].lastActiveRow = active.row
            desks[deskIdx].lastFocusedWindowID = active.win
        }
    }

    /// Previous desk (no wrap), landing on that desk's last active row
    public func navigateDeskLeft() {
        guard let deskIdx = desks.firstIndex(where: { $0.id == active.desk }) else { return }
        if deskIdx > 0 {
            switchToDesk(index: deskIdx - 1)
        }
    }

    /// Next desk (no wrap), landing on that desk's last active row
    public func navigateDeskRight() {
        guard let deskIdx = desks.firstIndex(where: { $0.id == active.desk }) else { return }
        if deskIdx < desks.count - 1 {
            switchToDesk(index: deskIdx + 1)
        }
    }

    public func switchToDesk(index: Int) {
        guard index >= 0 && index < desks.count else { return }
        let targetDesk = desks[index]
        active.desk = targetDesk.id
        if targetDesk.rows.isEmpty {
            active.row = 0
            active.win = nil
            return
        }
        let targetRow = min(max(0, targetDesk.lastActiveRow), targetDesk.rows.count - 1)
        active.row = targetRow
        let rowWins = targetDesk.rows[targetRow].wins
        if let lastWin = targetDesk.lastFocusedWindowID, rowWins.contains(lastWin) {
            active.win = lastWin
        } else {
            active.win = rowWins.first
        }
    }

    /// The user focusing a hidden window by other means (Cmd-Tab, Dock, a notification)
    /// makes that window's row active.
    public func focus(windowID: WindowID) {
        guard let loc = findWindow(windowID) else { return }
        let desk = desks[loc.deskIndex]
        active.desk = desk.id
        active.row = loc.rowIndex
        active.win = windowID
        desks[loc.deskIndex].lastActiveRow = loc.rowIndex
        desks[loc.deskIndex].lastFocusedWindowID = windowID
    }

    // MARK: - Spaces

    /// Desks mirror the Spaces in Mission Control order. A window keeps its place in its Space's desk, windows new to
    /// that Space go to the end, and rows are cut again: up to two windows one per row, more two per row.
    /// Returns whether anything changed.
    @discardableResult
    public func syncSpaces(_ spaces: [SpaceDesk]) -> Bool {
        let oldDesks = desks, oldActive = active
        let oldByID = Dictionary(oldDesks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        desks = spaces.map { space in
            let old = oldByID[space.id]
            let live = Set(space.wins)
            let kept = (old?.rows.flatMap(\.wins) ?? []).filter(live.contains)
            let wins = kept + space.wins.filter { !kept.contains($0) }
            return Desk(id: space.id, name: space.name, rows: Self.rows(for: wins),
                        lastActiveRow: old?.lastActiveRow ?? 0, lastFocusedWindowID: old?.lastFocusedWindowID)
        }
        if let win = active.win, let loc = findWindow(win) {
            active.desk = desks[loc.deskIndex].id
            active.row = loc.rowIndex
        }
        normalizeState()
        return desks != oldDesks || active != oldActive
    }

    static func rows(for wins: [WindowID]) -> [DeskRow] {
        let perRow = wins.count > 2 ? 2 : 1
        return stride(from: 0, to: wins.count, by: perRow).map {
            DeskRow(wins: Array(wins[$0..<min($0 + perRow, wins.count)]))
        }
    }

    // MARK: - Persistence

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL, liveWindowIDs: Set<WindowID>) throws -> DeskModel {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let model = try decoder.decode(DeskModel.self, from: data)

        // Drop ids not in liveWindowIDs, remove emptied rows
        for dIdx in 0..<model.desks.count {
            var filteredRows: [DeskRow] = []
            for row in model.desks[dIdx].rows {
                var survivingWins: [WindowID] = []
                var survivingRatios: [Double] = []
                for (wIdx, wid) in row.wins.enumerated() {
                    if liveWindowIDs.contains(wid) {
                        survivingWins.append(wid)
                        if wIdx < row.ratios.count {
                            survivingRatios.append(row.ratios[wIdx])
                        }
                    }
                }
                if !survivingWins.isEmpty {
                    var filteredRow = DeskRow(wins: survivingWins, ratios: survivingRatios)
                    filteredRow.normalizeRatios()
                    filteredRows.append(filteredRow)
                }
            }
            model.desks[dIdx].rows = filteredRows
        }

        model.normalizeState()
        return model
    }

    // MARK: - Helpers

    public func normalizeState() {
        if desks.isEmpty {
            desks = [Desk(id: "d1", name: "Desk 1", rows: [])]
        }
        guard let deskIdx = desks.firstIndex(where: { $0.id == active.desk }) else {
            active.desk = desks[0].id
            normalizeActiveRowAndWin(deskIndex: 0)
            return
        }
        normalizeActiveRowAndWin(deskIndex: deskIdx)
    }

    private func normalizeActiveRowAndWin(deskIndex: Int) {
        let desk = desks[deskIndex]
        if desk.rows.isEmpty {
            active.row = 0
            active.win = nil
            desks[deskIndex].lastActiveRow = 0
            desks[deskIndex].lastFocusedWindowID = nil
            return
        }
        let clampedRow = min(max(0, active.row), desk.rows.count - 1)
        active.row = clampedRow
        desks[deskIndex].lastActiveRow = clampedRow

        let rowWins = desk.rows[clampedRow].wins
        if let win = active.win, rowWins.contains(win) {
            desks[deskIndex].lastFocusedWindowID = win
        } else {
            active.win = rowWins.first
            desks[deskIndex].lastFocusedWindowID = rowWins.first
        }
    }

    public func allWindowIDs() -> [WindowID] {
        var ids: [WindowID] = []
        for desk in desks {
            for row in desk.rows {
                ids.append(contentsOf: row.wins)
            }
        }
        return ids
    }

    public struct WindowLocation: Equatable {
        public var deskIndex: Int
        public var rowIndex: Int
        public var winIndex: Int

        public init(deskIndex: Int, rowIndex: Int, winIndex: Int) {
            self.deskIndex = deskIndex
            self.rowIndex = rowIndex
            self.winIndex = winIndex
        }
    }

    public func findWindow(_ id: WindowID) -> WindowLocation? {
        for (dIdx, desk) in desks.enumerated() {
            for (rIdx, row) in desk.rows.enumerated() {
                for (wIdx, winId) in row.wins.enumerated() {
                    if winId == id {
                        return WindowLocation(deskIndex: dIdx, rowIndex: rIdx, winIndex: wIdx)
                    }
                }
            }
        }
        return nil
    }
}
