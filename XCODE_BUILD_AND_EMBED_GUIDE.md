# ApowerMirror Reconstructed Architecture & Xcode Embedding Guide

## 1. Bundle & Target Hierarchy for Xcode

To build an exact, production-ready binary hierarchy identical to ApowerMirror:

```
ApowerMirror.app/
├── Info.plist
├── ApowerMirror                              (Mach-O Executable, Main App)
├── Frameworks/                                (Embedded Dynamic Frameworks)
│   ├── WXCastiOSSender.framework
│   ├── WXMirrorCore.framework
│   └── MMWormhole.framework
└── PlugIns/
    └── ApowerMirrorUpload.appex/              (Embedded Broadcast Upload Extension)
        ├── Info.plist                         (NSExtensionPrincipalClass = ApowerMirrorUpload.SampleHandler)
        └── ApowerMirrorUpload                 (Mach-O 64-bit arm64 Extension Executable)
```

### Xcode Configuration Steps:
1. **Main Target (`ApowerMirror`):**
   - In **Signing & Capabilities**, add **App Groups** -> `group.apowersoft.mirror` (or `group.applecast.mirror`).
   - In **Signing & Capabilities**, add **Background Modes** -> check **Audio, AirPlay, and Picture in Picture**.
   - In **Build Phases**, click **+** -> **New Copy Files Phase**:
     - **Destination:** `PlugIns` (or `App Extensions`)
     - **Subpath:** leave blank
     - Add: `ApowerMirrorUpload.appex`
     - Check: **Code Sign On Copy**.

2. **Extension Target (`ApowerMirrorUpload`):**
   - Target Type: **Broadcast Upload Extension**
   - **Bundle Identifier:** `com.apowersoft.ApowerMirror.ApowerMirrorUpload`
   - In **Signing & Capabilities**, add **App Groups** -> same group `group.apowersoft.mirror`.
   - In `Info.plist`:
     - `NSExtensionPointIdentifier`: `com.apple.broadcast-services-upload`
     - `NSExtensionPrincipalClass`: `ApowerMirrorUpload.SampleHandler`
     - `RPBroadcastProcessMode`: `RPBroadcastProcessModeSampleBuffer`
   - In `SampleHandler.swift`: Class declared as `public class SampleHandler: RPBroadcastSampleHandler`. Since the module name is `ApowerMirrorUpload`, Swift automatically registers the canonical runtime name `ApowerMirrorUpload.SampleHandler`.

---

## 2. Port Separation Architecture (Zero `EADDRINUSE`)

In Apple's iOS sandbox, two processes cannot bind the same local TCP port simultaneously. If both the Main App and the Extension attempt to call `NWListener` on port `25334`, the OS rejects the second bind with `POSIX error 48 (EADDRINUSE: Address already in use)`.

### Strict Separation Map:

```
+-----------------------------------------------------------------------------------------+
|                                    IPHONE (iOS DEVICE)                                  |
|                                                                                         |
|  +---------------------------------------------+                                        |
|  | Main App Process (ApowerMirror.app)         |                                        |
|  | - WXCastSenderServer                        |                                        |
|  | - Binds ONLY to: 0.0.0.0:25333              | <===== usbmuxd tunnel (Port 25333)     |
|  | - Channel: /channel.do                      |        Control, StartCast, Ping/Pong,  |
|  | - Commands: cmd_Recast_req, cmd_Pause_req   |        cmd-Rotation-Resp:1             |
|  +---------------------------------------------+                                        |
|                         ^                                                               |
|                         | Darwin Notifications & App Group File (MMWormhole)             |
|                         v                                                               |
|  +---------------------------------------------+                                        |
|  | Extension Process (ApowerMirrorUpload.appex)|                                        |
|  | - SampleHandler + VideoEncoder              |                                        |
|  | - Binds ONLY to: 0.0.0.0:25334              | <===== usbmuxd tunnel (Port 25334)     |
|  | - Channel: /mirror.do (H.264 Video)         |        60 FPS H.264 Annex-B Slices,    |
|  | - Channel: /mirrorVoice.do (AAC Audio)      |        7-byte ADTS AAC Audio           |
|  +---------------------------------------------+                                        |
+-----------------------------------------------------------------------------------------+
```

1. **Main App (`WXCastSenderServer`):**
   - Calls `setupChannelListener(port: 25333)`.
   - Never calls `NWListener` on `25334`.
   - Dispatches `StartCast` JSON informing the desktop receiver that the video stream is accessible on port `25334`.

2. **Extension (`SampleHandler`):**
   - Calls `startStreamingServer(port: 25334)`.
   - Streams raw Annex-B H.264 slices tagged with `0x00000000` / `0x00000002` directly to clients connected over the USB usbmuxd tunnel or WiFi.

---

## 3. Verification Against Full Package Manifest

All reconstructed classes and framework structures in `D:\AppleCast\niraj\` match the original ApowerMirror 1,228-item package manifest (`APOWERMIRROR_FULL_FILE_MANIFEST.txt`):

| Reconstructed File | Source Binary & Framework in Manifest | Functionality Verified |
|---|---|---|
| `ApowerMirrorUpload/Info.plist` | `Payload/ApowerMirror.app/PlugIns/ApowerMirrorUpload.appex/Info.plist` | Verified `NSExtensionPrincipalClass = ApowerMirrorUpload.SampleHandler` |
| `ApowerMirrorUpload/SampleHandler.swift` | `Payload/ApowerMirror.app/PlugIns/ApowerMirrorUpload.appex/ApowerMirrorUpload` | Decompiled `-[SampleHandler broadcastStartedWithSetupInfo:]`, `init`, `broadcastFinished` |
| `ApowerMirrorUpload/Encoder/VideoEncoder.swift` | `Payload/ApowerMirror.app/Frameworks/WXCastiOSSender.framework/WXCastiOSSender` | Decompiled `-[WXCastSenderVideoEncoder createSessionRotation:]` & `sendH264Data:type:` |
| `ApowerMirrorUpload/Encoder/AudioEncoder.swift` | `Payload/ApowerMirror.app/Frameworks/WXCastiOSSender.framework/WXCastiOSSender` | Decompiled `-[WXCastSenderAudioEncoder adtsDataForPacketLength:]` |
| `ApowerMirror/Frameworks/WXCastiOSSender/WXCastSenderServer.swift` | `Payload/ApowerMirror.app/Frameworks/WXCastiOSSender.framework/WXCastiOSSender` | Decompiled `-[WXCastSenderServer startMirror:port:msg:]` |
| `ApowerMirror/Frameworks/WXCastiOSSender/WXCastiOSSender.swift` | `Payload/ApowerMirror.app/Frameworks/WXCastiOSSender.framework/WXCastiOSSender` | Decompiled `StartCast` & `SendCustomMsg` JSON payloads |
| `ApowerMirror/Frameworks/WXMirrorCore/WXMirrorCore.swift` | `Payload/ApowerMirror.app/Frameworks/WXMirrorCore.framework/WXMirrorCore` | Decompiled `UIDeviceOrientation` observer & canvas geometry sync |
| `ApowerMirror/Services/MMWormholeManager.swift` | `Payload/ApowerMirror.app/Frameworks/MMWormhole.framework/MMWormhole` | Decompiled Darwin notifications `com.apowermirror.broadcast.*` |
