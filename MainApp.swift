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

    @Published var isPaused: Bool = false
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
            }
        }
    }

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    private var currentSequence: MusicSequence?
    private var currentTrack: MusicTrack?
    private var sequenceStartTime: Date?

    private var silenceWork: DispatchWorkItem?
    private var noteCount = 0
    private let silenceInterval: TimeInterval = 5.0
    private let outputDirectory: URL

    private let queue = DispatchQueue(label: "com.midi.recorder.queue")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        outputDirectory = docs.appendingPathComponent("MIDIRecorder")

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
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
                let watermark = "MIDIRecorder"
                let dataBytes = Array(watermark.utf8)
                let size = MemoryLayout<MIDIMetaEvent>.size + dataBytes.count
                let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { mem.deallocate() }
                var status: OSStatus = -1
                mem.withMemoryRebound(to: MIDIMetaEvent.self, capacity: 1) { ptr in
                    ptr.pointee.metaEventType = 0x02
                    ptr.pointee.dataLength = UInt32(dataBytes.count)
                    memcpy(
                        UnsafeMutableRawPointer(ptr).advanced(by: MemoryLayout<MIDIMetaEvent>.size),
                        dataBytes,
                        dataBytes.count,
                    )
                    status = MusicTrackNewMetaEvent(track, 0, ptr)
                }
                if status != noErr {
                    print("Failed to add watermark meta-event: \(status)")
                }
            }
        }
        sequenceStartTime = nil
        noteCount = 0
        DispatchQueue.main.async {
            self.liveNoteCount = 0
        }
    }

    private func handleIncomingMIDIPackets(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        // Copy every packet now: the list is only valid during this callback.
        let packets = packetListPtr.unsafeSequence().map { $0.pointee }
        let now = Date()
        let paused = isPaused

        queue.async { [weak self] in
            guard let self else { return }

            var messages = packets.flatMap(Self.channelMessages)
            if paused {
                // Still close notes opened before the pause, but never start a take.
                messages = messages.filter(Self.isNoteOff)
                if sequenceStartTime == nil { return }
            }
            // Clock, active sensing and SysEx carry no channel messages: they must not start a take or reset the silence timer.
            guard !messages.isEmpty else { return }

            if sequenceStartTime == nil {
                sequenceStartTime = now
            }
            guard let startTime = sequenceStartTime, let track = currentTrack else { return }

            let timeInBeats = MusicTimeStamp(now.timeIntervalSince(startTime) * 2.0)
            for var message in messages {
                MusicTrackNewMIDIChannelEvent(track, timeInBeats, &message)
                if message.status & 0xF0 == 0x90, message.data2 > 0 {
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

    /// Splits a packet into channel messages; skips real-time bytes, SysEx and truncated messages.
    private static func channelMessages(_ packet: MIDIPacket) -> [MIDIChannelMessage] {
        let length = Int(packet.length)
        return withUnsafeBytes(of: packet.data) { raw in
            var out: [MIDIChannelMessage] = []
            var i = 0
            while i < length {
                let status = raw[i]
                guard status >= 0x80, status < 0xF0 else { i += 1; continue }
                let size = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 2 : 3
                guard i + size <= length else { break }
                out.append(MIDIChannelMessage(status: status, data1: raw[i + 1], data2: size == 3 ? raw[i + 2] : 0, reserved: 0))
                i += size
            }
            return out
        }
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

        let durationInSeconds = Int(Date().timeIntervalSince(startTime))
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HHmm (EEEE)"
        let dateString = dateFormatter.string(from: startTime)

        let filename = "\(dateString) \(liveNoteCount) notes, \(durationInSeconds) seconds.mid"
        let localFileURL = outputDirectory.appendingPathComponent(filename)

        let status = MusicSequenceFileCreate(sequence, localFileURL as CFURL, .midiType, [.eraseFile], 0)

        guard status == noErr else {
            // Keep the take in memory; the next silence retries.
            print("Failed to save \(filename): \(status)")
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
                }
            } catch {
                print("Failed to run post-save command: \(error.localizedDescription)")
            }
        }
    }
}
