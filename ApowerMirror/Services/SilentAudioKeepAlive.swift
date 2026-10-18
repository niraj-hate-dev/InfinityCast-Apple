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
        // Minimal valid 44-byte PCM WAV file containing silence
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let numSamples = sampleRate // 1 second of silence
        let dataSize = numSamples * UInt32(blockAlign)
        let totalSize = 36 + dataSize

        var wavData = Data()
        // RIFF chunk descriptor
        wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSize = totalSize
        wavData.append(Data(bytes: &chunkSize, count: 4))
        wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " sub-chunk
        wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1Size: UInt32 = 16
        wavData.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1 // PCM
        wavData.append(Data(bytes: &audioFormat, count: 2))
        var ch = channels
        wavData.append(Data(bytes: &ch, count: 2))
        var sr = sampleRate
        wavData.append(Data(bytes: &sr, count: 4))
        var br = byteRate
        wavData.append(Data(bytes: &br, count: 4))
        var ba = blockAlign
        wavData.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample
        wavData.append(Data(bytes: &bps, count: 2))

        // "data" sub-chunk
        wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var dSize = dataSize
        wavData.append(Data(bytes: &dSize, count: 4))
        wavData.append(Data(count: Int(dataSize))) // Zero bytes = absolute silence

        do {
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1 // Infinite loop
            player.volume = 0.0 // Muted
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
