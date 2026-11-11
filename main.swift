// Apollo Volume Keys
//
// Makes the Mac's volume and mute keys drive a Universal Audio Apollo's MONITOR
// level. The Apollo exposes no volume control to macOS, so this talks to the
// UA Mixer Engine's local (undocumented) TCP API on 127.0.0.1:4710 instead.
//
// The keys are taken over only while the Apollo is the default output and the
// engine is reachable; otherwise they pass through to macOS untouched.

import AppKit
import CoreAudio
import Network
import ServiceManagement

// MARK: - UA Mixer Engine connection

/// One connection to the mixer engine. Messages are "<verb> <path> [value]"
/// terminated by a NUL byte; replies are NUL-terminated JSON {"path", "data"}.
final class Engine {
    static let minDb = -96.0, maxDb = 0.0

    private(set) var db: Double?      // nil until the engine has reported it
    private(set) var muted = false
    var onChange: () -> Void = {}

    private var conn: NWConnection?
    private var buffer = Data()
    private var monitor: String?      // e.g. "/devices/0/outputs/4"

    /// True once the MONITOR output is found and its level is known.
    var isLive: Bool { monitor != nil && db != nil }

    func connect() {
        let c = NWConnection(host: "127.0.0.1", port: 4710, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.conn else { return }
            switch state {
            case .ready:
                self.send("get /devices")
                self.receive(on: c)
            case .failed, .cancelled, .waiting:   // .waiting: engine not running
                self.reconnectLater()
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    private func reconnectLater() {
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        buffer.removeAll()
        monitor = nil
        db = nil
        onChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.conn == nil { self?.connect() }
        }
    }

    func send(_ command: String) {
        conn?.send(content: Data(command.utf8) + [0], completion: .contentProcessed { _ in })
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, error in
            guard let self, let c, c === self.conn else { return }
            if let data {
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 0) {
                    let frame = self.buffer[self.buffer.startIndex..<end]
                    self.buffer = Data(self.buffer[self.buffer.index(after: end)...])
                    if let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                       let path = json["path"] as? String {
                        self.handle(path, json["data"])
                    }
                }
            }
            if done || error != nil { self.reconnectLater() } else { self.receive(on: c) }
        }
    }

    /// Discovery walks /devices -> outputs -> the output whose IOType is
    /// "Monitor", then subscribes so knob and Console changes are pushed to us.
    private func handle(_ path: String, _ data: Any?) {
        if path == "/devices" {
            if let device = Self.children(data).first { send("get /devices/\(device)/outputs") }
        } else if path.hasSuffix("/outputs") {
            for output in Self.children(data) { send("get \(path)/\(output)/IOType/value") }
        } else if path.hasSuffix("/IOType/value") {
            guard monitor == nil, data as? String == "Monitor" else { return }
            let base = String(path.dropLast("/IOType/value".count))
            monitor = base
            send("subscribe \(base)/CRMonitorLevel/value")
            send("subscribe \(base)/Mute/value")
        } else if let monitor, path == "\(monitor)/CRMonitorLevel/value", let value = data as? Double {
            db = value
            onChange()
        } else if let monitor, path == "\(monitor)/Mute/value", let value = data as? Bool {
            muted = value
            onChange()
        }
    }

    private static func children(_ data: Any?) -> [Int] {
        let dict = (data as? [String: Any])?["children"] as? [String: Any]
        return (dict?.keys.compactMap { Int($0) } ?? []).sorted()
    }

    /// Move the level by `delta` dB, landing on a whole dB.
    func step(_ delta: Double) {
        guard let monitor, let current = db else { return }
        let target = min(Self.maxDb, max(Self.minDb, (current + delta).rounded()))
        db = target   // optimistic, so held-key repeats compound correctly
        send(String(format: "set %@/CRMonitorLevel/value %.6f", monitor, target))
        onChange()
    }

    func toggleMute() {
        guard let monitor, db != nil else { return }
        muted.toggle()
        send("set \(monitor)/Mute/value \(muted ? "true" : "false")")
        onChange()
    }
}

// MARK: - Is the Apollo the default output?

func defaultOutputIsApollo() -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
    else { return false }
    for selector in [kAudioObjectPropertyManufacturer, kAudioObjectPropertyName] {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
           let text = name?.takeRetainedValue() as String?, text.contains("Universal Audio") {
            return true
        }
    }
    return false
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var apolloIsOutput = false
    private var tap: CFMachPort?
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onChange = { [weak self] in self?.refresh() }
        engine.connect()
        // The engine's own clients write /Sleep every few seconds to keep the socket open.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.engine.send("set /Sleep false")
        }

        // Cached and updated by a listener, so the key handler never waits on Core Audio.
        apolloIsOutput = defaultOutputIsApollo()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.apolloIsOutput = defaultOutputIsApollo()
        }

        // Swallowing keys needs Accessibility. Ask once, then wait for the grant.
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        startTap()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.startTap() }
        refresh()
    }

    /// Listens for system-defined (media key) events only; ordinary keystrokes
    /// are never delivered to this process.
    private func startTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let app = Unmanaged<App>.fromOpaque(refcon!).takeUnretainedValue()
            return app.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << 14,   // NX_SYSDEFINED
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        trustTimer?.invalidate()
        trustTimer = nil
        refresh()
    }

    /// Returns true to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14, apolloIsOutput, engine.isLive,
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8   // media key
        else { return false }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        let isRepeat = ns.data1 & 1 == 1
        let step = isRepeat ? 2.0 : 1.0   // a held key moves faster
        switch key {
        case 0: if isDown { engine.step(step) }                // NX_KEYTYPE_SOUND_UP
        case 1: if isDown { engine.step(-step) }               // NX_KEYTYPE_SOUND_DOWN
        case 7: if isDown && !isRepeat { engine.toggleMute() } // NX_KEYTYPE_MUTE
        default: return false
        }
        return true
    }

    private func refresh() {
        let title: String
        if tap == nil {
            title = "⚠︎ Vol"
        } else if let db = engine.db, engine.isLive {
            title = engine.muted ? "Muted" : String(format: "%.0f dB", db)
        } else {
            title = "– dB"
        }
        statusItem.button?.title = title
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if tap == nil {
            menu.addItem(withTitle: "Grant Accessibility…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        } else if !engine.isLive {
            menu.addItem(withTitle: "UA Mixer Engine not reachable", action: nil, keyEquivalent: "")
        } else if !apolloIsOutput {
            menu.addItem(withTitle: "Apollo is not the system output", action: nil, keyEquivalent: "")
        }
        let login = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
