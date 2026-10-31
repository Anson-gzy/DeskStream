import AppKit

/// Four-finger swipe down opens the canvas. Read the way LaunchOS reads its pinch: a listen-only session
/// tap on gesture events (NSEventTypeGesture = 29), whose touches carry finger count and position. The
/// system's own four-finger gesture (App Exposé) still runs unless it is turned off in System Settings
public final class GestureMonitor {
    public var onSwipeDown: (() -> Void)?

    private var tap: CFMachPort?
    private var origin: CGPoint?
    private var fired = false

    // Normalized trackpad units: a deliberate swipe covers about a fifth of the pad
    private static let travel: CGFloat = 0.18

    public init() {}

    public func start() {
        let mask = CGEventMask(1) << 29
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, info in
            let monitor = Unmanaged<GestureMonitor>.fromOpaque(info!).takeUnretainedValue()
            monitor.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let ns = NSEvent(cgEvent: event) else { return }
        let touches = ns.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
        guard touches.count == 4 else {
            if touches.isEmpty { origin = nil; fired = false }
            return
        }
        let center = touches.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.normalizedPosition.x / 4, y: $0.y + $1.normalizedPosition.y / 4)
        }
        guard let origin else { self.origin = center; return }
        let dx = center.x - origin.x, dy = center.y - origin.y
        // Trackpad y grows upward
        guard !fired, -dy > Self.travel, -dy > abs(dx) * 2 else { return }
        fired = true
        onSwipeDown?()
    }
}
