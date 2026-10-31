import AppKit
import WebKit
import DeskCore

public final class Controller: WindowServerDelegate, HotkeyManagerDelegate, ThumbnailServiceDelegate {
    public private(set) var deskModel: DeskModel
    public let windowServer: WindowServer
    public let thumbnailService: ThumbnailService
    public let hotkeyManager: HotkeyManager
    public let bridgeService: BridgeService
    private let gestureMonitor = GestureMonitor()
    public private(set) var overlayController: OverlayController!

    private var isStarted = false

    public init() {
        self.deskModel = DeskModel()
        self.windowServer = WindowServer()
        self.thumbnailService = ThumbnailService()
        self.hotkeyManager = HotkeyManager()
        self.bridgeService = BridgeService()

        self.windowServer.delegate = self
        self.thumbnailService.delegate = self
        self.hotkeyManager.delegate = self
        self.bridgeService.controller = self

        self.overlayController = OverlayController(schemeHandler: bridgeService, scriptMessageHandler: bridgeService)
        self.overlayController.controller = self
    }

    public var layoutURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DeskStream/layout.json")
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        hotkeyManager.registerHotkeys()
        gestureMonitor.onSwipeDown = { [weak self] in self?.toggleOverlay() }
        gestureMonitor.start()
        windowServer.start()
    }

    public var activeWindowID: CGWindowID? {
        deskModel.active.win
    }

    public func thumbnailData(for windowID: CGWindowID) -> Data? {
        thumbnailService.thumbnailData(for: windowID)
    }

    // MARK: - Active Row Helper

    public func getActiveRowWindowIDs() -> [CGWindowID] {
        guard let desk = deskModel.desks.first(where: { $0.id == deskModel.active.desk }),
              deskModel.active.row >= 0 && deskModel.active.row < desk.rows.count else {
            return []
        }
        return desk.rows[deskModel.active.row].wins
    }

    // MARK: - Focusing

    // Windows keep their own frame and state; Desk Stream only raises and focuses them.
    public func focusWindow(_ windowID: CGWindowID) {
        windowServer.makeWindowMainAndActivate(windowID)
        deskModel.focus(windowID: windowID)
        saveLayout()
    }

    // Row and desk hotkeys raise the whole active row, then focus its remembered window.
    private func bringActiveRowForward() {
        let rowIDs = getActiveRowWindowIDs()
        let focusedID = deskModel.active.win ?? rowIDs.first
        for wid in rowIDs where wid != focusedID {
            windowServer.raiseWindow(wid)
        }
        if let focusedID {
            windowServer.makeWindowMainAndActivate(focusedID)
        }
        saveLayout()
        if overlayController.isVisible {
            pushLoadState()
        }
    }

    public func saveLayout() {
        do {
            try deskModel.save(to: layoutURL)
        } catch {
            // Error saving layout
        }
    }

    // MARK: - State Push to JS

    public func pushLoadState() {
        let primaryScreen = NSScreen.screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 0
        let mainScreen = NSScreen.main ?? primaryScreen
        let screenFrame = mainScreen?.frame ?? .zero
        let visibleFrame = mainScreen?.visibleFrame ?? .zero
        let visibleAX = appKitToAXCoordinates(rect: visibleFrame, primaryScreenHeight: primaryHeight)
        let screenAX = appKitToAXCoordinates(rect: screenFrame, primaryScreenHeight: primaryHeight)

        var desksArray: [[String: Any]] = []
        for desk in deskModel.desks {
            var rowsArray: [[String: Any]] = []
            for row in desk.rows {
                rowsArray.append([
                    "wins": row.wins,
                    "ratios": row.ratios
                ])
            }
            desksArray.append([
                "id": desk.id,
                "name": desk.name,
                "rows": rowsArray
            ])
        }

        var windowsDict: [String: Any] = [:]
        for wid in deskModel.allWindowIDs() {
            let widStr = String(wid)
            if let info = windowServer.windowInfo(for: wid) {
                let v = thumbnailService.version(for: wid)
                let thumbVal: Any = v != nil ? "desk://thumb/\(wid)?v=\(v!)" : NSNull()
                windowsDict[widStr] = [
                    "title": info.title,
                    "app": info.appName,
                    "pid": info.pid,
                    "icon": "desk://icon/\(info.pid)",
                    "thumb": thumbVal,
                    "x": Int(info.origin.x - screenAX.origin.x),
                    "y": Int(info.origin.y - screenAX.origin.y),
                    "w": Int(info.size.width),
                    "h": Int(info.size.height)
                ]
            } else {
                windowsDict[widStr] = [
                    "title": "",
                    "app": "",
                    "pid": 0,
                    "icon": "",
                    "thumb": NSNull(),
                    "x": 0,
                    "y": 0,
                    "w": 0,
                    "h": 0
                ]
            }
        }

        let activeDict: [String: Any] = [
            "desk": deskModel.active.desk,
            "row": deskModel.active.row,
            "win": deskModel.active.win != nil ? deskModel.active.win! : NSNull()
        ]

        let screenDict: [String: Any] = [
            "w": Int(screenFrame.width),
            "h": Int(screenFrame.height),
            "visible": [
                "x": Int(visibleAX.origin.x - screenAX.origin.x),
                "y": Int(visibleAX.origin.y - screenAX.origin.y),
                "w": Int(visibleAX.width),
                "h": Int(visibleAX.height)
            ]
        ]

        let state: [String: Any] = [
            "desks": desksArray,
            "windows": windowsDict,
            "active": activeDict,
            "screen": screenDict
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: state, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        overlayController.webView.evaluateJavaScript("window.deskStream && window.deskStream.load(\(jsonString))")
    }

    // MARK: - WindowServerDelegate

    // Desks are the macOS Spaces; the saved layout only keeps the order of windows inside each one
    public func windowServerInitialDiscovery(windows: [WindowInfo]) {
        if let loaded = try? DeskModel.load(from: layoutURL, liveWindowIDs: Set(windows.map(\.id))) {
            deskModel = loaded
        }
        deskModel.syncSpaces(windowServer.spaceDesks())
        saveLayout()
        if overlayController.isVisible {
            pushLoadState()
        }
        // Pictures ready before the first open, so the first flight isn't empty frames that fill in afterwards
        thumbnailService.capture(windowIDs: deskModel.allWindowIDs())
        thumbnailService.captureWallpaper { [weak self] version in
            self?.overlayController.webView.evaluateJavaScript("window.deskStream && window.deskStream.wallpaper('desk://wallpaper?v=\(version)')")
        }
    }

    public func windowServerWindowAdded(info: WindowInfo) {
        syncDesks()
    }

    public func windowServerWindowRemoved(windowID: CGWindowID) {
        syncDesks()
    }

    public func windowServerWindowsRefreshed(windows: [WindowInfo]) {
        syncDesks()
    }

    public func windowServerDidFocusWindow(windowID: CGWindowID) {
        let before = deskModel.active
        deskModel.focus(windowID: windowID)
        guard deskModel.active != before else { return }
        saveLayout()
        if overlayController.isVisible {
            pushLoadState()
        }
    }

    // Repainting the canvas while nothing changed made the click animation stutter every 2 s
    private func syncDesks() {
        guard !movingDesk, deskModel.syncSpaces(windowServer.spaceDesks()) else { return }
        saveLayout()
        if overlayController.isVisible {
            pushLoadState()
        }
    }

    // MARK: - HotkeyManagerDelegate

    public func hotkeyToggleOverlay() {
        toggleOverlay()
    }

    public func hotkeyNavigateRowUp() {
        deskModel.navigateRowUp()
        bringActiveRowForward()
    }

    public func hotkeyNavigateRowDown() {
        deskModel.navigateRowDown()
        bringActiveRowForward()
    }

    public func hotkeyNavigateDeskLeft() {
        deskModel.navigateDeskLeft()
        bringActiveRowForward()
    }

    public func hotkeyNavigateDeskRight() {
        deskModel.navigateDeskRight()
        bringActiveRowForward()
    }

    // MARK: - ThumbnailServiceDelegate

    public func thumbnailDidUpdate(windowID: CGWindowID, version: Int) {
        if overlayController.isVisible {
            overlayController.webView.evaluateJavaScript("window.deskStream && window.deskStream.thumb(\(windowID), \(version))")
        }
    }

    // MARK: - Overlay Show / Toggle

    public func toggleOverlay() {
        overlayController.toggle(activeWindowID: deskModel.active.win)
    }

    public func overlayDidShow(activeWindowID: CGWindowID?) {
        windowServer.syncWindows()
        pushLoadState()
        let ids = deskModel.allWindowIDs()
        // One still per window each time the canvas opens: a live SCStream makes macOS badge every captured window.
        // Not until the windows have flown in: capturing and encoding during the flight cost it frames on a cold start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.overlayController.isVisible else { return }
            self.thumbnailService.capture(windowIDs: ids)
            self.thumbnailService.captureWallpaper { [weak self] version in
                self?.overlayController.webView.evaluateJavaScript("window.deskStream && window.deskStream.wallpaper('desk://wallpaper?v=\(version)')")
            }
        }
        let widStr = activeWindowID != nil ? "\(activeWindowID!)" : "null"
        let order = Set(ids)
        let zOrder = WindowServer.frontToBack().filter { order.contains($0) }.map(String.init).joined(separator: ",")
        let here = SkyLight.currentSpace().map { "'s\($0)'" } ?? "null"
        overlayController.webView.evaluateJavaScript("window.deskStream && window.deskStream.open(\(widStr), [\(zOrder)], \(here))")
    }

    // MARK: - Bridge Event Handlers

    public func bridgeDidReceiveReady() {
        pushLoadState()
    }

    // The window comes forward behind the opaque canvas while its picture flies to the real frame,
    // and the canvas fades only once the flight lands
    public func bridgeDidReceiveGo(windowID: CGWindowID) {
        overlayController.hide(waitingFor: windowServer.isOnOtherSpace(windowID) ? [.flight, .spaceSwitch] : [.flight])
        focusWindow(windowID)
    }

    public func bridgeDidReceiveLanded() {
        overlayController.met(.flight)
    }

    public func bridgeDidReceiveGoDesk(_ id: String) {
        guard let space = Int(id.dropFirst()) else { return }
        overlayController.hide(waitingFor: [.spaceSwitch])
        WindowServer.switchToSpace(space)
    }

    // Adding or removing a desktop goes through Mission Control, drawn under the canvas. The canvas has
    // already shown the change; the layout pushed afterwards confirms it
    public func bridgeDidReceiveAddDesk() {
        overlayController.holdOpen = true
        WindowServer.addDesktop { [weak self] in self?.refreshAfterMissionControl() }
    }

    public func bridgeDidReceiveRemoveDesk(_ id: String) {
        guard let desk = windowServer.spaceDesks().first(where: { $0.id == id }) else { return }
        overlayController.holdOpen = true
        WindowServer.removeDesktop(named: desk.name) { [weak self] in
            self?.refreshAfterMissionControl()
        }
    }

    // The canvas already shows the new order; until Mission Control has caught up, a sync would push the old one back
    public func bridgeDidReceiveMoveDesk(_ id: String, to: Int) {
        let desks = windowServer.spaceDesks()
        guard let from = desks.firstIndex(where: { $0.id == id }), desks.indices.contains(to), from != to else { return }
        overlayController.holdOpen = true
        overlayController.panel.ignoresMouseEvents = true
        movingDesk = true
        WindowServer.moveDesktop(from: from, to: to) { [weak self] in
            guard let self else { return }
            self.movingDesk = false
            self.overlayController.panel.ignoresMouseEvents = false
            self.refreshAfterMissionControl()
        }
    }

    private var movingDesk = false

    private func refreshAfterMissionControl() {
        windowServer.syncWindows()
        syncDesks()
        overlayController.holdOpen = false
        overlayController.refocus()
    }

    public func bridgeDidReceiveDismiss() {
        overlayController.hide()
    }

    public func bridgeDidReceiveLayout(desks: [Desk]) {
        deskModel.adoptLayout(desks)
        saveLayout()
    }

    public func bridgeDidReceiveClose(windowID: CGWindowID) {
        windowServer.closeWindow(wid: windowID)
        windowServer.syncWindows()
        pushLoadState()
    }

    public func bridgeDidReceiveMinimize(windowID: CGWindowID) {
        windowServer.minimizeWindow(wid: windowID)
        deskModel.removeWindow(windowID)
        saveLayout()
        pushLoadState()
    }
}
