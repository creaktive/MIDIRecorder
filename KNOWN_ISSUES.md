# Known issues

Found in the 2026-10-18 audit. Not fixed yet. Each item was reproduced unless noted.

## Should fix

### 1. `killall` loses the take in progress (`MainApp.swift`, `applicationWillTerminate`)

`kill` and `killall MIDIRecorder` send SIGTERM. AppKit does not turn that into a normal quit, so `applicationWillTerminate` (and `engine.flush()`) never runs. Up to 30 min of playing is lost. Crash, force quit and power loss also lose the take.

Fix: in `applicationDidFinishLaunching`, with `private var termSource: DispatchSourceSignal?`:

```swift
signal(SIGTERM, SIG_IGN)
termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource?.setEventHandler { NSApp.terminate(nil) }
termSource?.resume()
```

Tested in a probe: callback ran, exit 0.

### 2. A failed build deletes the working app (`build.sh`)

`build.sh` deletes `MIDIRecorder.app` first, then compiles. A Swift error leaves a hollow bundle (empty `MacOS/`, no `Info.plist`). Launch at Login points at that path.

Fix: build in the temp dir, move at the end. Replace `BUNDLE_DIR="${APP_NAME}.app"` with `FINAL="${APP_NAME}.app"`. Add `BUNDLE_DIR="$T/$FINAL"` after `T=$(mktemp -d)`. Replace the last `touch "$BUNDLE_DIR"` with `rm -rf "$FINAL"; mv "$BUNDLE_DIR" "$FINAL"; touch "$FINAL"`. Tested: failing build keeps old app, signature valid after the move.

### 3. Take logic and file name have no test

Only `ChannelParser` is tested. The pause filter, 30-min cut, held-note close, save retry and the file name format (used by outside tools) have no test. `AGENTS.md` says MIDI cannot be sent in CI; it can: a virtual source (`MIDISourceCreate` + `MIDIReceived`) needs no hardware.

Fix: move `MIDIRecorderEngine` to `Engine.swift` (pure move). Give `init` the parameters `outputDirectory`, `silenceInterval`, `maxTakeSeconds` with today's values as defaults. Add a test that sends notes through a virtual source, reads the `.mid` back, and asserts note count, tick times and the name pattern. Smaller first step: pull the name lines into `takeFilename(start:notes:seconds:)` and assert the README example.

### 4. Errors go to `print`, which nobody sees (`MainApp.swift`)

Seven failure paths use `print`. Started at login there is no terminal. The only trace is the last error in the popover, replaced by the next save.

Fix: `NSLog("%@", "...")` instead of `print("...")`.

## Nice to have

### 5. Pause flag is copied on the wrong thread

`didSet { queue.async { self.pausedOnQueue = self.isPaused } }` reads `isPaused` inside the queue block while main may write it. No wrong result today (a Bool cannot tear), but it is a data race.

Fix: `didSet { let paused = isPaused; queue.async { self.pausedOnQueue = paused } }`.

### 6. One text field carries every message

`lastSavedFilename` holds the last file name and every error. A failing post-save can replace the name of a newer take. `saveCurrentSequenceAndReset` has a local `let liveNoteCount` that hides the UI property of the same name.

Fix: one `private func show(_ text: String)` that does the `DispatchQueue.main.async` write, used at the four places that write it. Rename the local to `notes`. About -8 lines.

### 7. Smaller items

- Return codes of `NewMusicSequence`, `MusicSequenceNewTrack` and `MusicTrackNewMIDIChannelEvent` are ignored.
- Sustain pedal and program state is neither carried into the next take nor released at the end of one.
- The post-save shell gets macOS's short `PATH`; Homebrew tools need full paths.
- When a failing save is older than the 30-min cap, every MIDI message retries the whole save. Throttle the cut to once per 5 s.

## Documented decisions (not issues)

- Same-minute, same-length, same-count takes overwrite each other (file name template is fixed).
- The post-save command is async and likely does not run for the take saved on quit.
