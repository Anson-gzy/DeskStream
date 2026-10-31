import AppKit
import WebKit
import DeskCore

public final class BridgeService: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    public weak var controller: Controller?
    private var iconCache: [pid_t: Data] = [:]

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "desk" else {
            urlSchemeTask.didFailWithError(NSError(domain: "DeskStream", code: 400, userInfo: nil))
            return
        }

        let host = url.host ?? ""
        switch host {
        case "app":
            handleAppRequest(url: url, task: urlSchemeTask)
        case "thumb":
            handleThumbRequest(url: url, task: urlSchemeTask)
        case "icon":
            handleIconRequest(url: url, task: urlSchemeTask)
        case "wallpaper":
            handleWallpaperRequest(url: url, task: urlSchemeTask)
        default:
            send404(url: url, task: urlSchemeTask)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No-op
    }

    private func handleAppRequest(url: URL, task: WKURLSchemeTask) {
        var relPath = url.path
        if relPath.hasPrefix("/") {
            relPath.removeFirst()
        }
        if relPath.isEmpty {
            relPath = "index.html"
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            send404(url: url, task: task)
            return
        }
        let webDir = resourceURL.appendingPathComponent("web")
        let fileURL = webDir.appendingPathComponent(relPath)

        guard let data = try? Data(contentsOf: fileURL) else {
            send404(url: url, task: task)
            return
        }

        let ext = fileURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "html", "htm": mimeType = "text/html; charset=utf-8"
        case "js": mimeType = "application/javascript; charset=utf-8"
        case "css": mimeType = "text/css; charset=utf-8"
        case "json": mimeType = "application/json; charset=utf-8"
        case "png": mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "svg": mimeType = "image/svg+xml"
        case "ico": mimeType = "image/x-icon"
        default: mimeType = "application/octet-stream"
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func handleThumbRequest(url: URL, task: WKURLSchemeTask) {
        let widStr = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let wid = CGWindowID(widStr),
              let thumbData = controller?.thumbnailData(for: wid) else {
            send404(url: url, task: task)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/jpeg",
                "Content-Length": "\(thumbData.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        task.didReceive(response)
        task.didReceive(thumbData)
        task.didFinish()
    }

    private func handleWallpaperRequest(url: URL, task: WKURLSchemeTask) {
        guard let data = controller?.thumbnailService.wallpaper?.data else { return send404(url: url, task: task) }
        sendJPEG(data: data, url: url, task: task)
    }

    private func sendJPEG(data: Data, url: URL, task: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/jpeg",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func handleIconRequest(url: URL, task: WKURLSchemeTask) {
        let pidStr = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let pid = pid_t(pidStr) else {
            send404(url: url, task: task)
            return
        }

        if let cachedData = iconCache[pid] {
            sendPNG(data: cachedData, url: url, task: task)
            return
        }

        if let app = NSRunningApplication(processIdentifier: pid),
           let icon = app.icon {
            let size = NSSize(width: 64, height: 64)
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 64,
                pixelsHigh: 64,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) {
                NSGraphicsContext.saveGraphicsState()
                let ctx = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current = ctx
                icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                if let pngData = rep.representation(using: .png, properties: [:]) {
                    iconCache[pid] = pngData
                    sendPNG(data: pngData, url: url, task: task)
                    return
                }
            }
        }
        send404(url: url, task: task)
    }

    private func sendPNG(data: Data, url: URL, task: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func send404(url: URL, task: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Access-Control-Allow-Origin": "*"]
        )!
        task.didReceive(response)
        task.didFinish()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "desk",
              let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            controller?.bridgeDidReceiveReady()
        case "go":
            if let winNum = dict["win"] as? NSNumber {
                controller?.bridgeDidReceiveGo(windowID: CGWindowID(winNum.uint32Value))
            }
        case "landed":
            controller?.bridgeDidReceiveLanded()
        case "goDesk":
            if let desk = dict["desk"] as? String {
                controller?.bridgeDidReceiveGoDesk(desk)
            }
        case "removeDesk":
            if let desk = dict["desk"] as? String {
                controller?.bridgeDidReceiveRemoveDesk(desk)
            }
        case "moveDesk":
            if let desk = dict["desk"] as? String, let to = dict["to"] as? Int {
                controller?.bridgeDidReceiveMoveDesk(desk, to: to)
            }
        case "addDesk":
            controller?.bridgeDidReceiveAddDesk()
        case "dismiss":
            controller?.bridgeDidReceiveDismiss()
        case "layout":
            if let desksRaw = dict["desks"] as? [[String: Any]] {
                let desks = parseDesks(desksRaw)
                controller?.bridgeDidReceiveLayout(desks: desks)
            }
        case "close":
            if let winNum = dict["win"] as? NSNumber {
                controller?.bridgeDidReceiveClose(windowID: CGWindowID(winNum.uint32Value))
            }
        case "minimize":
            if let winNum = dict["win"] as? NSNumber {
                controller?.bridgeDidReceiveMinimize(windowID: CGWindowID(winNum.uint32Value))
            }
        case "zoom":
            if let winNum = dict["win"] as? NSNumber {
                controller?.bridgeDidReceiveGo(windowID: CGWindowID(winNum.uint32Value))
            }
        default:
            break
        }
    }

    private func parseDesks(_ raw: [[String: Any]]) -> [Desk] {
        var desks: [Desk] = []
        for deskDict in raw {
            let id = deskDict["id"] as? String ?? UUID().uuidString
            let name = deskDict["name"] as? String ?? "Desk"
            var rows: [DeskRow] = []
            if let rowsRaw = deskDict["rows"] as? [[String: Any]] {
                for rowDict in rowsRaw {
                    var wins: [CGWindowID] = []
                    if let winsRaw = rowDict["wins"] as? [NSNumber] {
                        wins = winsRaw.map { CGWindowID($0.uint32Value) }
                    }
                    var ratios: [Double] = []
                    if let ratiosRaw = rowDict["ratios"] as? [NSNumber] {
                        ratios = ratiosRaw.map { $0.doubleValue }
                    }
                    var row = DeskRow(wins: wins, ratios: ratios)
                    row.normalizeRatios()
                    rows.append(row)
                }
            }
            desks.append(Desk(id: id, name: name, rows: rows))
        }
        return desks
    }
}
