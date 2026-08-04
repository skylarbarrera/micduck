# micduck

Fades your Mac's output volume down while you're dictating, and back up when you stop.

Built for [Monologue](https://www.monologue.to/), but it watches the microphone, not any app,
so it works with anything you trigger off a modifier key.

```
17:47:02  duck 0.50 -> 0.07     17:47:05  restore -> 0.50
17:48:40  mic hot but no recent right-Option: assuming call, not ducking
```

## How it decides

It ignores meetings. Zoom and Meet open the mic too, and ducking a whole call is worse than no
tool at all. So two things have to be true before it ducks:

1. The mic went live. CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`,
   event-driven, no polling.
2. Right-Option fired in the last 2.5s. A `.listenOnly` `CGEventTap`.

The key is a gate, not the trigger. Monologue starts on either a hold-and-release or a
double-tap latch, and reimplementing that gesture would mean guessing its thresholds and
guessing again after every update. The mic says when recording actually starts. The key only
separates dictation from a call.

The gate token is one-shot, so ending a hands-free session can't leave a live token that
authorizes an unrelated mic open later. Restore is ungated and fires on mic-off regardless.

## Install

```sh
./install.sh                 # build + copy to ~/.local/bin
./install.sh --launchagent   # also start it at login
```

Then add `~/.local/bin/micduck` under System Settings > Privacy & Security > Accessibility.
From a terminal it inherits the terminal's grant; a LaunchAgent has no parent to inherit from,
so without it micduck exits at login with a permission error.

## Options

| Flag | Default | |
|---|---|---|
| `--duck N` | `0.15` | Fade to this fraction of the pre-duck volume |
| `--down MS` | `250` | Fade-out duration |
| `--up MS` | `400` | Fade-in duration |
| `--gate-ms MS` | `2500` | How soon after the key the mic must open |
| `--gate-key N` | `61` | Keycode to watch (61 = right-Option) |
| `--no-gate` | off | Duck for any mic use, calls included |
| `--max-duck-ms MS` | `900000` | Watchdog ceiling on a single duck |
| `--selftest` | | Duck and restore once, verify, exit |
| `--verbose` | | Log every transition |

## Notes

It won't leave your volume stuck. Signal handlers restore on exit, the pre-duck level is
written to `~/.cache/micduck.restore` so a crash-restart recovers it, and a watchdog covers a
missed mic-off. Grab the volume by hand mid-duck and it backs off instead of snapping you back
down. Same if the output device changes.

The keyboard tap subscribes to `flagsChanged` only, so `keyDown` and `keyUp` never reach the
process. It reads one integer per event, the keycode, and timestamps a match. There's no
networking in the repo. It doesn't need Microphone permission, only whether the mic is busy.

`micprobe.swift` logs mic transitions on every input device if ducking stops working.
`negtest.swift` opens the mic with no keypress; the volume should not move.

macOS 12+, tested on 26. MIT.
