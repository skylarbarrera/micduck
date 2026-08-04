# micduck

Fades your Mac's output volume down while you're dictating, and back up when you stop.

Built for the Monologue dictation app, but it keys off the microphone rather than any
particular app, so it works with anything triggered by a modifier key.

**It ignores meetings.** Zoom and Meet open the mic too, and ducking your audio for the
duration of a call is worse than not having the tool at all. See [How it decides](#how-it-decides).

```
17:47:02  duck 0.50 -> 0.07     17:47:05  restore -> 0.50
17:48:40  mic hot but no recent right-Option — assuming call, not ducking
```

## Install

```sh
git clone git@github.com:skylarbarrera/micduck.git
cd micduck
./install.sh                 # build + copy to ~/.local/bin
./install.sh --launchagent   # also start at login
```

Then grant Accessibility permission — **required**, see below.

Or just build in place:

```sh
make          # -> ./micduck
make test     # volume plumbing selftest, restores when done
```

No dependencies beyond the Xcode command line tools.

## Accessibility permission (read this on a new machine)

micduck needs Accessibility permission to watch for the right-Option key.

Run from a terminal, it silently inherits the terminal's grant, so it just works and you
may never realize permission was involved. **Under a LaunchAgent there's no parent to
inherit from**, so the binary needs its own entry:

> System Settings → Privacy & Security → Accessibility → **+** → `~/.local/bin/micduck`

`install.sh --launchagent` prints the exact path. Without it, micduck exits immediately at
login with an explanatory error — it fails loud rather than silently degrading into the
behavior you didn't want (ducking every call).

It does **not** need Microphone permission. It only reads whether the mic is busy, never
the audio.

## How it decides

Two signals have to agree before it ducks:

1. **Mic went live** — CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
   default input device. Event-driven, no polling.
2. **Right-Option fired within the last 2.5s** — a `.listenOnly` `CGEventTap`.

The key signal is a *gate*, not the trigger. That's deliberate: Monologue starts on either a
hold-and-release or a double-tap latch, and reimplementing that gesture detection would mean
guessing its thresholds and re-guessing them after every update. Instead the mic tells us
when recording actually starts, and the key only distinguishes "you started dictating" from
"a call started." Both of Monologue's modes work off the one rule, since both begin with
right-Option immediately before the mic opens.

The gate token is **one-shot** — consumed on use, so tapping off a hands-free session can't
leave a live token that authorizes an unrelated mic open seconds later.

Restore is ungated and fires on mic-off regardless, so a session always ends cleanly no
matter how long it ran.

## Options

| Flag | Default | |
|---|---|---|
| `--duck N` | `0.15` | Fade to this fraction of the pre-duck volume |
| `--down MS` | `250` | Fade-out duration |
| `--up MS` | `400` | Fade-in duration |
| `--gate-ms MS` | `2500` | How soon after the key the mic must open |
| `--gate-key N` | `61` | Keycode to watch (61 = right-Option) |
| `--no-gate` | off | Duck for **any** mic use, calls included |
| `--max-duck-ms MS` | `900000` | Watchdog ceiling on a single duck |
| `--selftest` | | Duck and restore once, verify, exit |
| `--verbose` | | Log every transition |

Using a different dictation hotkey? Pass its keycode to `--gate-key`.

## Won't leave your volume stuck

A daemon that quietly leaves you at 7% is worse than no daemon, so:

- Signal handlers on `INT`/`TERM`/`HUP` restore before exiting
- The pre-duck level is written to `~/.cache/micduck.restore`, so a crash-restart recovers it
- A generation counter aborts a stale fade if you retrigger mid-fade
- A watchdog restores if a mic-off event is ever missed (generous by default, because
  hands-free sessions legitimately run for minutes)
- Re-resolves the device if the default input changes — relevant when your input and output
  are different hardware, which move independently as headphones come and go

## Known limitation

**Adjusting the volume while ducked gets clobbered.** If it ducks 0.56 → 0.08 and you turn
it up to hear better, mic-off still restores 0.56. Fixable with a volume-change listener that
re-baselines when the observed level doesn't match what we last set; not done because the
simple version is right nearly all the time.

## Fades everything, not per-app

It moves the system output volume. Two finer-grained options exist if you ever want them:

- **Spotify** exposes `sound volume` over AppleScript and can be ducked independently.
- **Chrome** can set `video.volume` per tab via injected JS, but that needs
  *View → Developer → Allow JavaScript from Apple Events* toggled on by hand.

## Extras

- `micprobe.swift` — polls the mic flag on *every* input device and logs transitions. Reach
  for this first if ducking ever stops working; it separates "listener not firing" from
  "wrong device" from "app doesn't open the mic the normal way."
- `negtest.swift` — opens the mic for 5s with no keypress. Volume should not move. Audio is
  counted and discarded, nothing is written anywhere.

## License

MIT.
