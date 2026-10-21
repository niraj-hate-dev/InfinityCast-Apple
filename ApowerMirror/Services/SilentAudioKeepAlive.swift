//
//  SilentAudioKeepAlive.swift
//  ApowerMirror / Services
//
//  Background Keepalive Engine:
//  Plays an inaudible, zero-volume silent audio loop using AVAudioPlayer with
//  AVAudioSession category .playback and .mixWithOthers.
//  This prevents iOS from suspending the Main App when minimized to the Home screen
//  during live ReplayKit screen mirroring sessions, keeping internal socket servers
//  (Port 8889 and Port 25335) actively processing packets without sleep or throttling.
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
                try session.setCategory(.playback, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
                try session.setActive(true)
                audioPlayer?.play()
                NSLog("[SilentAudioKeepAlive] Resumed silent audio loop after interruption")
            } catch {
                NSLog("[SilentAudioKeepAlive] Failed to resume audio session: %@", error.localizedDescription)
            }
        }
    }

    private func prepareSilentPlayer() {
        // Generate a 1-second standard 44.1kHz 16-bit stereo PCM WAV file with pure zero silence.
        // Pure silence ensures zero audible noise (no old TV high-frequency whine or static hiss).
        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let durationSec: UInt32 = 1
        let numFrames = sampleRate * durationSec
        let dataBytes = numFrames * UInt32(channels) * UInt32(bitsPerSample / 8) // 176,400 bytes
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

        // 176,400 bytes of pure zero PCM silence (no tone, no whine, no TV static)
        data.append(Data(repeating: 0, count: Int(dataBytes)))

        // Persist to temporary file to guarantee bulletproof initialization across all iOS versions
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("keepalive.wav")
        if !FileManager.default.fileExists(atPath: tempURL.path) {
            try? data.write(to: tempURL)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: tempURL)
            player.numberOfLoops = -1 // Infinite loop
            player.volume = 1.0       // Non-zero volume keeps CoreAudio graph alive
            player.prepareToPlay()
            self.audioPlayer = player
            NSLog("[SilentAudioKeepAlive] Initialized silent audio player from file (%d bytes)", data.count)
        } catch {
            NSLog("[SilentAudioKeepAlive] File init note: %@, trying data init with fileTypeHint", error.localizedDescription)
            do {
                let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                player.numberOfLoops = -1
                player.volume = 1.0
                player.prepareToPlay()
                self.audioPlayer = player
                NSLog("[SilentAudioKeepAlive] Initialized silent audio player from data with hint (%d bytes)", data.count)
            } catch {
                NSLog("[SilentAudioKeepAlive] Failed to initialize silent audio player: %@", error.localizedDescription)
            }
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPlaying else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
            if audioPlayer == nil {
                prepareSilentPlayer()
            }
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
