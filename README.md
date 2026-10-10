# MIDIRecorder

![MIDIRecorder](AppIcon.svg)

macOS menu bar app that automatically captures live MIDI into `.mid` files.

## How it works

Inspired by Pianoteq's recording workflow, MIDIRecorder listens to all connected MIDI sources and records note/channel events into a `MusicSequence`. After **5 seconds of silence**, the current sequence is saved as a standard MIDI file and a new recording session begins automatically.

## Build & run

```bash
./build.sh          # builds MIDIRecorder.app
open MIDIRecorder.app  # launch
```

The app runs as a menu bar item (no Dock icon) with a piano keys icon. Click the icon to open the control popover.

## Features

- **Automatic recording**: captures all incoming MIDI from every connected source
- **Auto-save on silence**: saves after 5 seconds of no input, then starts a new file
- **Live metrics**: shows note count and last saved filename in the menu bar
- **Post-save shell command**: run any command after each save (use `%f` for full path, `%n` for filename)
- **Launch at Login**: toggle from the popover without editing config files

## Output

MIDI files are saved to `~/Documents/MIDIRecorder/` with names following the format:

```
yyyy-MM-dd HHmm (EEEE) NNN notes, SS seconds.mid
```

Example: `2026-10-10 1430 (Saturday) 47 notes, 12 seconds.mid`

## Requirements

- macOS 13+
- Swift 5.9+ (compiled via `swiftc`)
