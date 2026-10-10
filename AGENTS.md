# MIDIRecorder — Agent Guide

## Repo structure

Single-file macOS menu bar app. One source file: `MainApp.swift` (376 lines). No SPM, no Xcode project, no tests.

## Build & run

```bash
./build.sh          # builds MIDIRecorder.app
open MIDIRecorder.app  # launch
```

Build script (`build.sh`) compiles with `swiftc -O`, assembles the `.app` bundle structure, generates icons from `AppIcon.svg`, writes `Info.plist`, and codesigns. The app is a **LSUIElement** (menu bar only, no Dock icon).

## Constraints

- **Swift 6.1.2** — see `.swift-version`
- **macOS 13+** minimum deployment target (hardcoded in build.sh)
- No package manager — all frameworks (`SwiftUI`, `CoreMIDI`, `AudioToolbox`, `ServiceManagement`) are system frameworks linked via `-framework` flags
- Build artifacts (`.app/`, `AppIcon.appiconset/`, `Assets.xcassets/`) are gitignored

## Architecture notes

All code lives in `MainApp.swift`:
1. `MIDIRecorderApp` — `@main` entry point, delegates to `AppDelegate`
2. `AppDelegate` — manages status item + SwiftUI popover
3. `MenuBarView` — UI (status indicator, note count, post-save command field, launch-at-login toggle)
4. `MIDIRecorderEngine` — singleton CoreMIDI backend; captures MIDI packets into a `MusicSequence`, auto-saves on 5s silence

Output files go to `~/Documents/MIDIRecorder/`.

## Gotchas

- Editing `MainApp.swift` requires re-running `./build.sh` then reopening the app (no hot reload outside Xcode)
- Post-save shell commands use `%f` (full path) and `%n` (filename only) placeholders — executed via `/bin/sh -c`
- Launch at Login uses `SMAppService`; changing it requires no rebuild, just toggle in-app
