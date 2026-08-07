import AppKit
import Foundation

// Janitor multi-phase sweeper box.
// Session dir protocol:
// <dir>/cmd : bash appends lines; Swift polls and consumes
// <dir>/events : Swift appends user actions; bash polls
// <dir>/ready : written when UI is up
//
// Commands (bash → Swift):
// phase welcome|assessing|choose|sweeping|done
// subtitle <text>
// log <text>
// item <id>\t<title>\t<because>\t<tradeoff>\t<educate¶paras>
// items_end
// done_line <text>
// done_end
// quit
//
// Events (Swift → bash):
// start | start_deep | start_brave | start_stupid | cancel | sweep id1,id2,… | ok

let sessionDir: String = {
 let args = CommandLine.arguments
 if let i = args.firstIndex(of: "--session"), i + 1 < args.count {
 return args[i + 1]
 }
 // Legacy: phase + ready-file (broom-only)
 return ""
}()

let legacyPhase = CommandLine.arguments.count > 1 && !CommandLine.arguments[1].hasPrefix("--")
 ? CommandLine.arguments[1] : "Sweeping"
let legacyReady = CommandLine.arguments.count > 2 && sessionDir.isEmpty
 ? CommandLine.arguments[2] : ""

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

struct ChooseItem {
 let id: String
 let title: String
 let because: String
 let tradeoff: String
 let educate: String
}

/// Filled orange CTA. Always orange (not only when “default”), with a clear press darken.
/// Does not use Return-key default, so sibling clicks never pulse it scary-orange.
final class OrangePushButton: NSButton {
 private let fillNormal = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.08, alpha: 1)
 private let fillPressed = NSColor(calibratedRed: 0.72, green: 0.30, blue: 0.04, alpha: 1)
 private var pressed = false

 override init(frame frameRect: NSRect) {
  super.init(frame: frameRect)
  isBordered = false
  setButtonType(.momentaryChange)
 }

 required init?(coder: NSCoder) {
  fatalError("init(coder:) has not been implemented")
 }

 override func draw(_ dirtyRect: NSRect) {
  let inset: CGFloat = pressed ? 1.5 : 0
  let r = bounds.insetBy(dx: inset, dy: inset)
  let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
  (pressed ? fillPressed : fillNormal).setFill()
  path.fill()

  let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
  let attrs: [NSAttributedString.Key: Any] = [
   .font: font,
   .foregroundColor: NSColor.white,
  ]
  let text = title as NSString
  let size = text.size(withAttributes: attrs)
  let origin = NSPoint(
   x: (bounds.width - size.width) / 2,
   y: (bounds.height - size.height) / 2 - (pressed ? 0.5 : 0)
  )
  text.draw(at: origin, withAttributes: attrs)
 }

 override func mouseDown(with event: NSEvent) {
  pressed = true
  needsDisplay = true
  var keepTracking = true
  while keepTracking {
   guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
   let local = convert(next.locationInWindow, from: nil)
   let inside = bounds.contains(local)
   if pressed != inside {
    pressed = inside
    needsDisplay = true
   }
   if next.type == .leftMouseUp {
    keepTracking = false
    if inside {
     sendAction(action, to: target)
    }
   }
  }
  pressed = false
  needsDisplay = true
 }
}

final class Hud: NSObject, NSApplicationDelegate {
 var window: NSWindow!
 var contentRoot: NSView!

 // Shared chrome
 var broomLabel: NSTextField!
 var titleLabel: NSTextField!
 var subtitleLabel: NSTextField!

 // Phase containers
 var welcomeBox: NSView!
 var progressBox: NSView!
 var chooseBox: NSView!
 var doneBox: NSView!

 var logView: NSTextView!
 var logScroll: NSScrollView!

 var chooseScroll: NSScrollView!
 var chooseDoc: NSView!
 var chooseChecks: [NSButton] = []
 var chooseBooks: [NSButton] = []
 var chooseItems: [ChooseItem] = []
 var choosePrompt: NSTextField!
 var chooseBookHint: NSTextField!

 var doneText: NSTextView!
 var doneScroll: NSScrollView!

 var timer: Timer?
 var cmdTimer: Timer?
 let frames = ["(*^▽^*)", "(｀・ω・´)", "٩(ˊᗜˋ*)و", "(ノ°ο°)ノ", "(＾▽＾)"]
 var idx = 0
 var animate = false

 var cmdOffset: UInt64 = 0
 var bufferingItems = false
 var bufferingDone = false
 var pendingItems: [ChooseItem] = []
 var pendingDoneLines: [String] = []

 let darkBg = NSColor(calibratedWhite: 0.12, alpha: 1)
 let cardBg = NSColor(calibratedWhite: 0.16, alpha: 1)

 let winW: CGFloat = 620
 let winH: CGFloat = 560

 /// Welcome help tips keyed by NSButton.tag
 var welcomeHelpBodies: [(title: String, body: String)] = []

 func applicationDidFinishLaunching(_ notification: Notification) {
 let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
 let rect = NSRect(
 x: screen.origin.x + (screen.width - winW) / 2,
 y: screen.origin.y + (screen.height - winH) / 2,
 width: winW,
 height: winH
 )

 window = NSWindow(
 contentRect: rect,
 styleMask: [.titled, .closable],
 backing: .buffered,
 defer: false
 )
 window.title = "Janitor"
 window.isReleasedWhenClosed = false
 window.level = .floating
 window.backgroundColor = darkBg
 window.appearance = NSAppearance(named: .darkAqua)
 window.delegate = self

 contentRoot = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
 contentRoot.wantsLayer = true
 contentRoot.layer?.backgroundColor = darkBg.cgColor
 window.contentView = contentRoot

 buildChrome()
 buildWelcome()
 buildProgress()
 buildChoose()
 buildDone()

 window.makeKeyAndOrderFront(nil)
 NSApp.activate(ignoringOtherApps: true)

 if !sessionDir.isEmpty {
 FileManager.default.createFile(
 atPath: sessionDir + "/cmd", contents: Data(), attributes: nil
 )
 FileManager.default.createFile(
 atPath: sessionDir + "/events", contents: Data(), attributes: nil
 )
 try? "ready\n".write(
 toFile: sessionDir + "/ready", atomically: true, encoding: .utf8
 )
 hudLog("session ready dir=\(sessionDir)")
 showPhase("welcome")
 emit("ready")
 cmdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
 self?.pollCommands()
 }
 if let t = cmdTimer { RunLoop.main.add(t, forMode: .common) }
 } else {
 // Legacy broom-only mode
 showPhase("assessing")
 titleLabel.stringValue = legacyPhase
 subtitleLabel.stringValue = "underway…"
 animate = true
 if !legacyReady.isEmpty {
 try? "ready\n".write(toFile: legacyReady, atomically: true, encoding: .utf8)
 }
 }

 timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
 guard let self = self, self.animate else { return }
 self.idx = (self.idx + 1) % self.frames.count
 self.broomLabel.stringValue = self.frames[self.idx]
 }
 if let t = timer { RunLoop.main.add(t, forMode: .common) }
 }

 // MARK: - Build UI

 func label(_ text: String, frame: NSRect, size: CGFloat, bold: Bool = true) -> NSTextField {
 let t = NSTextField(frame: frame)
 t.stringValue = text
 t.isBezeled = false
 t.drawsBackground = false
 t.isEditable = false
 t.isSelectable = false
 t.alignment = .center
 t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
 t.textColor = .white
 return t
 }

 func makeButton(
 _ title: String,
 frame: NSRect,
 action: Selector,
 accent: Bool = false,
 isDefault: Bool = false
 ) -> NSButton {
 if accent {
  let b = OrangePushButton(frame: frame)
  b.title = title
  b.target = self
  b.action = action
  // No Return default: filled orange is the always-on cue; default would flash on siblings.
  return b
 }
 let b = NSButton(frame: frame)
 b.title = title
 b.bezelStyle = .rounded
 b.target = self
 b.action = action
 // Return-key only for lone primary actions (e.g. Done OK), never for choose/welcome CTAs.
 if isDefault {
  b.keyEquivalent = "\r"
 }
 return b
 }

 func makeHelpButton(frame: NSRect, tip: String, tag: Int) -> NSButton {
 let b = NSButton(frame: frame)
 b.title = "?"
 b.bezelStyle = .circular
 b.target = self
 b.action = #selector(onWelcomeHelp(_:))
 b.toolTip = tip
 b.tag = tag
 b.setButtonType(.momentaryPushIn)
 return b
 }

 func buildChrome() {
 broomLabel = label("(*^▽^*)", frame: NSRect(x: 0, y: winH - 100, width: winW, height: 70), size: 28)
 titleLabel = label("Janitor", frame: NSRect(x: 20, y: winH - 130, width: winW - 40, height: 28), size: 22)
 subtitleLabel = label(
 "", frame: NSRect(x: 20, y: winH - 154, width: winW - 40, height: 20), size: 13, bold: false
 )
 subtitleLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
 contentRoot.addSubview(broomLabel)
 contentRoot.addSubview(titleLabel)
 contentRoot.addSubview(subtitleLabel)
 }

 func buildWelcome() {
 welcomeBox = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - 170))
 let blurb = label(
 "Janitor clears caches to free disk space. It does not free RAM.\nQuit apps to free memory. Never Documents or Downloads.\nButtons below only assess. You pick what to clean next. Nothing deletes yet.",
 frame: NSRect(x: 28, y: 230, width: winW - 56, height: 62),
 size: 12,
 bold: false
 )
 blurb.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)

 let btnW: CGFloat = 280
 let btnX = (winW - btnW) / 2
 let helpX = btnX + btnW + 10
 let helpW: CGFloat = 28

 let start = makeButton(
 "Start sweep",
 frame: NSRect(x: btnX, y: 186, width: btnW, height: 36),
 action: #selector(onStart),
 accent: true
 )
 // No Return-key default on welcome: sibling buttons would pulse this one orange.
 let deep = makeButton(
 "Start deep sweep",
 frame: NSRect(x: btnX, y: 146, width: btnW, height: 32),
 action: #selector(onStartDeep)
 )

 let braveTip = """
 Wider disk sweep: browser & media caches (Chrome, Safari, Steam, Spotify, Discord, …).

 Still never touches Documents or Downloads.
 More buffering / slower first page loads possible after. That’s the tradeoff.
 Same as: janitor clean --brave
 """
 let stupidTip = """
 One notch past caches: sandboxed app container caches, Application Support Cache/Caches folders, and Docker prune.

 Includes everything Brave unlocks, plus those past-cache regenerables.
 Still never Documents or Downloads. Apps may feel colder; Docker may redownload layers.
 Same as: janitor clean --stupid
 """

 welcomeHelpBodies = [
 (
 title: "Brave sweep",
 body: braveTip
 ),
 (
 title: "Just stupid",
 body: stupidTip
 ),
 ]

 let brave = makeButton(
 "Brave sweep",
 frame: NSRect(x: btnX, y: 106, width: btnW, height: 32),
 action: #selector(onStartBrave)
 )
 let braveHelp = makeHelpButton(
 frame: NSRect(x: helpX, y: 108, width: helpW, height: 28),
 tip: braveTip,
 tag: 0
 )

 let stupid = makeButton(
 "Just stupid",
 frame: NSRect(x: btnX, y: 66, width: btnW, height: 32),
 action: #selector(onStartStupid)
 )
 let stupidHelp = makeHelpButton(
 frame: NSRect(x: helpX, y: 68, width: helpW, height: 28),
 tip: stupidTip,
 tag: 1
 )

 let cancel = makeButton(
 "Cancel",
 frame: NSRect(x: (winW - 120) / 2, y: 20, width: 120, height: 28),
 action: #selector(onCancel)
 )
 welcomeBox.addSubview(blurb)
 welcomeBox.addSubview(start)
 welcomeBox.addSubview(deep)
 welcomeBox.addSubview(brave)
 welcomeBox.addSubview(braveHelp)
 welcomeBox.addSubview(stupid)
 welcomeBox.addSubview(stupidHelp)
 welcomeBox.addSubview(cancel)
 contentRoot.addSubview(welcomeBox)
 welcomeBox.isHidden = true
 }

 func buildProgress() {
 progressBox = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - 170))

 logScroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: winW - 48, height: winH - 210))
 logScroll.hasVerticalScroller = true
 logScroll.hasHorizontalScroller = false
 logScroll.borderType = .bezelBorder
 logScroll.drawsBackground = true
 logScroll.backgroundColor = cardBg

 logView = NSTextView(frame: NSRect(x: 0, y: 0, width: winW - 64, height: winH - 210))
 logView.isEditable = false
 logView.isSelectable = true
 logView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
 logView.textColor = .white
 logView.backgroundColor = cardBg
 logView.string = ""
 logScroll.documentView = logView

 progressBox.addSubview(logScroll)
 contentRoot.addSubview(progressBox)
 progressBox.isHidden = true
 }

 func buildChoose() {
 chooseBox = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - 170))

 choosePrompt = label(
 "Check what to clean.",
 frame: NSRect(x: 24, y: winH - 202, width: winW - 220, height: 24),
 size: 12,
 bold: false
 )
 choosePrompt.alignment = .left
 choosePrompt.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)

 // Align 📖 with the book buttons in each hog row (right column of the list)
 let bookColX = winW - 84
 chooseBookHint = label(
 "📖 = educate me further",
 frame: NSRect(x: bookColX - 4, y: winH - 202, width: winW - bookColX - 20, height: 24),
 size: 12,
 bold: false
 )
 chooseBookHint.alignment = .left
 chooseBookHint.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)

 chooseScroll = NSScrollView(frame: NSRect(x: 24, y: 70, width: winW - 48, height: winH - 280))
 chooseScroll.hasVerticalScroller = true
 chooseScroll.borderType = .bezelBorder
 chooseScroll.drawsBackground = true
 chooseScroll.backgroundColor = cardBg
 chooseDoc = NSView(frame: .zero)
 chooseScroll.documentView = chooseDoc

 let checkAll = makeButton(
 "Check all", frame: NSRect(x: 24, y: 28, width: 100, height: 28), action: #selector(onCheckAll)
 )
 let uncheckAll = makeButton(
 "Uncheck all", frame: NSRect(x: 132, y: 28, width: 110, height: 28), action: #selector(onUncheckAll)
 )
 let cancel = makeButton(
 "Cancel", frame: NSRect(x: winW - 250, y: 28, width: 90, height: 28), action: #selector(onCancel)
 )
 let sweep = makeButton(
 "Sweep now",
 frame: NSRect(x: winW - 150, y: 28, width: 120, height: 28),
 action: #selector(onSweepNow),
 accent: true
 )

 chooseBox.addSubview(choosePrompt)
 chooseBox.addSubview(chooseBookHint)
 chooseBox.addSubview(chooseScroll)
 chooseBox.addSubview(checkAll)
 chooseBox.addSubview(uncheckAll)
 chooseBox.addSubview(cancel)
 chooseBox.addSubview(sweep)
 contentRoot.addSubview(chooseBox)
 chooseBox.isHidden = true
 }

 func buildDone() {
 doneBox = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - 170))

 doneScroll = NSScrollView(frame: NSRect(x: 24, y: 70, width: winW - 48, height: winH - 250))
 doneScroll.hasVerticalScroller = true
 doneScroll.borderType = .bezelBorder
 doneScroll.backgroundColor = cardBg

 doneText = NSTextView(frame: NSRect(x: 0, y: 0, width: winW - 64, height: 200))
 doneText.isEditable = false
 doneText.isSelectable = true
 doneText.font = NSFont.systemFont(ofSize: 13)
 doneText.textColor = .white
 doneText.backgroundColor = cardBg
 doneScroll.documentView = doneText

 let ok = makeButton(
 "OK",
 frame: NSRect(x: (winW - 120) / 2, y: 24, width: 120, height: 32),
 action: #selector(onOK),
 accent: true
 )
 doneBox.addSubview(doneScroll)
 doneBox.addSubview(ok)
 contentRoot.addSubview(doneBox)
 doneBox.isHidden = true
 }

 // MARK: - Phase switching

 func showPhase(_ name: String) {
 welcomeBox.isHidden = true
 progressBox.isHidden = true
 chooseBox.isHidden = true
 doneBox.isHidden = true
 animate = false
 broomLabel.stringValue = "(*^▽^*)"

 switch name {
 case "welcome":
 welcomeBox.isHidden = false
 titleLabel.stringValue = "Janitor"
 subtitleLabel.stringValue = "Assess first. Pick hogs before anything is deleted"
 animate = true
 case "assessing":
 progressBox.isHidden = false
 titleLabel.stringValue = "Assessing"
 subtitleLabel.stringValue = "Indexing reclaimable caches…"
 logView.string = ""
 animate = true
 case "choose":
 chooseBox.isHidden = false
 titleLabel.stringValue = "Choose what to sweep"
 subtitleLabel.stringValue = "Check tasks, then Sweep now"
 animate = false
 case "sweeping":
 progressBox.isHidden = false
 titleLabel.stringValue = "Sweeping"
 subtitleLabel.stringValue = "Cleaning selected tasks…"
 logView.string = ""
 animate = true
 case "done":
 doneBox.isHidden = false
 titleLabel.stringValue = "Hooray! Cleanup complete"
 // subtitle often overwritten by bash "subtitle Disk freed: …"
 subtitleLabel.stringValue = "Your disk is a little tidier"
 animate = false
 broomLabel.stringValue = "☆(≧▽≦)☆"
 default:
 hudLog("unknown phase \(name)")
 }
 hudLog("phase=\(name)")
 }

 func appendLog(_ line: String) {
 let existing = logView.string
 let next = existing.isEmpty ? line : existing + "\n" + line
 logView.string = next
 logView.scrollToEndOfDocument(nil)
 }

 func heightForWrappedText(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
 guard !text.isEmpty, width > 0 else { return 0 }
 let attrs: [NSAttributedString.Key: Any] = [.font: font]
 let rect = (text as NSString).boundingRect(
 with: NSSize(width: width, height: 10_000),
 options: [.usesLineFragmentOrigin, .usesFontLeading],
 attributes: attrs
 )
 return ceil(rect.height) + 2
 }

 func makeWrappedNote(
 _ text: String,
 frame: NSRect,
 font: NSFont,
 color: NSColor
 ) -> NSTextField {
 let note = NSTextField(frame: frame)
 note.stringValue = text
 note.isBezeled = false
 note.isBordered = false
 note.drawsBackground = false
 note.isEditable = false
 note.isSelectable = true
 note.font = font
 note.textColor = color
 note.maximumNumberOfLines = 0
 note.lineBreakMode = .byWordWrapping
 note.cell?.wraps = true
 note.cell?.isScrollable = false
 note.cell?.usesSingleLineMode = false
 return note
 }

 func rebuildChooseList() {
 chooseChecks.removeAll()
 chooseBooks.removeAll()
 chooseDoc.subviews.forEach { $0.removeFromSuperview() }

 let listW = winW - 64
 let bookW: CGFloat = 36
 let textW = listW - bookW - 48
 let titleFont = NSFont.boldSystemFont(ofSize: 13)
 let noteFont = NSFont.systemFont(ofSize: 12)
 let tradeColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.35, alpha: 1)

 var rowHeights: [CGFloat] = []
 for item in chooseItems {
 var h: CGFloat = 8 + 26 + 6 // top pad + title + gap
 if !item.because.isEmpty {
 h += heightForWrappedText(item.because, font: noteFont, width: textW) + 4
 }
 if !item.tradeoff.isEmpty {
 h += heightForWrappedText(item.tradeoff, font: noteFont, width: textW) + 4
 }
 h += 8 // bottom pad
 rowHeights.append(max(h, 70))
 }

 let contentH = rowHeights.reduce(CGFloat(0), +)
 // Pin document so first row is at the top of the scroll view when short
 if contentH < chooseScroll.frame.height {
 chooseDoc.frame = NSRect(
 x: 0,
 y: chooseScroll.frame.height - contentH,
 width: listW,
 height: contentH
 )
 } else {
 chooseDoc.frame = NSRect(x: 0, y: 0, width: listW, height: contentH)
 }

 var y = contentH
 for (i, item) in chooseItems.enumerated() {
 let rowH = rowHeights[i]
 y -= rowH
 let row = NSView(frame: NSRect(x: 0, y: y, width: listW, height: rowH))

 let titleH: CGFloat = 26
 let cb = NSButton(
 frame: NSRect(x: 8, y: rowH - 8 - titleH, width: listW - bookW - 28, height: titleH)
 )
 cb.setButtonType(.switch)
 cb.title = item.title
 cb.state = .off
 cb.font = titleFont
 if #available(macOS 10.14, *) {
 cb.contentTintColor = .white
 }
 row.addSubview(cb)
 chooseChecks.append(cb)

 let book = NSButton(
 frame: NSRect(x: listW - bookW - 8, y: rowH - 8 - 28, width: bookW, height: 28)
 )
 book.bezelStyle = .rounded
 book.title = "📖"
 book.toolTip = "Educate me further"
 book.tag = i
 book.target = self
 book.action = #selector(onEducate(_:))
 book.isEnabled = !item.educate.isEmpty
 row.addSubview(book)
 chooseBooks.append(book)

 var cursorY = rowH - 8 - titleH - 6
 if !item.because.isEmpty {
 let nh = heightForWrappedText(item.because, font: noteFont, width: textW)
 cursorY -= nh
 let note = makeWrappedNote(
 item.because,
 frame: NSRect(x: 32, y: cursorY, width: textW, height: nh),
 font: noteFont,
 color: NSColor.secondaryLabelColor
 )
 row.addSubview(note)
 cursorY -= 4
 }
 if !item.tradeoff.isEmpty {
 let nh = heightForWrappedText(item.tradeoff, font: noteFont, width: textW)
 cursorY -= nh
 let note = makeWrappedNote(
 item.tradeoff,
 frame: NSRect(x: 32, y: cursorY, width: textW, height: nh),
 font: noteFont,
 color: tradeColor
 )
 row.addSubview(note)
 }
 chooseDoc.addSubview(row)
 }
 }

 // MARK: - Protocol

 func emit(_ event: String) {
 guard !sessionDir.isEmpty else { return }
 let path = sessionDir + "/events"
 let line = event + "\n"
 if let data = line.data(using: .utf8) {
 if FileManager.default.fileExists(atPath: path),
 let fh = FileHandle(forWritingAtPath: path) {
 fh.seekToEndOfFile()
 fh.write(data)
 try? fh.close()
 } else {
 try? data.write(to: URL(fileURLWithPath: path))
 }
 }
 hudLog("event \(event)")
 }

 func pollCommands() {
 let path = sessionDir + "/cmd"
 guard let fh = FileHandle(forReadingAtPath: path) else { return }
 fh.seek(toFileOffset: cmdOffset)
 let data = fh.readDataToEndOfFile()
 try? fh.close()
 guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
 cmdOffset += UInt64(data.count)

 for raw in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
 let line = String(raw)
 if line.isEmpty { continue }
 handleCommand(line)
 }
 }

 func handleCommand(_ line: String) {
 if line.hasPrefix("phase ") {
 let name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
 bufferingItems = false
 bufferingDone = false
 if name == "choose" {
 pendingItems = []
 chooseItems = []
 }
 if name == "done" {
 pendingDoneLines = []
 }
 showPhase(name)
 return
 }
 if line.hasPrefix("log ") {
 appendLog(String(line.dropFirst(4)))
 return
 }
 if line.hasPrefix("item ") || line.hasPrefix("item\t") {
 bufferingItems = true
 let rest = line.hasPrefix("item ") ? String(line.dropFirst(5)) : String(line.dropFirst(5))
 let parts = rest.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
 guard parts.count >= 2 else { return }
 let eduRaw = parts.count > 4 ? String(parts[4]) : ""
 let edu = eduRaw.replacingOccurrences(of: "¶", with: "\n\n")
 pendingItems.append(
 ChooseItem(
 id: String(parts[0]),
 title: String(parts[1]),
 because: parts.count > 2 ? String(parts[2]) : "",
 tradeoff: parts.count > 3 ? String(parts[3]) : "",
 educate: edu
 )
 )
 return
 }
 if line == "items_end" {
 chooseItems = pendingItems
 pendingItems = []
 bufferingItems = false
 rebuildChooseList()
 return
 }
 if line.hasPrefix("subtitle ") {
 subtitleLabel.stringValue = String(line.dropFirst(9))
 return
 }
 if line.hasPrefix("done_line ") {
 bufferingDone = true
 pendingDoneLines.append(String(line.dropFirst(10)))
 return
 }
 if line == "done_end" {
 doneText.string = pendingDoneLines.joined(separator: "\n")
 pendingDoneLines = []
 bufferingDone = false
 return
 }
 if line == "quit" {
 NSApp.terminate(nil)
 return
 }
 }

 // MARK: - Actions

 @objc func onStart() { emit("start") }
 @objc func onStartDeep() { emit("start_deep") }
 @objc func onStartBrave() { emit("start_brave") }
 @objc func onStartStupid() { emit("start_stupid") }
 @objc func onCancel() { emit("cancel") }
 @objc func onOK() { emit("ok") }

 @objc func onWelcomeHelp(_ sender: NSButton) {
 let i = sender.tag
 guard i >= 0, i < welcomeHelpBodies.count else { return }
 let tip = welcomeHelpBodies[i]
 let alert = NSAlert()
 alert.messageText = tip.title
 alert.informativeText = tip.body
 alert.alertStyle = .informational
 alert.addButton(withTitle: "Got it")
 alert.runModal()
 }

 @objc func onEducate(_ sender: NSButton) {
 let i = sender.tag
 guard i >= 0, i < chooseItems.count else { return }
 let item = chooseItems[i]
 let alert = NSAlert()
 alert.messageText = "📖 Educate me further: \(item.id)"
 var body = ""
 if !item.because.isEmpty { body += item.because + "\n\n" }
 if !item.tradeoff.isEmpty { body += item.tradeoff + "\n\n" }
 body += item.educate.isEmpty ? "(no educate note for this hog yet)" : item.educate
 alert.informativeText = body
 alert.alertStyle = .informational
 alert.addButton(withTitle: "Got it")
 alert.runModal()
 }

 @objc func onCheckAll() {
 for cb in chooseChecks { cb.state = .on }
 }

 @objc func onUncheckAll() {
 for cb in chooseChecks { cb.state = .off }
 }

 @objc func onSweepNow() {
 var ids: [String] = []
 for (i, cb) in chooseChecks.enumerated() {
 if cb.state == .on, i < chooseItems.count {
 ids.append(chooseItems[i].id)
 }
 }
 if ids.isEmpty {
 let alert = NSAlert()
 alert.messageText = "Nothing checked"
 alert.informativeText = "Check at least one task to clean, or Cancel."
 alert.alertStyle = .informational
 alert.addButton(withTitle: "OK")
 alert.runModal()
 return
 }
 emit("sweep " + ids.joined(separator: ","))
 }
}

extension Hud: NSWindowDelegate {
 func windowShouldClose(_ sender: NSWindow) -> Bool {
 emit("cancel")
 return true
 }
}

hudLog("launch session=\(sessionDir.isEmpty ? "<legacy>" : sessionDir)")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Hud()
app.delegate = delegate
app.run()
