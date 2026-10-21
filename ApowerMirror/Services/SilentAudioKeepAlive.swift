//
//  SilentAudioKeepAlive.swift
//  ApowerMirror / Services
//
//  Background Keepalive & Audio Graph Priming Engine:
//  Plays an inaudible, low-level dithered PCM audio loop using AVAudioPlayer with
//  AVAudioSession category .playback and .mixWithOthers.
//  This serves two critical roles:
//  1. Prevents iOS from suspending the Main App when minimized to the Home screen
//     or when another app (YouTube, Spotify) is opened.
//  2. Actively primes the iOS CoreAudio render graph from the moment broadcast starts,
//     ensuring ReplayKit's daemon (replayd) hooks into the system audio output tap
//     and reliably delivers .audioApp sample buffers even when external audio starts late.
//

import Foundation
import AVFoundation

public final class SilentAudioKeepAlive {

    public static let shared = SilentAudioKeepAlive()

    private var audioPlayer: AVAudioPlayer?
    private var isPlaying = false
    private let lock = NSLock()

    private init() {
        setupInterruptionObserver()
        prepareSilentPlayer()
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            if type == .ended {
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        NSLog("[SilentAudioKeepAlive] Interruption ended with shouldResume -> Resuming silent audio player")
                        self?.resumeIfPlaying()
                    }
                } else {
                    self?.resumeIfPlaying()
                }
            }
        }
    }

    private func resumeIfPlaying() {
        lock.lock()
        let shouldPlay = isPlaying
        lock.unlock()
        if shouldPlay {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.mixWithOthers])
                try session.setActive(true)
                audioPlayer?.play()
                NSLog("[SilentAudioKeepAlive] Resumed silent audio loop after interruption")
            } catch {
                NSLog("[SilentAudioKeepAlive] Failed to resume audio session: %@", error.localizedDescription)
            }
        }
    }

    private func prepareSilentPlayer() {
        // Generate a 3-second 44.1kHz 16-bit stereo WAV with low-level LSB dither (alternating +1 and -1).
        // Amplitude: 1 out of 32767 = -90.3 dBFS.
        // This is completely imperceptible to human ears, but tricks CoreAudio's silence
        // detector into keeping the audio hardware graph and replayd tap active.
        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let durationSec: UInt32 = 3
        let numFrames = sampleRate * durationSec
        let dataBytes = numFrames * UInt32(channels) * UInt32(bitsPerSample / 8)
        let riffSize = dataBytes + 36

        var data = Data(capacity: Int(dataBytes + 44))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        let subchunk1Size: UInt32 = 16
        data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Array($0) })
        let audioFormat: UInt16 = 1 // PCM
        data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // "data" chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataBytes.littleEndian) { Array($0) })

        // 3 seconds of alternating +1, -1 dithered samples for L and R channels
        let pos1: Int16 = 1
        let neg1: Int16 = -1
        let posBytes = withUnsafeBytes(of: pos1.littleEndian) { Array($0) }
        let negBytes = withUnsafeBytes(of: neg1.littleEndian) { Array($0) }

        for i in 0..<numFrames {
            if i % 2 == 0 {
                data.append(contentsOf: posBytes) // Left
                data.append(contentsOf: posBytes) // Right
            } else {
                data.append(contentsOf: negBytes) // Left
                data.append(contentsOf: negBytes) // Right
            }
        }

        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1 // Infinite loop
            player.volume = 1.0       // Non-zero amplitude ensures active CoreAudio render graph
            player.prepareToPlay()
            self.audioPlayer = player
            NSLog("[SilentAudioKeepAlive] Initialized 3-second dithered silent audio player (%d bytes)", data.count)
        } catch {
            NSLog("[SilentAudioKeepAlive] Failed to initialize silent audio player: %@", error.localizedDescription)
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPlaying else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            audioPlayer?.play()
            isPlaying = true
            NSLog("[SilentAudioKeepAlive] Silent audio loop started -> CoreAudio graph primed & continuous background active")
        } catch {
            NSLog("[SilentAudioKeepAlive] Failed to activate audio session: %@", error.localizedDescription)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isPlaying else { return }
        audioPlayer?.pause()
        isPlaying = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            NSLog("[SilentAudioKeepAlive] Silent audio loop stopped")
        } catch {
            NSLog("[SilentAudioKeepAlive] Failed to deactivate audio session: %@", error.localizedDescription)
        }
    }
}
