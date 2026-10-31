import AppKit
import ApplicationServices
import CoreGraphics

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: Controller?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate is weak; without this Swift may free the delegate (and with it the
        // status item, hotkeys and window observers) right after launch
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status item menu: 'Show Canvas' (⌃⌥Space), 'Quit Desk Stream'
        setupStatusItem()

        // Prompt for Accessibility with AXIsProcessTrustedWithOptions
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOptions)

        // Prompt for Screen Recording with CGRequestScreenCaptureAccess
        CGRequestScreenCaptureAccess()

        // Initialize and start Controller
        let ctrl = Controller()
        self.controller = ctrl
        ctrl.start()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "DeskStream")
                ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DeskStream")
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Canvas", action: #selector(showCanvasClicked), keyEquivalent: " ")
        showItem.keyEquivalentModifierMask = [.control, .option]
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Desk Stream", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func showCanvasClicked() {
        controller?.toggleOverlay()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

}
