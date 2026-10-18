import AudioToolbox
import CoreMIDI
import ServiceManagement
import SwiftUI

// MARK: - 1. Main Entry Point

@main
struct MIDIRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - 2. Application Delegate & Menu Bar Manager

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var activity: NSObjectProtocol? // token must stay alive or App Nap returns
    private let engine = MIDIRecorderEngine.shared

    func applicationDidFinishLaunching(_: Notification) {
        // Prevent App Nap from throttling background recording timers
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Continuous background MIDI capture",
        )

        // Setup Menu Bar Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let menuBarIcon = NSImage(named: "menuBar")
            if let icon = menuBarIcon {
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "pianokeys", accessibilityDescription: "MIDI Recorder")
            }
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Setup SwiftUI Popover with flexible height
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 180) // Reduced default height
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover
    }

    func applicationWillTerminate(_: Notification) {
        engine.flush()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - 3. SwiftUI Menu Bar Interface

struct MenuBarView: View {
    @ObservedObject private var engine = MIDIRecorderEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Status Bar
            HStack {
                Circle()
                    .fill(engine.isPaused ? Color.yellow : (engine.liveNoteCount > 0 ? Color.green : Color.red))
                    .frame(width: 8, height: 8)

                Text(engine.isPaused ? "Paused" : "Listening...")
                    .font(.headline)

                Spacer()

                Button(action: { engine.isPaused.toggle() }) {
                    Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                        .accessibilityLabel("Toggle Recording")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            // Live Metrics
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notes Recorded:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(engine.liveNoteCount)")
                        .bold()
                }

                HStack {
                    Text("Last Recorded:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(engine.lastSavedFilename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            // Shell Command Action Settings
            VStack(alignment: .leading, spacing: 4) {
                Text("Post-Save Shell Command (%f = file path, %n = file name)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("e.g. scp \"%f\" my-server:~/midi/", text: $engine.postSaveCommand)
                    .textFieldStyle(.roundedBorder)

                Text("Leave blank to skip execution.")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Divider()

            // Bottom Control Row: Launch at Login & Quit side-by-side
            HStack(alignment: .center) {
                Toggle("Launch at Login", isOn: $engine.launchAtLogin)
                    .toggleStyle(.switch)
                    .font(.caption)

                Spacer(minLength: 16)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.red)
            }
        }
        .padding(12)
        .frame(width: 500) // Fixed width, content determines height automatically
    }
}

// MARK: - 4. Background CoreMIDI Recorder Engine

final class MIDIRecorderEngine: ObservableObject {
    static let shared = MIDIRecorderEngine()

    @Published var isPaused: Bool = false {
        didSet { queue.async { self.pausedOnQueue = self.isPaused } }
    }

    @Published var liveNoteCount: Int = 0
    @Published var lastSavedFilename: String = "None"

    @AppStorage("postSaveCommand") var postSaveCommand: String = ""

    /// Native SMAppService Launch at Login state
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update Launch at Login status: \(error.localizedDescription)")
                launchAtLogin = oldValue // assigning inside didSet does not re-enter it
                lastSavedFilename = "Launch at Login failed: \(error.localizedDescription)"
            }
        }
    }

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    private var currentSequence: MusicSequence?
    private var currentTrack: MusicTrack?
    private var sequenceStartTime: Date? // wall clock, for the file name
    private var sequenceStartHost: UInt64 = 0 // monotonic host time, for event times
    private var lastEventBeats: MusicTimeStamp = 0
    private var openNotes = Set<UInt16>() // (channel << 8 | note) with no note-off yet
    private var pausedOnQueue = false

    private var silenceWork: DispatchWorkItem?
    private var noteCount = 0
    private let silenceInterval: TimeInterval = 5.0
    private let maxTakeSeconds: TimeInterval = 30 * 60 // shortcut: fixed cap, make it a setting if someone needs longer takes
    private let outputDirectory: URL

    private let queue = DispatchQueue(label: "com.midi.recorder.queue")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        outputDirectory = docs.appendingPathComponent("MIDIRecorder")

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create \(outputDirectory.path): \(error)")
            lastSavedFilename = "Cannot create output folder"
        }
        createNewSequence()
        setupMIDI()
    }

    private func setupMIDI() {
        var status = MIDIClientCreateWithBlock("MIDIRecorderClient" as CFString, &client) { [weak self] notificationPtr in
            if notificationPtr.pointee.messageID == .msgSetupChanged {
                self?.connectAllSources()
            }
        }
        guard status == noErr else { return reportSetupFailure(status) }

        status = MIDIInputPortCreateWithBlock(client, "MIDIRecorderInput" as CFString, &inputPort) { [weak self] packetListPtr, _ in
            self?.handleIncomingMIDIPackets(packetListPtr)
        }
        guard status == noErr else { return reportSetupFailure(status) }

        connectAllSources()
    }

    private func reportSetupFailure(_ status: OSStatus) {
        print("CoreMIDI setup failed: \(status)")
        DispatchQueue.main.async {
            self.lastSavedFilename = "MIDI setup failed (\(status))"
        }
    }

    private func connectAllSources() {
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0 ..< sourceCount {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(inputPort, src, nil)
        }
    }

    private func createNewSequence() {
        if let seq = currentSequence {
            DisposeMusicSequence(seq)
        }
        NewMusicSequence(&currentSequence)
        if let seq = currentSequence {
            MusicSequenceNewTrack(seq, &currentTrack)
            if let track = currentTrack {
                let dataBytes = Array("MIDIRecorder".utf8)
                let dataOffset = MemoryLayout<MIDIMetaEvent>.offset(of: \.data)!
                let size = dataOffset + dataBytes.count
                let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIMetaEvent>.alignment)
                defer { raw.deallocate() }
                memset(raw, 0, size)
                let ptr = raw.bindMemory(to: MIDIMetaEvent.self, capacity: 1)
                ptr.pointee.metaEventType = 0x02
                ptr.pointee.dataLength = UInt32(dataBytes.count)
                memcpy(raw.advanced(by: dataOffset), dataBytes, dataBytes.count)
                let status = MusicTrackNewMetaEvent(track, 0, ptr)
                if status != noErr {
                    print("Failed to add watermark meta-event: \(status)")
                }
            }
        }
        sequenceStartTime = nil
        lastEventBeats = 0
        openNotes.removeAll()
        noteCount = 0
        DispatchQueue.main.async {
            self.liveNoteCount = 0
        }
    }

    private func handleIncomingMIDIPackets(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        // Parse now: the list is only valid during this callback.
        let nowHost = AudioGetCurrentHostTime()
        let now = Date()
        var events: [(host: UInt64, msg: MIDIChannelMessage)] = []
        for packet in packetListPtr.unsafeSequence() {
            let p = packet.pointee
            let host = p.timeStamp == 0 ? nowHost : p.timeStamp
            let length = Int(p.length)
            withUnsafeBytes(of: p.data) { raw in
                for msg in ChannelParser.parse(UnsafeRawBufferPointer(rebasing: raw.prefix(length))) {
                    events.append((host, msg))
                }
            }
        }

        queue.async { [weak self] in
            guard let self else { return }

            var events = events
            if pausedOnQueue {
                // Still close notes opened before the pause, but never start a take.
                events = events.filter { Self.isNoteOff($0.msg) }
                if sequenceStartTime == nil {
                    return
                }
            }
            // Clock, active sensing and SysEx carry no channel messages: they must not start a take or reset the silence timer.
            guard !events.isEmpty else { return }

            // Endless input (looper, controller streaming CC) never goes silent: cut the take.
            if let start = sequenceStartTime, now.timeIntervalSince(start) > maxTakeSeconds {
                saveCurrentSequenceAndReset()
            }
            if sequenceStartTime == nil {
                sequenceStartTime = now
                sequenceStartHost = events[0].host
            }
            guard let track = currentTrack else { return }

            for var event in events {
                let nanos = AudioConvertHostTimeToNanos(max(event.host, sequenceStartHost) - sequenceStartHost)
                lastEventBeats = MusicTimeStamp(Double(nanos) / 1e9 * 2.0)
                MusicTrackNewMIDIChannelEvent(track, lastEventBeats, &event.msg)
                let key = UInt16(event.msg.status & 0x0F) << 8 | UInt16(event.msg.data1)
                if Self.isNoteOff(event.msg) {
                    openNotes.remove(key)
                } else if event.msg.status & 0xF0 == 0x90 {
                    openNotes.insert(key)
                    noteCount += 1
                }
            }

            let count = noteCount
            DispatchQueue.main.async {
                self.liveNoteCount = count
            }
            resetSilenceTimer()
        }
    }

    private static func isNoteOff(_ m: MIDIChannelMessage) -> Bool {
        m.status & 0xF0 == 0x80 || (m.status & 0xF0 == 0x90 && m.data2 == 0)
    }

    /// Save the in-progress take now (used on quit). Blocks until written.
    func flush() {
        queue.sync {
            silenceWork?.cancel()
            saveCurrentSequenceAndReset()
        }
    }

    /// Must run on `queue`: GCD threads have no RunLoop, so a Timer would never fire.
    private func resetSilenceTimer() {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveCurrentSequenceAndReset()
        }
        silenceWork = work
        queue.asyncAfter(deadline: .now() + silenceInterval, execute: work)
    }

    private func saveCurrentSequenceAndReset() {
        guard let sequence = currentSequence, let startTime = sequenceStartTime else { return }

        // queue-owned count; liveNoteCount is main-thread UI state and may lag
        let liveNoteCount = noteCount
        if liveNoteCount == 0 {
            createNewSequence()
            return
        }

        // Close notes still held, so players do not sustain them forever.
        if let track = currentTrack {
            for key in openNotes {
                var off = MIDIChannelMessage(status: 0x80 | UInt8(key >> 8), data1: UInt8(key & 0xFF), data2: 0, reserved: 0)
                MusicTrackNewMIDIChannelEvent(track, lastEventBeats, &off)
            }
            openNotes.removeAll()
        }

        let durationInSeconds = Int(Date().timeIntervalSince(startTime))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX") // keep the name stable across regions
        dateFormatter.dateFormat = "yyyy-MM-dd HHmm (EEEE)"
        let dateString = dateFormatter.string(from: startTime)

        let filename = "\(dateString) \(liveNoteCount) notes, \(durationInSeconds) seconds.mid"
        let localFileURL = outputDirectory.appendingPathComponent(filename)

        let status = MusicSequenceFileCreate(sequence, localFileURL as CFURL, .midiType, [.eraseFile], 0)

        guard status == noErr else {
            // Keep the take in memory; the next silence retries.
            print("Failed to save \(filename): \(status)")
            resetSilenceTimer() // retry even if no more MIDI arrives
            DispatchQueue.main.async {
                self.lastSavedFilename = "Save failed (\(status))"
            }
            return
        }

        DispatchQueue.main.async {
            self.lastSavedFilename = filename
        }
        executePostSaveCommand(forFileURL: localFileURL)
        createNewSequence()
    }

    private func reportPostSaveFailure(_ detail: String) {
        DispatchQueue.main.async {
            self.lastSavedFilename = "Post-save failed (\(detail))"
        }
    }

    private func executePostSaveCommand(forFileURL fileURL: URL) {
        let rawCommand = postSaveCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCommand.isEmpty else { return }

        // Expand %f to full path and %n to filename only
        let formattedCommand = rawCommand
            .replacingOccurrences(of: "%f", with: fileURL.path)
            .replacingOccurrences(of: "%n", with: fileURL.lastPathComponent)

        // Not on `queue`: a slow command must not block recording or quit.
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", formattedCommand]

            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    print("Post-save command exited with status: \(task.terminationStatus)")
                    self.reportPostSaveFailure("exit \(task.terminationStatus)")
                }
            } catch {
                print("Failed to run post-save command: \(error.localizedDescription)")
                self.reportPostSaveFailure(error.localizedDescription)
            }
        }
    }
}
