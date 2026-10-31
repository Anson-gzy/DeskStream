import Foundation
import CoreGraphics

// director < script — one command per line, prints "t name" marks (seconds since start) to stdout
// wait s | move x y dur | click | down | up | drag x y dur | pan dx dur | key hotkey | mark name
let t0 = Date()
var pos = CGEvent(source: nil)!.location
var held = false

func now() -> Double { Date().timeIntervalSince(t0) }
func ease(_ k: Double) -> Double { 0.5 - 0.5 * cos(.pi * k) }
func sleepS(_ s: Double) { if s > 0 { usleep(UInt32(s * 1_000_000)) } }

func mouse(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.flags = []
    e.post(tap: .cghidEventTap)
}

func glide(to p: CGPoint, _ dur: Double) {
    let a = pos, n = max(1, Int(dur * 120))
    for i in 1...n {
        let k = ease(Double(i) / Double(n))
        let q = CGPoint(x: a.x + (p.x - a.x) * k, y: a.y + (p.y - a.y) * k)
        mouse(held ? .leftMouseDragged : .mouseMoved, q)
        pos = q
        sleepS(1.0 / 120)
    }
}

func wheel(_ dx: Double, phase: Int64, momentum: Int64) {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx.rounded()), wheel3: 0)!
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.post(tap: .cghidEventTap)
}

// A two-finger pan: a bell of deltas while the fingers move, then a decaying momentum tail
func pan(_ total: Double, _ dur: Double) {
    let n = max(2, Int(dur * 120))
    var sent = 0.0
    for i in 0..<n {
        let k = Double(i + 1) / Double(n)
        let d = total * ease(k) - sent
        sent += d
        wheel(d, phase: i == 0 ? 1 : 2, momentum: 0)
        sleepS(1.0 / 120)
    }
    wheel(0, phase: 4, momentum: 0)
    var v = total / Double(n) * 1.6
    var first = true
    while abs(v) > 0.5 {
        wheel(v, phase: 0, momentum: first ? 1 : 2)
        first = false
        v *= 0.95
        sleepS(1.0 / 120)
    }
    wheel(0, phase: 0, momentum: 3)
}

func hotkey() {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: down)!
        e.flags = [.maskControl, .maskAlternate]
        if !down { e.flags = [] }
        e.post(tap: .cghidEventTap)
        sleepS(0.03)
    }
    // The key-up alone leaves ⌃⌥ latched in the session flags, and the next click becomes a right click
    let clear = CGEvent(source: src)!
    clear.type = .flagsChanged
    clear.flags = []
    clear.post(tap: .cghidEventTap)
}

while let line = readLine() {
    let w = line.split(separator: " ").map(String.init)
    guard let cmd = w.first, !cmd.hasPrefix("#") else { continue }
    let n = w.dropFirst().compactMap(Double.init)
    switch cmd {
    case "wait": sleepS(n[0])
    case "move", "drag": glide(to: CGPoint(x: n[0], y: n[1]), n[2])
    case "down": mouse(.leftMouseDown, pos); held = true
    case "up": mouse(.leftMouseUp, pos); held = false
    case "click": mouse(.leftMouseDown, pos); sleepS(0.07); mouse(.leftMouseUp, pos)
    case "pan": pan(n[0], n[1])
    case "key": hotkey()
    case "mark": print(String(format: "%.3f %@", now(), w[1])); fflush(stdout)
    default: FileHandle.standardError.write("? \(line)\n".data(using: .utf8)!)
    }
}
