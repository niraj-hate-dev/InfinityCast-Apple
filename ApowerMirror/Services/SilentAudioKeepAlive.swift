//
//  SilentAudioKeepAlive.swift
//  ApowerMirror / Services
//
//  Background Keepalive Engine:
//  Plays an inaudible, zero-volume silent audio loop using AVAudioPlayer with
//  AVAudioSession category .playback and .mixWithOthers.
//  This prevents iOS from suspending the Main App when minimized to the Home screen
//  during live ReplayKit screen mirroring sessions.
//

import Foundation
import AVFoundation

public final class SilentAudioKeepAlive {

    public static let shared = SilentAudioKeepAlive()

    private var audioPlayer: AVAudioPlayer?
    private var isPlaying = false

    private init() {
        prepareSilentPlayer()
    }

    private func prepareSilentPlayer() {
        // Standard 44-byte PCM WAV header for 8000Hz 16-bit mono + 2048 bytes of silence
        let wavHeader: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, // "RIFF"
            0x24, 0x08, 0x00, 0x00, // total size - 8 (2084 bytes)
            0x57, 0x41, 0x56, 0x45, // "WAVE"
            0x66, 0x6D, 0x74, 0x20, // "fmt "
            0x10, 0x00, 0x00, 0x00, // subchunk1 size (16)
            0x01, 0x00,             // audio format (1 = PCM)
            0x01, 0x00,             // num channels (1)
            0x40, 0x1F, 0x00, 0x00, // sample rate (8000 Hz)
            0x80, 0x3E, 0x00, 0x00, // byte rate (16000 B/s)
            0x02, 0x00,             // block align (2)
            0x10, 0x00,             // bits per sample (16)
            0x64, 0x61, 0x74, 0x61, // "data"
            0x00, 0x08, 0x00, 0x00  // data size (2048 bytes of silence)
        ]

        var wavData = Data(wavHeader)
        wavData.append(Data(repeating: 0, count: 2048))

        do {
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1 // Infinite loop
            player.volume = 0.0 // Muted silence
            player.prepareToPlay()
            self.audioPlayer = player
        } catch {
            NSLog("[SilentAudioKeepAlive] Failed to initialize silent audio player: %@", error.localizedDescription)
        }
    }

    public func start() {
        guard !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            audioPlayer?.play()
            isPlaying = true
            NSLog("[SilentAudioKeepAlive] Silent audio loop started -> App granted continuous background execution")
        } catch {
            NSLog("[SilentAudioKeepAlive] Failed to activate audio session: %@", error.localizedDescription)
        }
    }

    public func stop() {
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
