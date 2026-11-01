import Foundation
import CoreGraphics

struct DisplayOrigin: Codable, Equatable {
    let id: CGDirectDisplayID
    let x: Int32
    let y: Int32
}

struct Snapshot: Codable {
    let original: [DisplayOrigin]
    let moved: [DisplayOrigin]
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ result: CGError, _ operation: String) throws {
    guard result == .success else {
        throw ProbeError("\(operation) failed: \(result.rawValue)")
    }
}

func origins() throws -> [DisplayOrigin] {
    var count: UInt32 = 0
    try check(CGGetActiveDisplayList(0, nil, &count), "Count displays")
    guard count == 2 else { throw ProbeError("Expected exactly two guest displays") }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    try check(CGGetActiveDisplayList(count, &ids, &count), "List displays")
    return ids.prefix(Int(count)).sorted().map { id in
        let frame = CGDisplayBounds(id)
        return DisplayOrigin(id: id, x: Int32(frame.minX), y: Int32(frame.minY))
    }
}

func configure(_ target: [DisplayOrigin]) throws {
    var configuration: CGDisplayConfigRef?
    try check(CGBeginDisplayConfiguration(&configuration), "Begin configuration")
    guard let configuration else { throw ProbeError("Missing display configuration") }
    do {
        for display in target {
            try check(CGConfigureDisplayOrigin(configuration, display.id, display.x, display.y), "Set origin")
        }
    } catch {
        CGCancelDisplayConfiguration(configuration)
        throw error
    }
    try check(CGCompleteDisplayConfiguration(configuration, .forSession), "Apply session configuration")
    Thread.sleep(forTimeInterval: 2)
    guard try origins() == target else { throw ProbeError("Effective display origins differ from requested origins") }
}

func emit(_ name: String, _ value: [DisplayOrigin]) throws {
    let data = try JSONEncoder().encode(value)
    print("\(name)=\(String(decoding: data, as: UTF8.self))")
}

// Check the machine before reading a snapshot or starting a display transaction.
do {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    process.arguments = ["-n", "hw.model"]
    process.standardOutput = pipe
    try process.run()
    let model = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0, model.hasPrefix("VirtualMac") else {
        throw ProbeError("Refusing display rearrangement outside VirtualMac")
    }
    guard CommandLine.arguments.count == 3 else {
        throw ProbeError("Usage: rearrange snapshot|move|restore <snapshot.json>")
    }
    let action = CommandLine.arguments[1]
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    if action == "snapshot" {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeError("Refusing to replace an existing topology snapshot")
        }
        let original = try origins()
        let primaryID = CGMainDisplayID()
        guard let primary = original.first(where: { $0.id == primaryID }),
              let secondary = original.first(where: { $0.id != primaryID }) else {
            throw ProbeError("Cannot identify primary and secondary displays")
        }
        let moved = original.map { display in
            display.id == secondary.id
                ? DisplayOrigin(id: display.id, x: primary.x - Int32(CGDisplayBounds(display.id).width), y: primary.y + 80)
                : display
        }
        guard moved != original else { throw ProbeError("Probe target already matches current layout") }
        try JSONEncoder().encode(Snapshot(original: original, moved: moved)).write(to: url, options: .atomic)
        try emit("snapshot_origins", original)
        try emit("planned_origins", moved)
    } else if action == "move" || action == "restore" {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        let current = try origins()
        guard current == snapshot.original || current == snapshot.moved else {
            throw ProbeError("Topology changed outside probe; retain snapshot and inspect before recovery")
        }
        let target = action == "move" ? snapshot.moved : snapshot.original
        if current != target { try configure(target) }
        try emit("effective_origins", try origins())
        print("\(action)_verified=true")
    } else {
        throw ProbeError("Unknown action: \(action)")
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
