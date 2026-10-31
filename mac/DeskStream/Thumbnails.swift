import Cocoa
import ScreenCaptureKit

public protocol ThumbnailServiceDelegate: AnyObject {
    func thumbnailDidUpdate(windowID: CGWindowID, version: Int)
}

public final class ThumbnailService {
    public weak var delegate: ThumbnailServiceDelegate?

    private var cache: [CGWindowID: (data: Data, version: Int)] = [:]
    private var inFlight = Set<CGWindowID>()
    private let queue = DispatchQueue(label: "com.guziyang.deskstream.thumbnails")

    public init() {}

    public func thumbnailData(for windowID: CGWindowID) -> Data? {
        queue.sync {
            cache[windowID]?.data
        }
    }

    public func version(for windowID: CGWindowID) -> Int? {
        queue.sync {
            cache[windowID]?.version
        }
    }

    private func tryBeginCapture(windowID: CGWindowID) -> Bool {
        queue.sync {
            if inFlight.contains(windowID) {
                return false
            }
            inFlight.insert(windowID)
            return true
        }
    }

    private func endCapture(windowID: CGWindowID) {
        queue.sync {
            _ = inFlight.remove(windowID)
        }
    }

    private func recordThumbnail(windowID: CGWindowID, data: Data) -> Int {
        queue.sync {
            let nextVersion = (cache[windowID]?.version ?? 0) + 1
            cache[windowID] = (data: data, version: nextVersion)
            return nextVersion
        }
    }

    public func capture(windowIDs: [CGWindowID]) {
        guard !windowIDs.isEmpty else { return }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let scMap = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

                for wid in windowIDs {
                    guard let scWin = scMap[wid] else { continue }
                    guard self.tryBeginCapture(windowID: wid) else { continue }

                    Task { [weak self] in
                        guard let self = self else { return }
                        defer {
                            self.endCapture(windowID: wid)
                        }

                        do {
                            let filter = SCContentFilter(desktopIndependentWindow: scWin)
                            let config = SCStreamConfiguration()
                            let w = CGFloat(scWin.frame.width)
                            let h = CGFloat(scWin.frame.height)
                            let maxDim = max(w, h)
                            // Up to Retina pixels, capped at 2048 px: big canvas windows still look sharp
                            if maxDim * 2 > 2048 {
                                let scale = 2048.0 / maxDim
                                config.width = max(1, Int(w * scale))
                                config.height = max(1, Int(h * scale))
                            } else {
                                config.width = max(1, Int(w * 2))
                                config.height = max(1, Int(h * 2))
                            }
                            config.showsCursor = false

                            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                            let rep = NSBitmapImageRep(cgImage: cgImage)
                            if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                                let nextVersion = self.recordThumbnail(windowID: wid, data: jpegData)
                                await MainActor.run { [weak self] in
                                    self?.delegate?.thumbnailDidUpdate(windowID: wid, version: nextVersion)
                                }
                            }
                        } catch {
                            // A failed capture keeps the previous image
                        }
                    }
                }
            } catch {
                // ScreenCaptureKit access denied or shareable content failure
            }
        }
    }

    // MARK: - Wallpaper

    public private(set) var wallpaper: (data: Data, version: Int)?

    /// NSWorkspace.desktopImageURL still names the old default picture after the wallpaper is changed in
    /// System Settings, so take the picture from the wallpaper window WindowManager draws for the current Space
    /// The JPEG of a full Retina screen takes ~40 ms to encode, so it is made off the main thread
    public func captureWallpaper(completion: @escaping @MainActor (Int) -> Void) {
        Task.detached { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let scWin = content.windows.first(where: {
                      $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager" && $0.title == "Wallpaper"
                  }) else { return }
            let config = SCStreamConfiguration()
            config.width = Int(scWin.frame.width * 2)
            config.height = Int(scWin.frame.height * 2)
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWin), configuration: config),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            await MainActor.run { [weak self] in
                guard let self, data != self.wallpaper?.data else { return }
                let version = (self.wallpaper?.version ?? 0) + 1
                self.wallpaper = (data, version)
                completion(version)
            }
        }
    }
}
