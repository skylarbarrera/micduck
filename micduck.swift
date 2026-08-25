// micduck: fade system output volume down while the microphone is live, fade back when it stops.
//
// Trigger: CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere on the default *input*
// device. This flips whenever any process opens the mic, so it tracks Monologue's actual
// recording window without us having to reimplement its right-Option hold/double-press gesture.
//
// Build: swiftc -O -o micduck micduck.swift
// Run:   ./micduck [--duck 0.15] [--down 250] [--up 400] [--verbose]

import Foundation
import CoreAudio
import AudioToolbox
import CoreGraphics
import ApplicationServices

// ---------- config ----------

struct Config {
    var duckTo: Float = 0.15      // fraction of the pre-duck volume to fall to
    var downMs: Double = 250      // fade-out duration
    var upMs: Double = 400        // fade-in duration
    var verbose = false
    var selftest = false
    var gateKeyCodes: [Int64] = [61]  // kVK_RightOption; --gate-key accepts a comma list (61,54 = Monologue + Nix)
    var gateMs: Double = 2500      // mic must go hot within this long after a gate-key event
    var gated = true               // false => duck for *any* mic use (calls included)
    // Watchdog only exists to catch a missed MIC-OFF. Generous, because hands-free
    // (double-tap) dictation sessions can legitimately run for many minutes.
    var maxDuckMs: Double = 900_000
}

var cfg = Config()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--duck":    if let v = it.next(), let f = Float(v)  { cfg.duckTo = max(0, min(1, f)) }
        case "--down":    if let v = it.next(), let f = Double(v) { cfg.downMs = max(0, f) }
        case "--up":      if let v = it.next(), let f = Double(v) { cfg.upMs = max(0, f) }
        case "--verbose", "-v": cfg.verbose = true
        case "--selftest": cfg.selftest = true; cfg.verbose = true; cfg.gated = false
        case "--gate-ms": if let v = it.next(), let f = Double(v) { cfg.gateMs = max(0, f) }
        case "--gate-key":
            if let v = it.next() {
                let keys = v.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                if !keys.isEmpty { cfg.gateKeyCodes = keys }
            }
        case "--no-gate": cfg.gated = false
        case "--max-duck-ms": if let v = it.next(), let f = Double(v) { cfg.maxDuckMs = max(1000, f) }
        default: FileHandle.standardError.write("unknown arg: \(a)\n".data(using: .utf8)!); exit(2)
        }
    }
}

func log(_ s: String) {
    guard cfg.verbose else { return }
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)"); fflush(stdout)
}

// State file lets a restarted daemon recover a volume it left ducked.
let stateURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".cache/micduck.restore")

// ---------- device helpers ----------

func systemObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func defaultDevice(input: Bool) -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                         : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, &id) == noErr ? id : nil
}

func deviceName(_ dev: AudioDeviceID) -> String {
    var out: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &out) == noErr else { return "?" }
    return out?.takeRetainedValue() as String? ?? "?"
}

// ---------- output volume (main slider, with per-channel fallback) ----------

private func mainVolumeAddr() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
}

private func channelVolumeAddr(_ ch: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: ch)
}

// Last value we set ourselves, read back from the device so hardware quantization
// doesn't make our own write look like a user adjustment.
let lastSetLock = NSLock()
var lastSetVolume: Float? = nil

func getVolume(_ dev: AudioDeviceID) -> Float? {
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    var a = mainVolumeAddr()
    if AudioObjectHasProperty(dev, &a),
       AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return v }
    // Fallback: average whatever channels expose a scalar.
    var sum: Float = 0, n: Float = 0
    for ch in UInt32(1)...UInt32(2) {
        var ca = channelVolumeAddr(ch)
        var cv: Float32 = 0
        var csize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(dev, &ca),
           AudioObjectGetPropertyData(dev, &ca, 0, nil, &csize, &cv) == noErr { sum += cv; n += 1 }
    }
    return n > 0 ? sum / n : nil
}

@discardableResult
func setVolume(_ dev: AudioDeviceID, _ value: Float) -> Bool {
    var v = Float32(max(0, min(1, value)))
    let size = UInt32(MemoryLayout<Float32>.size)
    var wrote = false

    var a = mainVolumeAddr()
    var mainSettable = DarwinBoolean(false)
    if AudioObjectHasProperty(dev, &a),
       AudioObjectIsPropertySettable(dev, &a, &mainSettable) == noErr, mainSettable.boolValue,
       AudioObjectSetPropertyData(dev, &a, 0, nil, size, &v) == noErr {
        wrote = true
    }
    if !wrote {
        for ch in UInt32(1)...UInt32(2) {
            var ca = channelVolumeAddr(ch)
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(dev, &ca),
               AudioObjectIsPropertySettable(dev, &ca, &settable) == noErr, settable.boolValue,
               AudioObjectSetPropertyData(dev, &ca, 0, nil, size, &v) == noErr { wrote = true }
        }
    }

    // Remember what the device actually landed on, not what we asked for.
    if wrote {
        let actual = getVolume(dev) ?? Float(v)
        lastSetLock.lock(); lastSetVolume = actual; lastSetLock.unlock()
    }
    return wrote
}

// ---------- fade engine ----------

let work = DispatchQueue(label: "micduck.fade")
var generation = 0            // bumped on every new fade so stale steps abort
var savedVolume: Float? = nil // pre-duck volume, nil when not ducked

/// Smooth fade on `work`. Aborts if a newer fade supersedes it.
func fade(_ dev: AudioDeviceID, to target: Float, ms: Double, done: (() -> Void)? = nil) {
    generation += 1
    let gen = generation
    let from = getVolume(dev) ?? target
    let steps = max(1, Int(ms / 12.0))          // ~12ms per step
    if steps == 1 || abs(from - target) < 0.005 {
        setVolume(dev, target); done?(); return
    }
    for i in 1...steps {
        let t = Float(i) / Float(steps)
        // ease-in-out so the start and end are gentle
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let v = from + (target - from) * eased
        work.asyncAfter(deadline: .now() + .milliseconds(Int(Double(i) * 12))) {
            guard gen == generation else { return }
            setVolume(dev, v)
            if i == steps { done?() }
        }
    }
}

// ---------- mic state ----------

var runningAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

// ---------- right-Option gate ----------
//
// Monologue is triggered two ways: hold right-Option and release when done, or
// double-tap to latch it on hands-free until you tap again. Both begin with
// right-Option activity immediately before the mic opens, so a single rule covers
// them: only duck if the mic went hot shortly after a right-Option event. A Zoom
// or Meet call opens the mic with no such key event, so it never ducks.

let gateLock = NSLock()
var lastGateEventAt: Date? = nil

func noteGateKey() {
    gateLock.lock(); lastGateEventAt = Date(); gateLock.unlock()
}

/// True if a gate key fired recently. Consumes the token so it can't authorize a
/// second, unrelated mic open (e.g. tapping off hands-free then joining a call).
func consumeGateToken() -> Bool {
    guard cfg.gated else { return true }
    gateLock.lock(); defer { gateLock.unlock() }
    guard let t = lastGateEventAt else { return false }
    let age = Date().timeIntervalSince(t) * 1000
    guard age <= cfg.gateMs else { return false }
    lastGateEventAt = nil
    return true
}

var eventTap: CFMachPort? = nil

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged,
       cfg.gateKeyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
        noteGateKey()
    }
    return Unmanaged.passUnretained(event)
}

/// Installs a passive tap. `.listenOnly` guarantees we never modify or swallow the
/// event, so Monologue still receives right-Option exactly as before.
func installGateTap() -> Bool {
    let mask = (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: tapCallback,
        userInfo: nil) else { return false }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

func micIsHot(_ dev: AudioDeviceID) -> Bool {
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &runningAddr, 0, nil, &size, &v) == noErr && v != 0
}

var duckEpoch = 0   // bumped per duck so a stale watchdog can't fire

func duck() {
    guard let out = defaultDevice(input: false) else { return }
    guard savedVolume == nil else { log("already ducked"); return }
    guard consumeGateToken() else {
        log("mic hot but no recent right-Option: assuming call, not ducking")
        return
    }
    guard let cur = getVolume(out), cur > 0.01 else { log("output already silent"); return }
    savedVolume = cur
    duckEpoch += 1
    let epoch = duckEpoch
    try? String(cur).write(to: stateURL, atomically: true, encoding: .utf8)
    log(String(format: "duck %.2f -> %.2f on %@", cur, cur * cfg.duckTo, deviceName(out)))
    fade(out, to: cur * cfg.duckTo, ms: cfg.downMs)

    // Safety net for a MIC-OFF notification we somehow never receive.
    work.asyncAfter(deadline: .now() + .milliseconds(Int(cfg.maxDuckMs))) {
        guard epoch == duckEpoch, savedVolume != nil else { return }
        log("watchdog: ducked too long, restoring")
        restore()
    }
}

func restore() {
    guard let out = defaultDevice(input: false) else { return }
    guard let target = savedVolume else { return }
    savedVolume = nil
    duckEpoch += 1
    log(String(format: "restore -> %.2f", target))
    fade(out, to: target, ms: cfg.upMs) {
        try? FileManager.default.removeItem(at: stateURL)
    }
}

/// Stop managing the current duck without moving the volume. Used when the user takes
/// manual control, or when the output device changes and our saved level no longer
/// refers to the hardware we'd be restoring.
func abandonDuck(_ why: String) {
    guard savedVolume != nil else { return }
    savedVolume = nil
    duckEpoch += 1
    generation += 1   // cancel any fade still in flight
    try? FileManager.default.removeItem(at: stateURL)
    log("abandoning duck: \(why)")
}

// ---------- wiring ----------

guard var inDev = defaultDevice(input: true) else {
    FileHandle.standardError.write("no default input device\n".data(using: .utf8)!); exit(1)
}
let outDev = defaultDevice(input: false)

print("micduck: in=\(deviceName(inDev)) out=\(outDev.map(deviceName) ?? "?") "
      + "duck=\(cfg.duckTo) down=\(cfg.downMs)ms up=\(cfg.upMs)ms")
if let o = outDev, let v = getVolume(o) { print(String(format: "current output volume: %.2f", v)) }

// Recover a volume left ducked by a previous crash. Runs before the run loop starts,
// so there is nothing to race with yet.
if let s = try? String(contentsOf: stateURL, encoding: .utf8),
   let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
    if let o = outDev, !micIsHot(inDev) {
        log("recovering volume left ducked by a previous run -> \(v)")
        fade(o, to: v, ms: 200)
    }
    try? FileManager.default.removeItem(at: stateURL)
}

// While ducked, watch for the user moving the volume themselves (media keys, menu bar,
// Control Center). Their intent beats ours, so we stop managing that duck rather than
// snapping them back on mic-off. Compares against the value we last wrote, so our own
// fade steps aren't mistaken for manual input.
let manualEpsilon: Float = 0.02
var volumeListenerDevice: AudioDeviceID? = nil

func attachVolumeListener(_ dev: AudioDeviceID) {
    guard volumeListenerDevice != dev else { return }
    var a = mainVolumeAddr()
    guard AudioObjectHasProperty(dev, &a) else { return }
    let err = AudioObjectAddPropertyListenerBlock(dev, &a, work) { _, _ in
        guard savedVolume != nil else { return }
        guard let observed = getVolume(dev) else { return }
        lastSetLock.lock(); let ours = lastSetVolume; lastSetLock.unlock()
        guard let ours else { return }
        if abs(observed - ours) > manualEpsilon {
            abandonDuck(String(format: "volume moved to %.2f by hand (we set %.2f)", observed, ours))
        }
    }
    if err == noErr { volumeListenerDevice = dev; log("volume listener on \(deviceName(dev))") }
}
if let o = outDev { attachVolumeListener(o) }

// If the output device changes mid-duck, our saved level belongs to the old hardware.
var defOutAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(systemObject(), &defOutAddr, work) { _, _ in
    guard let newOut = defaultDevice(input: false), newOut != volumeListenerDevice else { return }
    log("default output changed -> \(deviceName(newOut))")
    abandonDuck("output device changed")
    volumeListenerDevice = nil
    attachVolumeListener(newOut)
}

// Fail loudly rather than silently degrading to ducking every call.
if cfg.gated && !cfg.selftest {
    // Check trust separately from the tap. CGEventTapCreate can hand back a live tap that
    // never receives an event, so the tap succeeding is not proof we're authorized. That
    // gap opens every time the binary is replaced: an ad-hoc signature pins the grant to
    // the exact cdhash, so a rebuild silently invalidates it while the old entry still
    // shows as checked in System Settings.
    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write("""
        micduck: not trusted for Accessibility, so the right-Option gate can never arm.
          This usually means the binary was rebuilt: an ad-hoc signature ties the grant to
          the exact binary, so replacing it invalidates the old grant even though the entry
          still looks enabled.
          Fix: System Settings > Privacy & Security > Accessibility, remove the old entry,
          then re-add:
          \(CommandLine.arguments[0])
          To stop this recurring on every rebuild, run ./sign-setup.sh once.
        Re-run with --no-gate to duck on ANY mic use (calls included).\n
        """.data(using: .utf8)!)
        exit(1)
    }
    if installGateTap() {
        print("gate: keycodes \(cfg.gateKeyCodes.map(String.init).joined(separator: ",")), window \(Int(cfg.gateMs))ms")
    } else {
        FileHandle.standardError.write("""
        micduck: could not create the event tap. This binary needs Accessibility permission.
          System Settings > Privacy & Security > Accessibility, and add:
          \(CommandLine.arguments[0])
        Re-run with --no-gate to duck on ANY mic use (calls included).\n
        """.data(using: .utf8)!)
        exit(1)
    }
} else if !cfg.gated {
    print("gate: DISABLED, will duck for any mic use, including calls")
}

var listening = false
func attachMicListener() {
    guard !listening else { return }
    let dev = inDev
    let err = AudioObjectAddPropertyListenerBlock(dev, &runningAddr, work) { _, _ in
        micIsHot(dev) ? duck() : restore()
    }
    listening = (err == noErr)
    log("listener on \(deviceName(dev)): \(listening ? "ok" : "err \(err)")")
}
attachMicListener()

// If the default input device changes (AirPods in/out), move the listener.
var defInAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(systemObject(), &defInAddr, work) { _, _ in
    guard let newDev = defaultDevice(input: true), newDev != inDev else { return }
    log("default input changed -> \(deviceName(newDev))")
    inDev = newDev
    listening = false
    attachMicListener()
}

// Never leave the volume down if we're killed.
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        if let out = defaultDevice(input: false), let v = savedVolume { setVolume(out, v) }
        try? FileManager.default.removeItem(at: stateURL)
        exit(0)
    }
}

if cfg.selftest {
    // Prove the volume plumbing + fade engine work, then put everything back.
    guard let o = outDev else { print("selftest: no output device"); exit(1) }
    let before = getVolume(o) ?? -1
    print(String(format: "selftest: before=%.3f", before))
    // Everything that mutates duck state runs on `work`, so this does too.
    work.async { duck() }
    work.asyncAfter(deadline: .now() + .milliseconds(Int(cfg.downMs) + 120)) {
        let low = getVolume(o) ?? -1
        print(String(format: "selftest: ducked=%.3f (expected ~%.3f)", low, before * cfg.duckTo))
        restore()
        work.asyncAfter(deadline: .now() + .milliseconds(Int(cfg.upMs) + 250)) {
            let after = getVolume(o) ?? -1
            let ok = abs(after - before) < 0.02 && low < before - 0.02
            print(String(format: "selftest: after=%.3f  %@", after, ok ? "PASS" : "FAIL"))
            exit(ok ? 0 : 1)
        }
    }
    RunLoop.main.run()
}

if micIsHot(inDev) { log("mic already hot at launch"); duck() }
RunLoop.main.run()
