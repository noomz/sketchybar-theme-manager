import AppKit
import CoreGraphics

let screens = NSScreen.screens.map { screen -> [String: Any] in
    ["frame": NSStringFromRect(screen.frame),
     "visibleFrame": NSStringFromRect(screen.visibleFrame),
     "safeTop": screen.safeAreaInsets.top]
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let menuWindows = windows.filter { window in
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    return layer == 24 || layer == 25
}.map { window -> [String: Any] in
    ["owner": window[kCGWindowOwnerName as String] ?? "unknown",
     "layer": window[kCGWindowLayer as String] ?? -1,
     "bounds": window[kCGWindowBounds as String] ?? [:]]
}
let output: [String: Any] = ["menuVisible": NSMenu.menuBarVisible(), "screens": screens, "menuWindows": menuWindows]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
