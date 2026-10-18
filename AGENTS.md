# MIDIRecorder - Agent Guide

## Repo structure

Single-file macOS menu bar app. One source file: `MainApp.swift` (~420 lines). No SPM, no Xcode project, no tests.

## Build & run

```bash
./build.sh          # builds MIDIRecorder.app
open MIDIRecorder.app  # launch
```

Build script (`build.sh`) compiles with `swiftc -O` for arm64 and x86_64 (merged with `lipo` into a universal binary), assembles the `.app` bundle structure, generates icons from `AppIcon.svg`, writes `Info.plist`, and codesigns. It can run from any directory and keeps its temp files in a `mktemp -d` dir. The app is a **LSUIElement** (menu bar only, no Dock icon).

Signing: by default ad-hoc with the explicit requirement `designated => identifier "com.user.midirecorder"`, so the code hash does not decide identity. For a stable identity, run `SIGN_IDENTITY="<cert name>" ./build.sh` (see `security find-identity -v -p codesigning`).

## Constraints

- **Swift 6.1.2** - see `.swift-version`
- **macOS 13+** minimum deployment target (`MIN_MACOS` in build.sh; passed to `swiftc -target`, `actool`, and `LSMinimumSystemVersion`). Without `-target`, `swiftc` would default to the host OS version.
- No package manager - all frameworks (`SwiftUI`, `CoreMIDI`, `AudioToolbox`, `ServiceManagement`) are system frameworks linked via `-framework` flags
- Build artifacts (`.app/`, `AppIcon.appiconset/`, `Assets.xcassets/`) are gitignored

## Architecture notes

All code lives in `MainApp.swift`:
1. `MIDIRecorderApp` - `@main` entry point, delegates to `AppDelegate`
2. `AppDelegate` - manages status item + SwiftUI popover; holds the App Nap activity token; calls `engine.flush()` on quit
3. `MenuBarView` - UI (status indicator, note count, post-save command field, launch-at-login toggle)
4. `MIDIRecorderEngine` - singleton CoreMIDI backend; captures MIDI packets into a `MusicSequence`, auto-saves on 5s silence

Output files go to `~/Documents/MIDIRecorder/`.

### Engine threading

- All recording state (`currentSequence`, `currentTrack`, `sequenceStartTime`, `noteCount`, `silenceWork`) is owned by the serial `queue`. `liveNoteCount`, `lastSavedFilename` are UI state, written only on main.
- The CoreMIDI callback copies packets synchronously (the list is invalid after it returns), then hands them to `queue`.
- Silence timer is a `DispatchWorkItem` on `queue`. Never use `Timer` there: GCD threads have no RunLoop, so it never fires.
- `channelMessages` keeps only channel messages (0x80-0xEF). Clock, active sensing and SysEx must not start a take or reset the silence timer.
- Note-on/off are stored as raw channel events (real note lengths). Do not use `MusicTrackNewMIDINoteEvent`: it forces a fixed duration.
- Post-save command runs on a global queue, never on `queue` (a slow command would block recording and quit).

## Gotchas

- The output filename template `yyyy-MM-dd HHmm (EEEE) N notes, S seconds.mid` is relied on by external tooling. Do not change it, even though two same-minute, same-length, same-count takes overwrite each other.
- A failed save keeps the take in memory and shows `Save failed (<code>)` in the popover; the next silence retries.
- Quit saves the current take, but the post-save command is async and likely will not run for it.
- No tests and no way to send MIDI in CI. Verify by running the app with a real or virtual MIDI source.
- Editing `MainApp.swift` requires re-running `./build.sh` then reopening the app (no hot reload outside Xcode)
- Post-save shell commands use `%f` (full path) and `%n` (filename only) placeholders - executed via `/bin/sh -c`
- `actool` only emits a plist here (no `Assets.car`); the app icon comes from the `.icns` built by `iconutil`. The menu bar icon is `menuBar.png`, rendered at 36px for the 18pt size set in `AppDelegate`.
- If macOS re-asks for Documents access or Launch at Login approval after a rebuild, sign with `SIGN_IDENTITY` (a real certificate); the ad-hoc identifier requirement is not verified to satisfy TCC.
- Launch at Login uses `SMAppService`; changing it requires no rebuild, just toggle in-app
