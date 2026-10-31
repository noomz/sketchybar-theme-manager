import AppKit

final class Probe: NSObject, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 160, y: 140, width: 640, height: 400),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
    var finished = false

    func sample(_ phase: String) {
        let output: [String: Any] = [
            "phase": phase,
            "menuVisible": NSMenu.menuBarVisible(),
            "fullScreen": window.styleMask.contains(.fullScreen),
            "presentationOptions": NSApp.currentSystemPresentationOptions.rawValue,
            "windowFrame": NSStringFromRect(window.frame),
            "screens": NSScreen.screens.map { ["frame": NSStringFromRect($0.frame),
                                               "visibleFrame": NSStringFromRect($0.visibleFrame)] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    func start() {
        NSApp.setActivationPolicy(.regular)
        window.title = "STM menu-bar feasibility probe"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
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
            self.finished = true
            NSApp.terminate(nil)
        }
    }
}

let application = NSApplication.shared
let probe = Probe()
probe.start()
application.run()
