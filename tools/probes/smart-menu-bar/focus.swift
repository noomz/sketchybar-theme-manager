import AppKit

let check = Process()
let pipe = Pipe()
check.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
check.arguments = ["-n", "hw.model"]
check.standardOutput = pipe
try check.run()
let model = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
check.waitUntilExit()
guard check.terminationStatus == 0, model.hasPrefix("VirtualMac") else {
    fatalError("Refusing focus probe outside VirtualMac")
}
let previous = NSWorkspace.shared.frontmostApplication
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screens = NSScreen.screens
guard screens.count == 2 else { fatalError("Expected two guest displays") }
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "stm display focus probe"
window.isReleasedWhenClosed = false

func focus(_ index: Int, _ phase: String) {
    let frame = screens[index].frame
    window.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.midY - 90))
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    print("focus_phase=\(phase) window=\(NSStringFromRect(window.frame))")
    fflush(stdout)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focus(1, "secondary") }
DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { focus(0, "primary") }
DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
    window.close()
    let requested = previous?.activate(options: [.activateIgnoringOtherApps]) ?? false
    print("focus_restore_requested=\(requested)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let restored = previous != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == previous?.processIdentifier
        print("focus_restore_verified=\(restored)")
        fflush(stdout)
        app.terminate(nil)
    }
}
app.run()
