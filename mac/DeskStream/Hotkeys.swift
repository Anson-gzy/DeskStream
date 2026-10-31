import Carbon
import Foundation

public protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyToggleOverlay()
    func hotkeyNavigateRowUp()
    func hotkeyNavigateRowDown()
    func hotkeyNavigateDeskLeft()
    func hotkeyNavigateDeskRight()
}

public final class HotkeyManager {
    public weak var delegate: HotkeyManagerDelegate?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let signature: OSType = 0x44535452 // 'DSTR'

    public enum ActionID: UInt32 {
        case toggleOverlay = 1
        case rowUp = 2
        case rowDown = 3
        case deskLeft = 4
        case deskRight = 5
    }

    public init() {}

    deinit {
        unregisterAll()
    }

    public func registerHotkeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (handlerCallRef, eventRef, userData) -> OSStatus in
                guard let eventRef = eventRef, let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == 0x44535452 else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotKey(actionID: hotKeyID.id)
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )
        guard status == noErr else { return }

        let modifiers = UInt32(controlKey | optionKey)

        // ⌃⌥Space
        registerHotkey(id: .toggleOverlay, keyCode: UInt32(kVK_Space), modifiers: modifiers)
        // ⌃⌥↑
        registerHotkey(id: .rowUp, keyCode: UInt32(kVK_UpArrow), modifiers: modifiers)
        // ⌃⌥↓
        registerHotkey(id: .rowDown, keyCode: UInt32(kVK_DownArrow), modifiers: modifiers)
        // ⌃⌥←
        registerHotkey(id: .deskLeft, keyCode: UInt32(kVK_LeftArrow), modifiers: modifiers)
        // ⌃⌥→
        registerHotkey(id: .deskRight, keyCode: UInt32(kVK_RightArrow), modifiers: modifiers)
    }

    private func registerHotkey(id: ActionID, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id.rawValue)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if err == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        }
    }

    public func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
    }

    fileprivate func handleHotKey(actionID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let action = ActionID(rawValue: actionID) else { return }
            switch action {
            case .toggleOverlay:
                self.delegate?.hotkeyToggleOverlay()
            case .rowUp:
                self.delegate?.hotkeyNavigateRowUp()
            case .rowDown:
                self.delegate?.hotkeyNavigateRowDown()
            case .deskLeft:
                self.delegate?.hotkeyNavigateDeskLeft()
            case .deskRight:
                self.delegate?.hotkeyNavigateDeskRight()
            }
        }
    }
}
