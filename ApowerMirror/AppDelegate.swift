//
//  AppDelegate.swift
//  ApowerMirror
//
//  Reconstructed 1:1 from ApowerMirror Main Application:
//  - Background Audio Execution Mode Configuration
//  - Background Task Assertion Management
//  - Service & Server Auto-Launch on Startup
//

import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate, MMWormholeManagerDelegate {

    var window: UIWindow?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        NSLog("[AppDelegate] ApowerMirror application launched")

        // 1. Enable Background Audio Category and start keepalive to prime CoreAudio from launch
        configureBackgroundAudioSession()
        SilentAudioKeepAlive.shared.start()

        // 2. Initialize and start WXCastiOSSender service (Listening on 25333 / 25334)
        WXCastiOSSender.shared.startMirrorService(channelPort: 25333, mirrorPort: 25334)

        // 3. Connect MMWormhole IPC Manager
        MMWormholeManager.shared.delegate = self

        // 4. Initialize Core Mirroring Engine
        WXMirrorCore.shared.configureMirroringOptions(fps: 60, bitrate: 4_000_000, resolution: 1080)

        // 5. Initialize Root Window with WXHomeViewController
        if window == nil {
            let win = UIWindow(frame: UIScreen.main.bounds)
            let homeVC = WXHomeViewController()
            let nav = UINavigationController(rootViewController: homeVC)
            win.rootViewController = nav
            win.makeKeyAndVisible()
            self.window = win
        }

        return true
    }

    // MARK: - Background Audio Mode Configuration
    // In iOS, setting category .playback with .mixWithOthers allows the app to maintain
    // active network sockets and receive usbmuxd / USB connections while in the background.

    private func configureBackgroundAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            // Do NOT call session.setActive(true) prematurely; this avoids collision with ReplayKit capture pipeline
            NSLog("[AppDelegate] AVAudioSession category set to .playback with .mixWithOthers (clean ReplayKit compatibility)")
        } catch {
            NSLog("[AppDelegate] Failed to configure AVAudioSession: %@", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle & Background Task Keepalive

    func applicationDidEnterBackground(_ application: UIApplication) {
        NSLog("[AppDelegate] Application entered background -> ensuring audio keepalive is active")
        SilentAudioKeepAlive.shared.start()

        backgroundTask = application.beginBackgroundTask(withName: "com.apowermirror.keepalive") { [weak self] in
            guard let self = self else { return }
            application.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
            NSLog("[AppDelegate] Background task expired")
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        NSLog("[AppDelegate] Application will enter foreground")
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NSLog("[AppDelegate] Application terminating -> cleaning up services")
        WXCastiOSSender.shared.stopMirrorService()
    }

    // MARK: - MMWormholeManagerDelegate Callbacks

    func wormholeDidReceiveBroadcastStarted() {
        NSLog("[AppDelegate] ReplayKit broadcast started in extension -> UI updating to active")
    }

    func wormholeDidReceiveBroadcastFinished() {
        NSLog("[AppDelegate] ReplayKit broadcast stopped in extension -> UI updating to idle")
    }

    func wormholeDidReceivePauseVideo() {
        NSLog("[AppDelegate] ReplayKit broadcast paused")
    }

    func wormholeDidReceiveResumeVideo() {
        NSLog("[AppDelegate] ReplayKit broadcast resumed")
    }
}
