import AppKit
import CoreGraphics

let screens = NSScreen.screens.map { screen -> [String: Any] in
    var row: [String: Any] = [
        "displayID": screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? -1,
        "frame": NSStringFromRect(screen.frame),
        "visibleFrame": NSStringFromRect(screen.visibleFrame),
        "safeTop": screen.safeAreaInsets.top,
        "scale": screen.backingScaleFactor
    ]
    if let area = screen.auxiliaryTopRightArea {
        row["auxiliaryTopRightArea"] = NSStringFromRect(area)
    }
    return row
}
let options: CGWindowListOption = CommandLine.arguments.contains("--all") ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let relevantWindows = windows.filter { window in
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    return layer == 24 || layer == 25 || owner.lowercased() == "sketchybar"
}.map { window -> [String: Any] in
    ["owner": window[kCGWindowOwnerName as String] ?? "unknown",
     "layer": window[kCGWindowLayer as String] ?? -1,
     "onScreen": window[kCGWindowIsOnscreen as String] ?? false,
     "bounds": window[kCGWindowBounds as String] ?? [:]]
}
let output: [String: Any] = ["menuVisible": NSMenu.menuBarVisible(), "screens": screens, "windows": relevantWindows]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
