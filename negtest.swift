// Negative gate test: open the microphone WITHOUT any right-Option press, hold it
// for a few seconds, then close. Audio is counted and discarded. Nothing is buffered
// to disk. micduck should log "assuming call, not ducking" and leave volume alone.
// Build: swiftc -O -o negtest negtest.swift ; Run: ./negtest
import Foundation
import AVFoundation

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.inputFormat(forBus: 0)
print("input format: \(fmt.sampleRate)Hz \(fmt.channelCount)ch")

var frames = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
    frames += Int(buf.frameLength)   // discarded immediately; nothing retained
}

do {
    try engine.start()
} catch {
    print("engine start failed: \(error.localizedDescription)")
    print("(if this is a permissions error, the parent terminal needs Microphone access)")
    exit(1)
}

print("mic OPEN (no right-Option pressed), holding 5s...")
fflush(stdout)
Thread.sleep(forTimeInterval: 5.0)
engine.stop()
input.removeTap(onBus: 0)
print("mic CLOSED: saw \(frames) frames, all discarded")
