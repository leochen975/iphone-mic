#!/usr/bin/env swift
//
// bh_player.swift
//
// Stream 16-bit signed little-endian mono PCM from stdin to a macOS audio
// output device (by default BlackHole 2ch). The player duplicates the mono
// signal to both channels and converts it to the device's Float32 format.
//
// Usage:
//   bh_player [--uid <device-uid>] [--rate <sample-rate>]
//
// Defaults:
//   --uid  BlackHole2ch_UID
//   --rate 44100
//

import Foundation
import AudioToolbox
import CoreAudio

// MARK: - Configuration

let defaultDeviceUID = "BlackHole2ch_UID"
let defaultSampleRate: Float64 = 44100.0
let outputChannelCount: UInt32 = 2

var deviceUID = defaultDeviceUID
var sampleRate = defaultSampleRate

var remainingArgs = Array(CommandLine.arguments.dropFirst())
var idx = 0
while idx < remainingArgs.count {
    let arg = remainingArgs[idx]
    switch arg {
    case "--uid":
        if idx + 1 < remainingArgs.count {
            deviceUID = remainingArgs[idx + 1]
            idx += 1
        }
    case "--rate":
        if idx + 1 < remainingArgs.count, let value = Float64(remainingArgs[idx + 1]) {
            sampleRate = value
            idx += 1
        }
    case "--help", "-h":
        print("Usage: bh_player [--uid <device-uid>] [--rate <sample-rate>]")
        exit(0)
    default:
        break
    }
    idx += 1
}

// MARK: - Thread-safe ring buffer (mono Float32 samples)

final class RingBuffer {
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private let lock = NSLock()

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(capacity, 1))
    }

    var availableCount: Int {
        lock.lock(); defer { lock.unlock() }
        return (writeIndex - readIndex + storage.count) % storage.count
    }

    @discardableResult
    func push(_ values: [Float]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var written = 0
        for value in values {
            let next = (writeIndex + 1) % storage.count
            if next == readIndex { break } // buffer is full
            storage[writeIndex] = value
            writeIndex = next
            written += 1
        }
        return written
    }

    func pop(_ values: inout [Float]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var read = 0
        while read < values.count && readIndex != writeIndex {
            values[read] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
            read += 1
        }
        return read
    }
}

// MARK: - Audio device lookup

func findDevice(uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size) == noErr else { return nil }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &devices) == noErr else { return nil }

    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    for device in devices {
        var uidRef: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uidRef)
        if (uidRef?.takeRetainedValue() as String?) == uid {
            return device
        }
    }
    return nil
}

func check(_ status: OSStatus, _ message: String) throws {
    if status != noErr {
        throw NSError(
            domain: "bh_player",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message) failed: \(status)"])
    }
}

// MARK: - Main

guard let deviceID = findDevice(uid: deviceUID) else {
    FileHandle.standardError.write("Error: audio device with UID '\(deviceUID)' not found\n".data(using: .utf8)!)
    exit(1)
}

// Prefer the device to run at the incoming sample rate so no resampling happens.
do {
    var rate = sampleRate
    var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectSetPropertyData(
        deviceID, &rateAddress, 0, nil,
        UInt32(MemoryLayout<Float64>.size), &rate)
    if status == noErr {
        FileHandle.standardError.write("Set '\(deviceUID)' sample rate to \(sampleRate) Hz\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("Warning: could not set sample rate (\(status))\n".data(using: .utf8)!)
    }
}

// About two seconds of mono audio.
let ringBuffer = RingBuffer(capacity: Int(sampleRate) * 2)

var outputUnit: AudioUnit?
var componentDescription = AudioComponentDescription()
componentDescription.componentType = kAudioUnitType_Output
componentDescription.componentSubType = kAudioUnitSubType_HALOutput
componentDescription.componentManufacturer = kAudioUnitManufacturer_Apple
componentDescription.componentFlags = 0
componentDescription.componentFlagsMask = 0

guard let component = AudioComponentFindNext(nil, &componentDescription) else {
    FileHandle.standardError.write("Error: HAL output audio unit not found\n".data(using: .utf8)!)
    exit(1)
}

do {
    try check(AudioComponentInstanceNew(component, &outputUnit), "AudioComponentInstanceNew")
    guard let unit = outputUnit else { throw NSError(domain: "bh_player", code: -1) }

    var enableOutput: UInt32 = 1
    try check(AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output, 0, &enableOutput,
        UInt32(MemoryLayout<UInt32>.size)), "EnableIO output")

    var currentDevice = deviceID
    try check(AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &currentDevice,
        UInt32(MemoryLayout<AudioDeviceID>.size)), "CurrentDevice")

    var streamFormat = AudioStreamBasicDescription()
    streamFormat.mSampleRate = sampleRate
    streamFormat.mFormatID = kAudioFormatLinearPCM
    streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    streamFormat.mBytesPerPacket = outputChannelCount * 4
    streamFormat.mFramesPerPacket = 1
    streamFormat.mBytesPerFrame = outputChannelCount * 4
    streamFormat.mChannelsPerFrame = outputChannelCount
    streamFormat.mBitsPerChannel = 32
    try check(AudioUnitSetProperty(
        unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &streamFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "StreamFormat")

    var renderCallback = AURenderCallbackStruct(
        inputProc: { (
            inRefCon: UnsafeMutableRawPointer,
            _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            _: UnsafePointer<AudioTimeStamp>,
            _: UInt32,
            inNumberFrames: UInt32,
            ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in

            let buffer = Unmanaged<RingBuffer>.fromOpaque(inRefCon).takeUnretainedValue()
            let frames = Int(inNumberFrames)
            var mono = [Float](repeating: 0, count: frames)
            let read = buffer.pop(&mono)

            guard let ioData = ioData else { return noErr }
            let audioBufferList = UnsafeMutableAudioBufferListPointer(ioData)
            for audioBuffer in audioBufferList {
                guard let rawData = audioBuffer.mData else { continue }
                let output = rawData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let sample = frame < read ? mono[frame] : 0
                    output[frame * 2] = sample
                    output[frame * 2 + 1] = sample
                }
            }
            return noErr
        },
        inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(ringBuffer).toOpaque()))

    try check(AudioUnitSetProperty(
        unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &renderCallback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback")

    try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
    try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
} catch {
    FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

FileHandle.standardError.write("Streaming stdin PCM to '\(deviceUID)' at \(sampleRate) Hz\n".data(using: .utf8)!)

// MARK: - stdin reader

let stdinHandle = FileHandle.standardInput
var pendingBytes = [UInt8]()

while true {
    let data = stdinHandle.readData(ofLength: 8192)
    if data.isEmpty { break } // EOF from parent

    var bytes = [UInt8](data)
    if !pendingBytes.isEmpty {
        bytes = pendingBytes + bytes
        pendingBytes = []
    }

    var samples = [Float]()
    samples.reserveCapacity(bytes.count / 2)
    var i = 0
    while i + 1 < bytes.count {
        let low = UInt16(bytes[i])
        let high = UInt16(bytes[i + 1])
        let value = Int16(bitPattern: low | (high << 8))
        samples.append(Float(value) / 32768.0)
        i += 2
    }
    if i < bytes.count {
        pendingBytes = Array(bytes[i...])
    }

    ringBuffer.push(samples)

    // Backpressure: keep the buffer under about one second of audio.
    while ringBuffer.availableCount > Int(sampleRate) {
        usleep(10_000)
    }
}

// Drain what is left before stopping.
while ringBuffer.availableCount > 0 {
    usleep(50_000)
}

if let unit = outputUnit {
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
}
FileHandle.standardError.write("bh_player stopped\n".data(using: .utf8)!)
