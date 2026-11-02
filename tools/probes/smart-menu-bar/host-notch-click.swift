import AppKit
import ApplicationServices

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func command(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProbeFailure("Command failed (\(process.terminationStatus)): \(executable)")
    }
    return data
}

let sketchybar = "/opt/homebrew/bin/sketchybar"
func barCommand(_ arguments: [String]) throws {
    _ = try command(sketchybar, arguments)
}
func query(_ name: String) throws -> [String: Any] {
    let data = try command(sketchybar, ["--query", name])
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeFailure("Invalid query: \(name)")
    }
    return result
}
func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
func rectangle(_ name: String) throws -> CGRect {
    let item = try query(name)
    guard let bounds = item["bounding_rects"] as? [String: [String: [Double]]],
          bounds.count == 1, let row = bounds.values.first,
          let origin = row["origin"], origin.count == 2,
          let size = row["size"], size.count == 2, size.allSatisfy({ $0 > 1 }) else {
        throw ProbeFailure("Expected exactly one visible scratch-item rectangle")
    }
    return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
}
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

var result: Int32 = 1
do {
    guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--approve-model" else {
        throw ProbeFailure("Usage: host-notch-click --approve-model <explicitly-approved-model> <fresh-snapshot-directory>")
    }
    let model = String(decoding: try command("/usr/sbin/sysctl", ["-n", "hw.model"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard model == CommandLine.arguments[2], !model.hasPrefix("VirtualMac") else {
        throw ProbeFailure("Machine does not match explicitly approved physical host")
    }
    guard CGPreflightPostEventAccess() else {
        throw ProbeFailure("Event posting permission unavailable; no permission request made")
    }
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
          let pointer = CGEvent(source: nil)?.location else {
        throw ProbeFailure("Cannot snapshot cursor or left mouse button is already held")
    }
    guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
          let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
          CGDisplayIsBuiltin(displayID) != 0,
          let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea,
          left.maxX < right.minX, screen.safeAreaInsets.top > 0 else {
        throw ProbeFailure("Probe requires one confirmed physically notched built-in display")
    }
    let frame = CGDisplayBounds(displayID)
    var clearance = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {
        if window[kCGWindowOwnerName as String] as? String == "Screenshot",
           let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(frame) {
            throw ProbeFailure("Screenshot overlay active; refusing item, offset, and pointer changes")
        }
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        guard layer == 24, owner == "MenuBarAgent" || owner == "Window Server",
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.minY == frame.minY, rect.width > frame.width / 2 else { continue }
        clearance = max(clearance, rect.maxY - frame.minY)
    }
    guard clearance > 0, clearance <= 100 else { throw ProbeFailure("Unusable measured menu clearance") }
    let original = try query("bar")
    guard original["position"] as? String == "top", original["hidden"] as? String == "off",
          original["drawing"] as? String == "on", let offset = original["y_offset"] as? Int else {
        throw ProbeFailure("Expected a visible top bar with integer y_offset")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let snapshot = directory.appendingPathComponent("snapshot.json")
    guard !FileManager.default.fileExists(atPath: snapshot.path) else {
        throw ProbeFailure("Refusing to overwrite an existing snapshot")
    }
    let name = "stm.notch_probe.\(ProcessInfo.processInfo.processIdentifier)"
    guard let items = original["items"] as? [String], !items.contains(name) else {
        throw ProbeFailure("Scratch name is already in use")
    }
    let marker = directory.appendingPathComponent("clicks.log")
    let settings = original.filter { ["position", "height", "y_offset", "topmost", "show_in_fullscreen", "hidden", "drawing"].contains($0.key) }
    let saved: [String: Any] = ["model": model, "scratchName": name, "bar": settings,
        "pointer": ["x": pointer.x, "y": pointer.y], "clearance": clearance,
        "auxiliaryLeft": NSStringFromRect(left), "auxiliaryRight": NSStringFromRect(right)]
    try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: snapshot, options: .atomic)
    try Data().write(to: marker, options: .atomic)
    var created = false
    var lastOffset = offset
    defer {
        do {
            if created { try barCommand(["--remove", name]) }
            let current = try query("bar")
            guard let currentOffset = current["y_offset"] as? Int else { throw ProbeFailure("Cannot read offset during cleanup") }
            if lastOffset != offset {
                guard currentOffset == lastOffset || currentOffset == offset else {
                    throw ProbeFailure("Offset changed externally; refusing to overwrite it. Retain snapshot.")
                }
                if currentOffset != offset { try barCommand(["--bar", "y_offset=\(offset)"]) }
            }
            let restored = try query("bar")
            guard restored["y_offset"] as? Int == offset,
                  let finalItems = restored["items"] as? [String], !finalItems.contains(name) else {
                throw ProbeFailure("Scratch removal or original offset restoration failed")
            }
            try emit(["cleanup_verified": true, "restored_y_offset": offset, "scratch_removed": true])
        } catch {
            fputs("cleanup_failed=\(error) snapshot=\(snapshot.path)\n", stderr)
            result = 1
        }
    }
    try emit(["snapshot": snapshot.path, "original_y_offset": offset, "measured_clearance": clearance])
    // Mark ownership before the add: a partial command failure still removes only this unique name.
    created = true
    try barCommand(["--add", "item", name, "right", "--set", name, "label=STM probe", "width=100",
                    "click_script=/usr/bin/printf 'click\\n' >> \(shellQuote(marker.path))"])
    Thread.sleep(forTimeInterval: 0.5)

    func click(_ phase: String, _ edge: String) throws {
        let rect = try rectangle(name)
        let y = edge == "top" ? rect.minY + 2 : (edge == "bottom" ? rect.maxY - 2 : rect.midY)
        let point = CGPoint(x: rect.midX, y: y)
        guard frame.contains(rect), point.y >= frame.minY + clearance,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            throw ProbeFailure("Refusing click outside confirmed clear scratch-item area")
        }
        // An unraised bar sits below app windows; a click that lands on another window proves nothing about the notch.
        // Keep desktop elements: an unraised bar's layer -20 window counts as one.
        let stack = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = stack.first { window in
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
        let frontOwner = front?[kCGWindowOwnerName as String] as? String ?? "no listed window"
        guard frontOwner == "sketchybar" else {
            throw ProbeFailure("Click point occluded by \(frontOwner); no click posted")
        }
        let before = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count
        let source = CGEventSource(stateID: .hidSystemState)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left),
              let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left) else {
            throw ProbeFailure("Cannot create complete click and cursor-restoration event sequence")
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)
        restore.post(tap: .cghidEventTap)
        let after = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count
        var currentPointer = CGEvent(source: nil)?.location
        for _ in 0..<10 {
            if let current = currentPointer, abs(current.x - pointer.x) <= 1, abs(current.y - pointer.y) <= 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
            currentPointer = CGEvent(source: nil)?.location
        }
        let restored = currentPointer.map { abs($0.x - pointer.x) <= 1 && abs($0.y - pointer.y) <= 1 } ?? false
        try emit(["phase": phase, "edge": edge, "item_rect": NSStringFromRect(rect),
                  "click": ["x": point.x, "y": point.y], "deliveries": after - before, "cursor_restored": restored,
                  "cursor": currentPointer.map { ["x": $0.x, "y": $0.y] } ?? [:]])
        guard restored else { throw ProbeFailure("Cursor restoration not verified") }
        guard after - before == 1 else { throw ProbeFailure("Scratch handler did not receive exactly one click") }
    }

    let initialRect = try rectangle(name)
    if initialRect.midY >= frame.minY + clearance {
        try click("current-offset", "center")
    }
    let extra = Int(ceil(max(0, frame.minY + clearance - initialRect.minY)))
    guard extra <= 100 else { throw ProbeFailure("Required offset adjustment exceeds probe bound") }
    if extra > 0 {
        let current = try query("bar")
        guard current["y_offset"] as? Int == offset else { throw ProbeFailure("Offset changed before probe adjustment") }
        lastOffset = offset + extra
        try barCommand(["--bar", "y_offset=\(lastOffset)"])
        Thread.sleep(forTimeInterval: 0.5)
    }
    try emit(["tested_y_offset": lastOffset, "extra_clearance": extra])
    for position in ["right", "left"] {
        try barCommand(["--set", name, "position=\(position)"])
        Thread.sleep(forTimeInterval: 0.3)
        for edge in ["top", "center", "bottom"] { try click(position, edge) }
    }
    result = 0
} catch {
    fputs("probe_failed=\(error)\n", stderr)
}
exit(result)
