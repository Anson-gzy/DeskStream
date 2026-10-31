import AppKit
import ApplicationServices

// Private window server and Accessibility calls (the same ones AltTab uses), looked up at runtime
// so the app links only public frameworks
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowsWithOptionsAndTags = @convention(c) (Int32, Int32, CFArray, Int32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    private typealias WindowQueryWindows = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias QueryResultCopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias IteratorAdvance = @convention(c) (CFTypeRef) -> Bool
    private typealias IteratorUInt32 = @convention(c) (CFTypeRef) -> UInt32
    private typealias IteratorUInt64 = @convention(c) (CFTypeRef) -> UInt64
    private typealias MoveWindowsToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> CGError
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> CGError
    private typealias WindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> CGError

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let hi = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)

    private static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as: T.Type) -> T {
        unsafeBitCast(dlsym(handle, name)!, to: T.self)
    }

    private static let connection = load(sky, "SLSMainConnectionID", as: MainConnectionID.self)()
    private static let createWithRemoteToken = load(hi, "_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self)
    private static let getProcessForPID = load(hi, "GetProcessForPID", as: GetProcessForPID.self)
    private static let setFrontProcess = load(sky, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self)
    private static let postEventRecord = load(sky, "SLPSPostEventRecordTo", as: PostEventRecordTo.self)
    private static let copyManagedDisplaySpaces = load(sky, "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copyWindowsWithTags = load(sky, "SLSCopyWindowsWithOptionsAndTags", as: CopyWindowsWithOptionsAndTags.self)
    private static let queryWindows = load(sky, "SLSWindowQueryWindows", as: WindowQueryWindows.self)
    private static let queryResultCopyWindows = load(sky, "SLSWindowQueryResultCopyWindows", as: QueryResultCopyWindows.self)
    private static let iteratorAdvance = load(sky, "SLSWindowIteratorAdvance", as: IteratorAdvance.self)
    private static let iteratorWindowID = load(sky, "SLSWindowIteratorGetWindowID", as: IteratorUInt32.self)
    private static let iteratorParentID = load(sky, "SLSWindowIteratorGetParentID", as: IteratorUInt32.self)
    private static let iteratorTags = load(sky, "SLSWindowIteratorGetTags", as: IteratorUInt64.self)
    private static let iteratorAttributes = load(sky, "SLSWindowIteratorGetAttributes", as: IteratorUInt64.self)
    private static let moveWindowsToManagedSpace = load(sky, "SLSMoveWindowsToManagedSpace", as: MoveWindowsToManagedSpace.self)
    private static let spaceCreate = load(sky, "SLSSpaceCreate", as: SpaceCreate.self)
    private static let spaceSetAbsoluteLevel = load(sky, "SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self)
    private static let showSpaces = load(sky, "SLSShowSpaces", as: ShowSpaces.self)
    private static let addWindowsToSpaces = load(sky, "SLSAddWindowsToSpaces", as: WindowsToSpaces.self)

    struct Space {
        let id: Int
        let fullscreen: Bool
        /// The window a full-screen Space was made for
        var window: CGWindowID? = nil
    }

    /// User desktops and full-screen Spaces of every display, in Mission Control order
    static func spaces() -> [Space] {
        let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        return displays.flatMap { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = space["ManagedSpaceID"] as? Int else { return nil }
                switch space["type"] as? Int {
                case 0: return Space(id: id, fullscreen: false)
                case 4: return Space(id: id, fullscreen: true, window: (space["fs_wid"] as? NSNumber)?.uint32Value)
                default: return nil
                }
            }
        }
    }

    /// The Space on screen of the main display
    static func currentSpace() -> Int? {
        let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        return (displays.first?["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
    }

    /// Real windows on the Space, front to back. SLSCopySpacesForWindows still reports a Space for
    /// windows that are ordered out (closed to the Dock, hidden apps), so membership comes from here
    static func windows(in space: Int) -> [CGWindowID] {
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        guard let ids = copyWindowsWithTags(connection, 0, [space] as CFArray, 0x2, &setTags, &clearTags)?.takeRetainedValue(),
              let query = queryWindows(connection, ids, Int32(CFArrayGetCount(ids)))?.takeRetainedValue(),
              let iterator = queryResultCopyWindows(query)?.takeRetainedValue() else { return [] }
        var result: [CGWindowID] = []
        while iteratorAdvance(iterator) {
            let tags = iteratorTags(iterator), attributes = iteratorAttributes(iterator)
            // yabai's test for a top-level document window rather than a panel, sheet or system surface
            guard iteratorParentID(iterator) == 0,
                  attributes & 0x2 != 0 || tags & 0x400000000000000 != 0,
                  tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x80000000 != 0) else { continue }
            result.append(iteratorWindowID(iterator))
        }
        return result
    }

    /// Works only on this process's own windows
    static func moveWindows(_ ids: [CGWindowID], to space: Int) {
        moveWindowsToManagedSpace(connection, ids.map { NSNumber(value: $0) } as CFArray, UInt64(space))
    }

    /// A Space of our own drawn above the user's desktops at `level`. Its windows stay put while macOS slides
    /// between desktops, where a window that joins all Spaces slides out with the old desktop
    static func overlaySpace(level: Int32) -> UInt64 {
        let space = spaceCreate(connection, 1, nil)
        _ = spaceSetAbsoluteLevel(connection, space, level)
        _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
        return space
    }

    static func addWindow(_ wid: CGWindowID, to space: UInt64) {
        _ = addWindowsToSpaces(connection, [NSNumber(value: wid)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    /// Every AXWindow element of the app, including windows on other Spaces
    static func windowElements(pid: pid_t) -> [AXUIElement] {
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { p in
            p.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            p.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            p.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self)
        }
        var elements: [AXUIElement] = []
        for id in UInt64(0)..<1000 {
            token.withUnsafeMutableBytes { $0.storeBytes(of: id, toByteOffset: 12, as: UInt64.self) }
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == kAXWindowRole {
                elements.append(element)
            }
        }
        return elements
    }

    /// Makes the window's process frontmost with that window key, switching Spaces if needed
    static func bringToFront(pid: pid_t, windowID: CGWindowID) {
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return }
        _ = setFrontProcess(&psn, windowID, 0x200) // kCPSUserGenerated

        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: &wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
    }
}
