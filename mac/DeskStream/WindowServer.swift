import AppKit
import ApplicationServices
import DeskCore

// CGWindowID from the private _AXUIElementGetWindow with a comment saying it is the only way to map an AX window to its id (yabai, AltTab and AeroSpace use it)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Converts an AppKit screen frame to AX top-left coordinates (y measured down from top of primary screen).
public func appKitToAXCoordinates(rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(
        x: rect.origin.x,
        y: primaryScreenHeight - (rect.origin.y + rect.height),
        width: rect.width,
        height: rect.height
    )
}

public struct WindowInfo {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let pid: pid_t
    public let origin: CGPoint
    public let size: CGSize
    public let element: AXUIElement
    public let space: Int
}

public protocol WindowServerDelegate: AnyObject {
    func windowServerInitialDiscovery(windows: [WindowInfo])
    func windowServerWindowAdded(info: WindowInfo)
    func windowServerWindowRemoved(windowID: CGWindowID)
    func windowServerDidFocusWindow(windowID: CGWindowID)
    func windowServerWindowsRefreshed(windows: [WindowInfo])
}

public final class WindowServer: NSObject {
    public weak var delegate: WindowServerDelegate?

    private var knownWindows: [CGWindowID: WindowInfo] = [:]
    private var appObservers: [pid_t: AXObserver] = [:]
    private var timer: Timer?
    private var syncWorkItem: DispatchWorkItem?
    private var isInitialDiscoveryDone = false
    private var remoteElements: [CGWindowID: AXUIElement] = [:]
    private var remoteMisses = Set<CGWindowID>()
    private var spaces: [SkyLight.Space] = []
    private var spaceWindows: [Int: [CGWindowID]] = [:]

    public override init() {
        super.init()
    }

    public func start() {
        setupWorkspaceNotifications()

        // Sync immediately if accessibility is already granted
        if AXIsProcessTrusted() {
            syncWindows()
        }

        // Periodic timer re-checks accessibility and syncs windows every 2s
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAndSync()
        }
    }

    deinit {
        timer?.invalidate()
        syncWorkItem?.cancel()
        tearDownObservers()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func checkAndSync() {
        guard AXIsProcessTrusted() else { return }
        syncWindows()
    }

    private func setupWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleAppLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return
        }
        observeApp(app)
        scheduleSync()
    }

    @objc private func handleAppTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        unobserveApp(pid: app.processIdentifier)
        scheduleSync()
    }

    @objc private func handleAppActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success {
            let winElement = focusedRef as! AXUIElement
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(winElement, &wid) == .success && wid != 0 {
                delegate?.windowServerDidFocusWindow(windowID: wid)
            }
        }
    }

    public func scheduleSync() {
        syncWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.syncWindows()
        }
        syncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    public func syncWindows() {
        guard AXIsProcessTrusted() else { return }

        let discovered = discoverWindows()
        let currentMap = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        let currentIDs = Set(currentMap.keys)
        let oldIDs = Set(knownWindows.keys)

        knownWindows = currentMap

        if !isInitialDiscoveryDone {
            isInitialDiscoveryDone = true
            delegate?.windowServerInitialDiscovery(windows: discovered)
            return
        }

        let addedIDs = currentIDs.subtracting(oldIDs)
        let removedIDs = oldIDs.subtracting(currentIDs)

        for wid in addedIDs {
            if let info = currentMap[wid] {
                delegate?.windowServerWindowAdded(info: info)
            }
        }

        for wid in removedIDs {
            delegate?.windowServerWindowRemoved(windowID: wid)
        }

        if addedIDs.isEmpty && removedIDs.isEmpty {
            delegate?.windowServerWindowsRefreshed(windows: discovered)
        }
    }

    public func discoverWindows() -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }

        let currentPid = NSRunningApplication.current.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != currentPid
        }

        spaces = SkyLight.spaces()
        spaceWindows = [:]
        var spaceOf: [CGWindowID: Int] = [:]
        for space in spaces {
            for wid in SkyLight.windows(in: space.id) where spaceOf[wid] == nil {
                spaceOf[wid] = space.id
                spaceWindows[space.id, default: []].append(wid)
            }
        }

        var results: [WindowInfo] = []
        for app in apps {
            observeApp(app)

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }
            results += axWindows.compactMap { windowInfo(element: $0, app: app, spaceOf: spaceOf) }
        }

        results += otherSpaceWindows(apps: apps, spaceOf: spaceOf, known: Set(results.map(\.id)))
        return results
    }

    private func windowInfo(element: AXUIElement, app: NSRunningApplication, spaceOf: [CGWindowID: Int]) -> WindowInfo? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, let space = spaceOf[wid] else { return nil }
        // Safari's full-screen video is an AXDialog, so a full-screen Space's own window counts whatever its subrole
        guard (copyAttribute(element, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
                || spaces.contains(where: { $0.window == wid }),
              (copyAttribute(element, kAXMinimizedAttribute) as? Bool) != true else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        if let v = copyAttribute(element, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &origin) }
        if let v = copyAttribute(element, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }

        return WindowInfo(
            id: wid,
            title: copyAttribute(element, kAXTitleAttribute) as? String ?? "",
            appName: app.localizedName ?? "App",
            pid: app.processIdentifier,
            origin: origin,
            size: size,
            element: element,
            space: space
        )
    }

    // kAXWindowsAttribute only lists windows on the current Space, so windows on other Spaces
    // (native full screen included) are found the way AltTab does it: probe the app's AX element
    // ids through a remote token. Only windows the window server lists on some Space are probed,
    // and results are cached per id.
    private func otherSpaceWindows(apps: [NSRunningApplication], spaceOf: [CGWindowID: Int], known: Set<CGWindowID>) -> [WindowInfo] {
        let appsByPid = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var candidates: [CGWindowID: pid_t] = [:]
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let wid = w[kCGWindowNumber as String] as? CGWindowID, !known.contains(wid),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, appsByPid[pid] != nil,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 100, (b["Height"] ?? 0) >= 100,
                  spaceOf[wid] != nil else { continue }
            candidates[wid] = pid
        }

        remoteElements = remoteElements.filter { candidates[$0.key] != nil }
        let unprobed = Set(candidates.filter { remoteElements[$0.key] == nil && !remoteMisses.contains($0.key) }.values)
        for pid in unprobed {
            for element in SkyLight.windowElements(pid: pid) {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(element, &wid) == .success, candidates[wid] != nil {
                    remoteElements[wid] = element
                }
            }
            for (wid, owner) in candidates where owner == pid && remoteElements[wid] == nil {
                remoteMisses.insert(wid)
            }
        }

        return remoteElements.compactMap { wid, element in
            windowInfo(element: element, app: appsByPid[candidates[wid]!]!, spaceOf: spaceOf)
        }
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    // MARK: - App Observers

    private func observeApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard appObservers[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success,
              let obs = observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let notifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for note in notifications {
            AXObserverAddNotification(obs, appElement, note, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        appObservers[pid] = obs
    }

    private func unobserveApp(pid: pid_t) {
        guard let obs = appObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    private func tearDownObservers() {
        for (_, obs) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        appObservers.removeAll()
    }

    fileprivate func handleAXNotification(element: AXUIElement, notification: CFString) {
        if notification == (kAXFocusedWindowChangedNotification as CFString) {
            var winElement = element
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) != .success ||
               (subroleRef as? String) != (kAXStandardWindowSubrole as String) {
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success {
                    winElement = winRef as! AXUIElement
                }
            }
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(winElement, &wid) == .success && wid != 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.windowServerDidFocusWindow(windowID: wid)
                }
            }
        } else {
            scheduleSync()
        }
    }

    /// One desk per Space: user desktops are numbered like Mission Control does, a full-screen
    /// Space is named after its app. Windows are listed front to back.
    public func spaceDesks() -> [SpaceDesk] {
        var desktop = 0
        return spaces.map { space in
            let wins = (spaceWindows[space.id] ?? []).filter { knownWindows[$0] != nil }
            let name: String
            if space.fullscreen {
                name = wins.first.flatMap { knownWindows[$0]?.appName } ?? "Full Screen"
            } else {
                desktop += 1
                name = "Desktop \(desktop)"
            }
            return SpaceDesk(id: "s\(space.id)", name: name, wins: wins)
        }
    }

    /// True when going to the window makes macOS slide to another Space
    public func isOnOtherSpace(_ wid: CGWindowID) -> Bool {
        guard let current = SkyLight.currentSpace(),
              let space = spaceWindows.first(where: { $0.value.contains(wid) })?.key else { return false }
        return space != current
    }

    // MARK: - Adding a desktop

    // macOS has no public API for desktops. Mission Control (drawn by WindowManager since macOS 27) exposes
    // its "Add Desktop" button to Accessibility, so open it, press that and close it again
    public static func addDesktop(completion: @escaping () -> Void) {
        missionControl(press: "Add Desktop", action: kAXPressAction, completion: completion)
    }

    /// `name` as Mission Control shows it, "Desktop 3"
    public static func removeDesktop(named name: String, completion: @escaping () -> Void) {
        missionControl(press: "Exit To \(name)", action: "AXRemoveDesktop", completion: completion)
    }

    /// Mission Control has no action for reordering, so the thumbnail is dragged along its top bar with real
    /// pointer events (events posted to WindowManager alone are ignored), under the opaque canvas. The pointer
    /// is detached from the mouse meanwhile, so moving the mouse cannot spoil the drag, and warped back home
    /// after every posted event, so the cursor Mission Control insists on showing never visibly leaves
    public static func moveDesktop(from: Int, to: Int, completion: @escaping () -> Void) {
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
            return completion()
        }
        let pid = manager.processIdentifier
        let home = CGEvent(source: nil)?.location ?? .zero
        CGAssociateMouseAndMouseCursorPosition(0)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        DispatchQueue.global(qos: .userInitiated).async {
            dragThumbnail(pid: pid, from: from, to: to, home: home)
            for _ in 0..<2 where missionControlIsOpen(pid) {
                escape()
                usleep(300_000)
            }
            CGWarpMouseCursorPosition(home)
            CGAssociateMouseAndMouseCursorPosition(1)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func dragThumbnail(pid: pid_t, from: Int, to: Int, home: CGPoint) {
        var buttons: [CGRect] = []
        for _ in 0..<40 {
            buttons = desktopButtons(pid)
            if buttons.count > max(from, to) { break }
            usleep(50_000)
        }
        guard buttons.count > max(from, to) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        // No deltas: with the pointer detached, the visible cursor would be pushed along by them
        func post(_ type: CGEventType, _ p: CGPoint) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
            CGWarpMouseCursorPosition(home)
        }
        // The bar only shows thumbnails, and lays them out where they can be grabbed, while the pointer is over
        // it. With the cursor warped home after each event the bar collapses again unless moves keep coming
        for i in 0...50 { post(.mouseMoved, CGPoint(x: buttons[from].minX, y: 4 + Double(min(i, 10)) * 6)); usleep(16_000) }
        buttons = desktopButtons(pid)
        guard buttons.count > max(from, to) else { return }
        // WindowManager reports each thumbnail's centre as its position. One dropped on the target's centre
        // stays put when moving right; it has to pass it
        let a = buttons[from].origin
        let b = CGPoint(x: buttons[to].minX + (to > from ? 0.45 : -0.1) * buttons[to].width, y: buttons[to].minY)
        post(.leftMouseDown, a)
        usleep(300_000)
        let steps = 60
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + 20 * sin(t * .pi)))
            usleep(16_000)
        }
        usleep(600_000)
        post(.leftMouseUp, b)
        usleep(400_000)
    }

    /// The "Exit To …" thumbnails in Mission Control's top bar, left to right, one per Space
    private static func desktopButtons(_ pid: pid_t) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &value) == .success,
               (value as? String)?.hasPrefix("Exit To ") == true {
                var pos: CFTypeRef?, size: CFTypeRef?
                var p = CGPoint.zero, s = CGSize.zero
                if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
                   AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success {
                    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
                    AXValueGetValue(size as! AXValue, .cgSize, &s)
                    found.append(CGRect(origin: p, size: s))
                }
                return
            }
            guard depth < 6, AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { return }
            children.forEach { walk($0, depth + 1) }
        }
        walk(AXUIElementCreateApplication(pid), 0)
        return found.sorted { $0.minX < $1.minX }
    }

    private static func missionControl(press description: String, action: String, completion: @escaping () -> Void) {
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
            return completion()
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        var tries = 0
        func press() {
            tries += 1
            guard let button = element(in: AXUIElementCreateApplication(manager.processIdentifier), description: description) else {
                if tries < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: press) } else { completion() }
                return
            }
            AXUIElementPerformAction(button, action as CFString)
            // Escape right after removing a desktop is sometimes swallowed by the removal animation, and removing
            // the current desktop closes Mission Control by itself. Only send it while Mission Control is still up,
            // or it would reach the canvas and close it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if missionControlIsOpen(manager.processIdentifier) { escape() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if missionControlIsOpen(manager.processIdentifier) { escape() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: completion)
                }
            }
        }
        press()
    }

    private static func escape() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private static func missionControlIsOpen(_ pid: pid_t) -> Bool {
        element(in: AXUIElementCreateApplication(pid), description: "Add Desktop") != nil
    }

    private static func element(in root: AXUIElement, description: String, depth: Int = 0) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXDescriptionAttribute as CFString, &value) == .success, value as? String == description {
            return root
        }
        guard depth < 5, AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children.lazy.compactMap { element(in: $0, description: description, depth: depth + 1) }.first
    }

    // A Space is entered by focusing a window on it. An empty desktop has none, so a transparent window of
    // our own is parked there and brought to the front, which makes macOS slide over to it
    private static let spaceProbe: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        return window
    }()

    public static func switchToSpace(_ space: Int) {
        let probe = spaceProbe, wid = CGWindowID(probe.windowNumber)
        probe.orderFrontRegardless()
        SkyLight.moveWindows([wid], to: space)
        SkyLight.bringToFront(pid: getpid(), windowID: wid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { probe.orderOut(nil) }
    }

    /// Normal-level window ids, frontmost first
    public static func frontToBack() -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { ($0[kCGWindowLayer as String] as? Int) == 0 ? $0[kCGWindowNumber as String] as? CGWindowID : nil }
    }

    // MARK: - Window Manipulation

    public func windowInfo(for wid: CGWindowID) -> WindowInfo? {
        knownWindows[wid]
    }

    public func raiseWindow(_ wid: CGWindowID) {
        guard let element = knownWindows[wid]?.element else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    // Bringing the window's process to the front by window id also switches to the window's Space,
    // which activate() alone does not do when the app has windows on several Spaces
    public func makeWindowMainAndActivate(_ wid: CGWindowID) {
        guard let info = knownWindows[wid] else { return }
        SkyLight.bringToFront(pid: info.pid, windowID: wid)
        AXUIElementPerformAction(info.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(info.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    public func closeWindow(wid: CGWindowID) {
        guard let element = knownWindows[wid]?.element else { return }
        var closeButtonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success {
            let button = closeButtonRef as! AXUIElement
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    public func minimizeWindow(wid: CGWindowID) {
        guard let element = knownWindows[wid]?.element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let server = Unmanaged<WindowServer>.fromOpaque(refcon).takeUnretainedValue()
    server.handleAXNotification(element: element, notification: notification)
}
