import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func output(_ executable: String, _ arguments: [String]) -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    do { try process.run() } catch { fail("Cannot launch \(executable): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("Command failed: \(executable)") }
    return data
}

let model = String(decoding: output("/usr/sbin/sysctl", ["-n", "hw.model"]), as: UTF8.self)
guard model.hasPrefix("VirtualMac") else { fail("Refusing click probe outside VirtualMac") }
guard CGPreflightPostEventAccess() else { fail("Event posting permission unavailable; no permission request made") }
let data = output("/opt/homebrew/bin/sketchybar", ["--query", "stm.placement"])
guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rects = item["bounding_rects"] as? [String: [String: [Double]]],
      rects.count == 1,
      let rect = rects.values.first,
      let origin = rect["origin"], origin.count == 2,
      let size = rect["size"], size.count == 2,
      size[0] > 1, size[1] > 1 else { fail("Expected one visible probe item rectangle") }
let point = CGPoint(x: origin[0] + size[0] / 2, y: origin[1] + size[1] / 2)
let previous = CGEvent(source: nil)?.location
let source = CGEventSource(stateID: .hidSystemState)
guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
      let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { fail("Cannot create mouse events") }
move.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
down.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
up.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.2)
if let previous {
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: previous, mouseButton: .left)?.post(tap: .cghidEventTap)
}
print("click_posted x=\(point.x) y=\(point.y)")
