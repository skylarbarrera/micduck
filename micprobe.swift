// Diagnostic: poll the is-running flag on EVERY input-capable device, not just the
// default one, and log transitions. Answers two questions the daemon log can't:
//   1. Does the flag move at all when Monologue records?
//   2. If it does, is it on the *default* input device or some other one?
// Build: swiftc -O -o micprobe micprobe.swift ; Run: ./micprobe
import Foundation
import CoreAudio

func allDevices() -> [AudioDeviceID] {
    var size = UInt32(0)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func name(_ dev: AudioDeviceID) -> String {
    var out: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &out) == noErr else { return "?" }
    return out?.takeRetainedValue() as String? ?? "?"
}

func hasInput(_ dev: AudioDeviceID) -> Bool {
    var size = UInt32(0)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
    return size > 0
}

func isHot(_ dev: AudioDeviceID) -> Bool {
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr && v != 0
}

func defaultInput() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

let inputs = allDevices().filter(hasInput)
print("watching \(inputs.count) input device(s), polling 200ms:")
for d in inputs {
    print("  [\(d)] \(name(d))\(d == defaultInput() ? "  <- default" : "")  hot=\(isHot(d))")
}
print("--- press right-Option and dictate; transitions print below ---")
fflush(stdout)

var prev = [AudioDeviceID: Bool]()
for d in inputs { prev[d] = isHot(d) }
let fmt = ISO8601DateFormatter()

while true {
    let def = defaultInput()
    for d in inputs {
        let now = isHot(d)
        if now != (prev[d] ?? false) {
            print("\(fmt.string(from: Date()))  [\(d)] \(name(d)) -> \(now ? "HOT" : "cold")"
                  + "\(d == def ? "  (is default)" : "  (NOT default)")")
            fflush(stdout)
            prev[d] = now
        }
    }
    usleep(200_000)
}
