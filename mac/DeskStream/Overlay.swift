import AppKit
import WebKit

public protocol OverlayDelegate: AnyObject {
    func overlayDidResignKey()
}

public final class OverlayPanel: NSPanel {
    weak var overlayDelegate: OverlayDelegate?

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    override public func resignKey() {
        super.resignKey()
        overlayDelegate?.overlayDidResignKey()
    }
}

public final class OverlayController: NSObject, OverlayDelegate {
    public private(set) var panel: OverlayPanel!
    public private(set) var webView: WKWebView!
    private let space = SkyLight.overlaySpace(level: 1)
    public weak var controller: Controller?

    public init(schemeHandler: WKURLSchemeHandler, scriptMessageHandler: WKScriptMessageHandler) {
        super.init()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "desk")
        config.userContentController.add(scriptMessageHandler, name: "desk")
        Self.allowFullFrameRate(config.preferences)

        let screenFrame = NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        panel = OverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        // Level above normal windows (0) and the Dock (20)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.overlayDelegate = self

        webView = WKWebView(frame: NSRect(origin: .zero, size: screenFrame.size), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .black
        webView.setValue(true, forKey: "drawsBackground")

        panel.contentView = webView

        // Load the canvas web page
        if let url = URL(string: "desk://app/index.html") {
            webView.load(URLRequest(url: url))
        }

        // The page's wheel events carry no gesture phase, and the edge bounce needs to know when the fingers
        // rest, lift, and when momentum starts and ends; send it only on those transitions
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.panel, let phase = Self.wheelPhase(event) {
                self.webView.evaluateJavaScript("window.deskStream && window.deskStream.wheel('\(phase)')")
            }
            return event
        }
    }

    private static func wheelPhase(_ event: NSEvent) -> String? {
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) { return "touch" }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return "release" }
        if event.momentumPhase.contains(.began) { return "momentum" }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { return "still" }
        return nil
    }

    // WebKit paces pages at 60 fps even on a 120 Hz screen unless this internal feature is off
    private static func allowFullFrameRate(_ preferences: WKPreferences) {
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setSel = NSSelectorFromString("_setEnabled:forFeature:")
        guard let features = (WKPreferences.self as AnyObject).perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject],
              let feature = features.first(where: { $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled" }),
              let method = class_getInstanceMethod(WKPreferences.self, setSel) else { return }
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(preferences, setSel, false, feature)
    }

    // True from show() until hide() starts the fade-out, so a hotkey during the fade reopens it
    public private(set) var isVisible = false

    public func show(activeWindowID: CGWindowID?) {
        guard !isVisible else { return }
        isVisible = true
        stopWaiting()

        // Main screen's full frame including menu bar
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrame(screen.frame, display: true)
        }

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        SkyLight.addWindow(CGWindowID(panel.windowNumber), to: space)
        panel.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        controller?.overlayDidShow(activeWindowID: activeWindowID)
    }

    public func hide() {
        guard isVisible else { return }
        beginHide()
        // Hand keyboard focus back to the app that was in front; going to a window activates its app itself
        NSApp.deactivate()
        fadeOut(duration: 0.25)
    }

    public enum Wait { case flight, spaceSwitch }
    private var waits: Set<Wait> = []
    private var hideID = 0
    private var spaceObserver: NSObjectProtocol?
    private var cutOnHide = false

    /// The opaque canvas stays up until the pictures flying back have landed on the real windows and the
    /// system has finished sliding to their Space; fading earlier shows both at once, offset (1.5 s at most)
    public func hide(waitingFor conditions: Set<Wait>) {
        guard isVisible else { return }
        beginHide()
        waits = conditions
        cutOnHide = conditions.contains(.spaceSwitch)
        hideID += 1
        let id = hideID
        if conditions.contains(.spaceSwitch) {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.met(.spaceSwitch)
                }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.hideID == id else { return }
            self.met(nil)
        }
    }

    /// `nil` gives up on whatever is still awaited
    public func met(_ wait: Wait?) {
        guard !waits.isEmpty else { return }
        if let wait { waits.remove(wait) } else { waits.removeAll() }
        guard waits.isEmpty else { return }
        stopWaiting()
        // After a Space switch the new desktop stays black under the canvas until the canvas is gone,
        // so fading would pass through black; the canvas already shows that desktop, so cut instead
        if cutOnHide { panel.orderOut(nil) } else { fadeOut(duration: 0.12) }
    }

    private func stopWaiting() {
        waits.removeAll()
        hideID += 1
        if let token = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            spaceObserver = nil
        }
    }

    private func beginHide() {
        isVisible = false
        webView.evaluateJavaScript("window.deskStream && window.deskStream.close()")
    }

    private func fadeOut(duration: TimeInterval) {
        guard !isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
    }

    public func toggle(activeWindowID: CGWindowID?) {
        if isVisible {
            hide()
        } else {
            show(activeWindowID: activeWindowID)
        }
    }

    /// Set while Mission Control is briefly on screen for the canvas, so losing key does not close it
    public var holdOpen = false

    public func refocus() {
        guard isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func overlayDidResignKey() {
        guard isVisible, !holdOpen else { return }
        hide()
    }
}
