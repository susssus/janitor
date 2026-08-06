import AppKit
import Foundation

// Janitor floating sweep overlay — compiled to bin/janitor-sweep-hud.appbin
// CRITICAL: set panel.level = .screenSaver AFTER isFloatingPanel = true
// (floating panel resets level to .floating = 3, which sits under normal apps).

let phase = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sweeping"
let readyPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let logPath = ProcessInfo.processInfo.environment["JANITOR_HUD_LOG"]
    ?? (NSHomeDirectory() + "/Library/Logs/janitor/desktop-debug.log")

func hudLog(_ msg: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " [hud-swift] " + msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logPath),
       let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

final class Hud: NSObject, NSApplicationDelegate {
    let phase: String
    let readyPath: String
    var panel: NSPanel!
    var broom: NSTextField!
    var timer: Timer?
    let frames = ["🧹", "🧹 💨", "💨 🧹", "✨ 🧹", "🧹✨"]
    var idx = 0
    var ticks = 0

    init(phase: String, readyPath: String) {
        self.phase = phase
        self.readyPath = readyPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let w: CGFloat = 340
        let h: CGFloat = 240
        let rect = NSRect(
            x: screen.origin.x + (screen.width - w) / 2,
            y: screen.origin.y + (screen.height - h) / 2,
            width: w,
            height: h
        )

        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.hasShadow = true
        panel.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.08, alpha: 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // AFTER isFloatingPanel — that property resets level to .floating (3)
        panel.level = .screenSaver
        panel.title = "Janitor Sweep"

        func label(_ text: String, frame: NSRect, size: CGFloat) -> NSTextField {
            let t = NSTextField(frame: frame)
            t.stringValue = text
            t.isBezeled = false
            t.drawsBackground = false
            t.isEditable = false
            t.isSelectable = false
            t.alignment = .center
            t.font = NSFont.boldSystemFont(ofSize: size)
            t.textColor = .white
            return t
        }

        broom = label("🧹", frame: NSRect(x: 0, y: 90, width: w, height: 110), size: 84)
        let sub = label("\(phase)…", frame: NSRect(x: 12, y: 42, width: w - 24, height: 32), size: 22)
        let brand = label("Janitor", frame: NSRect(x: 12, y: 14, width: w - 24, height: 24), size: 14)
        panel.contentView?.addSubview(broom)
        panel.contentView?.addSubview(sub)
        panel.contentView?.addSubview(brand)

        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        hudLog("panel visible=\(panel.isVisible) level=\(panel.level.rawValue) frame=\(rect)")

        if !readyPath.isEmpty {
            try? "ready\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
            hudLog("ready file written: \(readyPath)")
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.idx = (self.idx + 1) % self.frames.count
            self.broom.stringValue = self.frames[self.idx]
            self.ticks += 1
            self.panel.level = .screenSaver
            self.panel.orderFrontRegardless()
            if self.ticks % 8 == 0 {
                hudLog("heartbeat ticks=\(self.ticks) level=\(self.panel.level.rawValue)")
            }
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

hudLog("launch phase=\(phase)")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Hud(phase: phase, readyPath: readyPath)
app.delegate = delegate
app.run()
