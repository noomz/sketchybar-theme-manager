import AppKit
import CoreGraphics

func query(_ name: String) throws -> Any {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sketchybar")
    process.arguments = ["--query", name]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "SketchyBarQuery", code: Int(process.terminationStatus))
    }
    return try JSONSerialization.jsonObject(with: data)
}

let machine = Process()
let machineOutput = Pipe()
machine.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
machine.arguments = ["-n", "hw.model"]
machine.standardOutput = machineOutput
try machine.run()
let model = String(decoding: machineOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
machine.waitUntilExit()
guard machine.terminationStatus == 0, model.hasPrefix("VirtualMac") else {
    fputs("Refusing fullscreen probe outside VirtualMac\n", stderr)
    exit(1)
}
let previous = NSWorkspace.shared.frontmostApplication
let application = NSApplication.shared
let requestedScreen = CommandLine.arguments.dropFirst().first
let targetScreen: NSScreen
if let requestedScreen {
    guard CommandLine.arguments.count == 2, NSScreen.screens.count == 2,
          requestedScreen == "primary" || requestedScreen == "secondary",
          let screen = NSScreen.screens.first(where: {
              let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
              return (id == CGMainDisplayID()) == (requestedScreen == "primary")
          }) else {
        fputs("Usage: bar-fullscreen [primary|secondary], with exactly two displays when specified\n", stderr)
        exit(1)
    }
    targetScreen = screen
} else {
    guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first else {
        fputs("Probe requires one guest display unless primary or secondary is specified\n", stderr)
        exit(1)
    }
    targetScreen = screen
}
guard let targetID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
    fputs("Missing target display ID\n", stderr)
    exit(1)
}

final class Probe: NSObject, NSWindowDelegate {
    let targetScreen: NSScreen
    let targetID: UInt32

    init(targetScreen: NSScreen, targetID: UInt32) {
        self.targetScreen = targetScreen
        self.targetID = targetID
        super.init()
    }

    let window = NSWindow(contentRect: NSRect(x: 160, y: 140, width: 640, height: 400),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
    var finished = false
    var initialBounds: NSDictionary?
    var initialSettings: NSDictionary?
    var initialVisibility: [String: Bool] = [:]

    func sample(_ phase: String) {
        do {
            let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] ?? []
            let relevant = windows.filter {
                let owner = $0[kCGWindowOwnerName as String] as? String ?? ""
                let layer = $0[kCGWindowLayer as String] as? Int ?? -1
                return owner.lowercased() == "sketchybar" || layer == 24 || layer == 25
            }.map { row -> [String: Any] in
                ["owner": row[kCGWindowOwnerName as String] ?? "unknown",
                 "layer": row[kCGWindowLayer as String] ?? -1,
                 "onScreen": row[kCGWindowIsOnscreen as String] ?? false,
                 "bounds": row[kCGWindowBounds as String] ?? [:]]
            }
            guard let bar = try query("bar") as? [String: Any],
                  let item = try query("stm.transitions") as? [String: Any],
                  let bounds = item["bounding_rects"] as? [String: [String: Any]],
                  !bounds.isEmpty else {
                throw NSError(domain: "MissingBarGeometry", code: 1)
            }
            let settings = NSDictionary(dictionary: bar.filter {
                ["topmost", "y_offset", "sticky", "show_in_fullscreen", "position", "display"].contains($0.key)
            })
            guard let displays = try query("displays") as? [[String: Any]] else {
                throw NSError(domain: "MissingDisplays", code: 1)
            }
            var visibility: [String: Bool] = [:]
            for display in displays {
                guard let id = display["DirectDisplayID"] as? UInt32,
                      let arrangement = display["arrangement-id"] as? Int else {
                    throw NSError(domain: "InvalidDisplayIdentity", code: 1)
                }
                let row = bounds["display-\(arrangement)"]
                var visible = false
                if let origin = row?["origin"] as? [Double], origin.count == 2,
                   let size = row?["size"] as? [Double], size.count == 2 {
                    let rect = CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
                    visible = CGDisplayBounds(id).intersects(rect)
                }
                visibility[String(id)] = visible
            }
            guard let intersects = visibility[String(targetID)] else {
                throw NSError(domain: "TargetDisplayMissing", code: 1)
            }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            if phase == "desktop-before" {
                initialBounds = NSDictionary(dictionary: bounds)
                initialSettings = settings
                initialVisibility = visibility
            }
            if phase == "fullscreen" {
                guard visibility.filter({ $0.key != String(targetID) }) == initialVisibility.filter({ $0.key != String(targetID) }) else {
                    throw NSError(domain: "OtherDisplayVisibilityChanged", code: 1)
                }
                guard isFullScreen,
                      window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == targetID,
                      intersects == (bar["show_in_fullscreen"] as? String == "on") else {
                    throw NSError(domain: "FullscreenPlacementMismatch", code: 1)
                }
            } else {
                guard !isFullScreen, intersects else {
                    throw NSError(domain: "DesktopPlacementMismatch", code: 1)
                }
            }
            guard settings == initialSettings else {
                throw NSError(domain: "BarSettingsChanged", code: 1)
            }
            if phase == "desktop-after", NSDictionary(dictionary: bounds) != initialBounds {
                throw NSError(domain: "DesktopBoundsNotRestored", code: 1)
            }
            let output: [String: Any] = [
                "phase": phase,
                "targetDisplayID": targetID,
                "visibilityByDisplayID": visibility,
                "windowFrame": NSStringFromRect(window.frame),
                "menuVisible": NSMenu.menuBarVisible(),
                "fullScreen": window.styleMask.contains(.fullScreen),
                "bar": bar,
                "item": item,
                "windows": relevant,
                "screens": NSScreen.screens.map {
                    ["frame": NSStringFromRect($0.frame),
                     "visibleFrame": NSStringFromRect($0.visibleFrame)]
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        } catch {
            fputs("sample_failed=\(error)\n", stderr)
            exit(1)
        }
    }

    func start() {
        NSApp.setActivationPolicy(.regular)
        window.isReleasedWhenClosed = false
        window.title = "STM temporary fullscreen bar probe"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.setFrameOrigin(NSPoint(x: targetScreen.frame.midX - 320, y: targetScreen.frame.midY - 200))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.sample("desktop-before")
            self.window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !self.finished {
                self.sample("timeout")
                exit(1)
            }
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.sample("fullscreen")
            self.window.toggleFullScreen(nil)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.sample("desktop-after")
            self.window.close()
            _ = previous?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let restored = NSWorkspace.shared.frontmostApplication?.processIdentifier == previous?.processIdentifier
                print("focus_restore_verified=\(restored)")
                fflush(stdout)
                self.finished = true
                exit(restored ? 0 : 1)
            }
        }
    }
}

let probe = Probe(targetScreen: targetScreen, targetID: targetID)
probe.start()
application.run()
