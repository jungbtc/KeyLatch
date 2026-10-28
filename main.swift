import AppKit
import ApplicationServices

// Physical ANSI key positions. Chords work independently of input language.
let letterKeys: [Character: Int64] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]

struct LockState {
    var chord: Set<Int64> = [0,1,2,3]
    var pressed: Set<Int64> = []
    var active = false
    var matched = false
    var deadline: TimeInterval?
    mutating func start(chord: Set<Int64>, now: TimeInterval, duration: TimeInterval?) {
        self.chord = chord; pressed = []; matched = false; active = true
        deadline = duration.map { now + $0 }
    }
    // Once matched, wait for every swallowed key to be released before restoring input.
    mutating func key(_ code: Int64, down: Bool) -> Bool {
        guard active else { return false }
        if down { pressed.insert(code) } else { pressed.remove(code) }
        if chord.isSubset(of: pressed) { matched = true }
        return matched && pressed.isEmpty
    }
    func expired(at now: TimeInterval) -> Bool { active && deadline.map { now >= $0 } == true }
    mutating func stop() { active = false; matched = false; pressed = []; deadline = nil }
}

func parseChord(_ text: String) -> Set<Int64>? {
    let letters = Array(text.lowercased().filter { !$0.isWhitespace })
    guard (2...6).contains(letters.count), Set(letters).count == letters.count,
          letters.allSatisfy({ letterKeys[$0] != nil }) else { return nil }
    return Set(letters.compactMap { letterKeys[$0] })
}

func runSelfTests() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    check(parseChord("asdf") == [0,1,2,3], "Default chord")
    check(parseChord("A S D F") == [0,1,2,3], "Normalization")
    check(parseChord("aa") == nil && parseChord("a!") == nil && parseChord("a") == nil, "Validation")
    var state = LockState()
    state.start(chord: [0,1,2,3], now: 100, duration: 30)
    for k: Int64 in [0,1,2] { check(!state.key(k, down: true), "Partial chord") }
    check(!state.key(2, down: true) && !state.matched, "Repeat is not a chord")
    check(!state.key(3, down: true) && state.matched, "Match waits for release")
    for k: Int64 in [0,1,2] { check(!state.key(k, down: false), "Partial release") }
    check(state.key(3, down: false), "Complete release unlocks")
    check(!state.expired(at: 129) && state.expired(at: 130), "Timer boundary")
    state.stop(); check(!state.active && !state.expired(at: 200), "Stop clears deadline")
    state.start(chord: [0,1], now: 200, duration: nil)
    check(!state.expired(at: 999999), "Chord-only mode")
    _ = state.key(0, down: true); _ = state.key(0, down: false)
    _ = state.key(1, down: true); check(!state.matched, "Sequential typing must not unlock")
    state.stop(); check(state.pressed.isEmpty, "Recovery clears pressed keys")
    for cycle in 0..<100 {
        state.start(chord: [0,1,2,3], now: Double(cycle), duration: 10)
        check(state.active && !state.matched && state.pressed.isEmpty, "Relock starts clean")
        for k: Int64 in [0,1,2,3] { _ = state.key(k, down: true) }
        for k: Int64 in [0,1,2] { check(!state.key(k, down: false), "Relock partial release") }
        check(state.key(3, down: false), "Relock chord release")
        state.stop()
    }
    print("PASS: chord validation, simultaneous hold, repeat handling, release, timer, reset, chord-only mode, 100 relock cycles.")
}

let keyboardCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info = info else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
    guard app.state.active else { return Unmanaged.passUnretained(event) }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Fail open: never claim to be locked if macOS has disabled capture.
        app.scheduleUnlock("Keyboard capture interrupted. Input restored.")
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown || type == .keyUp {
        let released = app.state.key(event.getIntegerValueField(.keyboardEventKeycode), down: type == .keyDown)
        if released { app.scheduleUnlock("Unlocked with your key chord.") }
    }
    return nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var state = LockState()
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var lockGeneration = 0
    var window: NSWindow!
    var menuItem: NSStatusItem!
    let statusLabel = NSTextField(labelWithString: "Your keyboard is ready")
    let detailLabel = NSTextField(wrappingLabelWithString: "Hold your chord together, then release to unlock. Your mouse always stays available.")
    let chordField = NSTextField(string: UserDefaults.standard.string(forKey: "chord") ?? "asdf")
    let autoUnlock = NSButton(checkboxWithTitle: "Automatically unlock after", target: nil, action: nil)
    let duration = NSPopUpButton(frame: .zero, pullsDown: false)
    let lockButton = NSButton(title: "Lock keyboard", target: nil, action: nil)
    let permissionButton = NSButton(title: "Set up Accessibility…", target: nil, action: nil)
    let countdown = NSTextField(labelWithString: "")
    let durations: [TimeInterval] = [10,30,60,300,600,1800,3600]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow(); buildMenu(); buildMainMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        showWindow()
        timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyLatch"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        let title = NSTextField(labelWithString: "Give your keyboard a break.")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        root.addArrangedSubview(title)
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium); statusLabel.textColor = .systemGreen
        root.addArrangedSubview(statusLabel)
        detailLabel.font = .systemFont(ofSize: 13); detailLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(detailLabel)
        let divider = NSBox(); divider.boxType = .separator; root.addArrangedSubview(divider)
        let chordTitle = NSTextField(labelWithString: "UNLOCK CHORD"); chordTitle.font = .systemFont(ofSize: 11, weight: .semibold); chordTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(chordTitle)
        chordField.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        chordField.placeholderString = "asdf"; chordField.setAccessibilityLabel("Unlock chord, two to six different letters")
        chordField.widthAnchor.constraint(equalToConstant: 424).isActive = true
        root.addArrangedSubview(chordField)
        let help = NSTextField(wrappingLabelWithString: "Choose 2–6 different letters. Use the letter positions on a US keyboard. Press them together, not as a typed password.")
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor; root.addArrangedSubview(help)
        duration.addItems(withTitles: ["10 seconds","30 seconds","1 minute","5 minutes","10 minutes","30 minutes","1 hour"])
        let saved = UserDefaults.standard.object(forKey: "durationIndex") as? Int ?? 2
        duration.selectItem(at: min(max(saved,0),durations.count-1)); duration.setAccessibilityLabel("Automatic unlock duration")
        autoUnlock.state = UserDefaults.standard.object(forKey: "autoUnlock") as? Bool == false ? .off : .on
        autoUnlock.target = self; autoUnlock.action = #selector(timerChanged)
        let row = NSStackView(views: [autoUnlock,duration]); row.spacing = 12; root.addArrangedSubview(row)
        countdown.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium); root.addArrangedSubview(countdown)
        lockButton.target = self; lockButton.action = #selector(toggleLock); lockButton.bezelStyle = .rounded; lockButton.controlSize = .large
        lockButton.widthAnchor.constraint(equalToConstant: 424).isActive = true; root.addArrangedSubview(lockButton)
        permissionButton.target = self; permissionButton.action = #selector(setupPermission); permissionButton.bezelStyle = .rounded
        root.addArrangedSubview(permissionButton)
        timerChanged()
    }
    func buildMenu() {
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuItem.button?.title = "⌨︎"
        menuItem.button?.setAccessibilityLabel("KeyLatch keyboard lock")
        let menu = NSMenu()
        for (title, selector) in [("Show KeyLatch", #selector(showWindow)), ("Unlock keyboard", #selector(mouseUnlock)), ("Quit KeyLatch", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menuItem.menu = menu
    }
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let quitItem = NSMenuItem(title: "Quit KeyLatch", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        NSApp.mainMenu = main
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func setupPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        statusLabel.stringValue = "Enable KeyLatch in Accessibility"
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = "Enable KeyLatch in System Settings → Privacy & Security → Accessibility, then return and click Lock keyboard. You may need to quit and reopen it."
    }
    @objc func timerChanged() { duration.isEnabled = autoUnlock.state == .on && !state.active }
    @objc func toggleLock() {
        if state.active { mouseUnlock(); return }
        window.makeFirstResponder(nil)
        guard let chord = parseChord(chordField.stringValue) else {
            statusLabel.stringValue = "Use 2–6 different letters (A–Z)."; statusLabel.textColor = .systemRed; return
        }
        guard AXIsProcessTrusted() else { setupPermission(); return }
        // A fresh connection avoids reusing taps disabled or invalidated by macOS.
        disposeCapture()
        lockGeneration += 1
        do {
            // Include system-defined keyboard events (media/function keys) without touching mouse events.
            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: keyboardCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap = tap else {
                statusLabel.stringValue = "macOS could not enable keyboard capture."; statusLabel.textColor = .systemRed
                detailLabel.stringValue = "Check Accessibility permission, quit and reopen KeyLatch, and try again. Your keyboard is still unlocked."; return
            }
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            guard let source = source else {
                disposeCapture()
                statusLabel.stringValue = "Could not start keyboard capture. Try again."
                statusLabel.textColor = .systemRed
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        state.start(chord: chord, now: ProcessInfo.processInfo.systemUptime, duration: autoUnlock.state == .on ? durations[duration.indexOfSelectedItem] : nil)
        CGEvent.tapEnable(tap: tap!, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap!) else { unlock("Keyboard capture failed. Input remains available."); return }
        UserDefaults.standard.set(chordField.stringValue, forKey: "chord")
        UserDefaults.standard.set(duration.indexOfSelectedItem, forKey: "durationIndex")
        UserDefaults.standard.set(autoUnlock.state == .on, forKey: "autoUnlock")
        statusLabel.stringValue = "Keyboard locked"; statusLabel.textColor = .systemOrange
        let display = chordField.stringValue.lowercased().filter { !$0.isWhitespace }.map { String($0).uppercased() }.joined(separator: " + ")
        detailLabel.stringValue = "Hold \(display) together, then release all keys. Or click Unlock keyboard with your mouse."
        lockButton.title = "Unlock keyboard"; menuItem.button?.title = "⌨︎ Locked"
        chordField.isEnabled = false; autoUnlock.isEnabled = false; duration.isEnabled = false
        window.level = .floating; tick()
    }
    // Keep the event callback short. AppKit work and tap teardown happen only
    // after the callback returns, so Quartz cannot time it out during UI updates.
    func scheduleUnlock(_ message: String) {
        state.stop()
        let generation = lockGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.lockGeneration == generation else { return }
            self.unlock(message)
        }
    }
    func disposeCapture() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    func unlock(_ message: String) {
        state.stop()
        disposeCapture()
        statusLabel.stringValue = message; statusLabel.textColor = .systemGreen
        detailLabel.stringValue = "Hold your chord together, then release to unlock. Your mouse always stays available."
        countdown.stringValue = ""; lockButton.title = "Lock keyboard"; menuItem?.button?.title = "⌨︎"
        chordField.isEnabled = true; autoUnlock.isEnabled = true; timerChanged(); window?.level = .normal
    }
    @objc func tick() {
        guard state.active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if state.expired(at: now) { unlock("Timer finished. Keyboard unlocked."); return }
        if let tap = tap, !CGEvent.tapIsEnabled(tap: tap) { unlock("Keyboard capture interrupted. Input restored."); return }
        if state.matched { statusLabel.stringValue = "Chord detected — release all keys" }
        if let deadline = state.deadline {
            let remaining = Int(ceil(max(0, deadline-now)))
            countdown.stringValue = String(format: "Unlocks in %02d:%02d", remaining / 60, remaining % 60)
        } else { countdown.stringValue = "Unlock with your chord or mouse" }
    }
    @objc func mouseUnlock() { unlock("Keyboard unlocked.") }
    @objc func sleeping() { unlock("Keyboard unlocked before sleep.") }
    @objc func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        // Preserve valid edits even when the user quits without starting a lock.
        if parseChord(chordField.stringValue) != nil {
            UserDefaults.standard.set(chordField.stringValue, forKey: "chord")
        }
        UserDefaults.standard.set(duration.indexOfSelectedItem, forKey: "durationIndex")
        UserDefaults.standard.set(autoUnlock.state == .on, forKey: "autoUnlock")
        state.stop(); timer?.invalidate()
        disposeCapture()
    }
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
