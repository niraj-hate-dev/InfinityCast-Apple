# EXHAUSTIVE REVERSE-ENGINEERING & CODE RECONSTRUCTION SPECIFICATION
# Target Source: D:\AppleCast\com.apowersoft.ApowerMirror_1.5.2_und3fined\Payload\
# Destination Directory: D:\AppleCast\niraj\

---

## 1. SOURCE DIRECTORY SCAN & INVENTORY SUMMARY
A total of **1,228 files and directories** were recursively scanned across `Payload\`.
The complete line-by-line manifest is persisted in:
`D:\AppleCast\niraj\APOWERMIRROR_FULL_FILE_MANIFEST.txt`

### Key Root Binaries and Architecture Breakdown:
1. **Main Application Package**: `Payload/ApowerMirror.app/`
   - **Main Executable**: `ApowerMirror` (Mach-O ARM64, 18.2 MB)
   - **Main Info.plist**: Bundle ID `com.apowersoft.ApowerMirror`, Minimum OS `13.0`, Background Modes `["audio"]`
   - **UI Components**: 67 compiled NIB view controllers (`WXHomeViewController.nib`, `WXMirrorViewController.nib`, `WXPCMirrorChooseVC.nib`, etc.)

2. **ReplayKit Broadcast Extension**: `Payload/ApowerMirror.app/PlugIns/ApowerMirrorUpload.appex/`
   - **Extension Executable**: `ApowerMirrorUpload` (Mach-O ARM64, 93 KB)
   - **Extension Info.plist**:
     - `NSExtensionPointIdentifier`: `com.apple.broadcast-services-upload`
     - `NSExtensionPrincipalClass`: `ApowerMirrorUpload.SampleHandler`
     - `RPBroadcastProcessMode`: `RPBroadcastProcessModeSampleBuffer`

3. **Core Mirroring & Streaming Frameworks**: `Payload/ApowerMirror.app/Frameworks/`
   - `WXCastiOSSender.framework/WXCastiOSSender` (Primary streaming engine, `WXCastSenderServer`, WebSocket server on ports 25333/25334, VideoToolbox encoder)
   - `WXMirrorCore.framework/WXMirrorCore` (Mirroring session coordinator, rotation management)
   - `AgoraReplayKitExtension.framework/AgoraReplayKitExtension` (Base class `AgoraReplayKitHandler`)
   - `MMWormhole.framework/MMWormhole` (Cross-process notification bridge between Extension and App)
   - `SocketRocket.framework/SocketRocket` (WebSocket RFC 6455 transport)
   - `WXCastFFMpeg.framework` & `Agorafdkaac.framework` (Audio AAC ADTS compression)

---

## 2. CODE RECONSTRUCTION INSTRUCTIONS FOR REVERSE ENGINEER
You must reverse-engineer the disassembled ARM64 instructions, class structures, ivars, and methods across all the binaries above, and recreate the exact source code in `D:\AppleCast\niraj\`:

### Output Folder Structure in `D:\AppleCast\niraj\`:
```
D:\AppleCast\niraj\
│
├── ApowerMirror\                              <-- Reconstructed Main iOS App
│   ├── AppDelegate.swift
│   ├── Info.plist
│   ├── Controllers\
│   │   ├── WXHomeViewController.swift
│   │   ├── WXMirrorViewController.swift
│   │   └── WXPCMirrorChooseVC.swift
│   ├── Services\
│   │   ├── BroadcastPickerManager.swift       <-- RPSystemBroadcastPickerView trigger
│   │   ├── MMWormholeManager.swift            <-- App Group IPC bridge
│   │   └── NetworkDetector.swift
│   └── Frameworks\
│       ├── WXCastiOSSender\
│       │   ├── WXCastiOSSender.swift          <-- Embedded server coordinator
│       │   ├── WXCastSenderServer.swift       <-- Listening on 0.0.0.0:25333 & 25334
│       │   ├── WXCastSenderVideoEncoder.swift <-- VideoToolbox VTCompressionSession
│       │   └── WXCastSenderAudioEncoder.swift <-- AudioConverter AAC + ADTS headers
│       └── WXMirrorCore\
│           └── WXMirrorCore.swift
│
└── ApowerMirrorUpload\                        <-- Reconstructed ReplayKit Broadcast Extension
    ├── Info.plist
    ├── SampleHandler.swift                    <-- @objc(SampleHandler) : AgoraReplayKitHandler
    ├── Encoder\
    │   ├── VideoEncoder.swift                 <-- Annex-B NALU 00 00 00 01 + 4-byte slice tags
    │   └── AudioEncoder.swift                 <-- 7-byte ADTS framing
    └── Network\
        └── ExtensionSocketBridge.swift        <-- Forwarding to WXCastSenderServer
```

---

## 3. CORE PROTOCOL & SPECIFICATIONS TO REPLICATE:
1. **Ports & Binding**:
   - `_channelPort` = 25333 (`/channel.do`)
   - `_mirrorPort` = 25334 (`/mirror.do`)
   - Bind to `INADDR_ANY` (`0.0.0.0`) so usbmuxd virtual TCP tunnels can route in from Windows desktop.
2. **Video Framing**:
   - Raw Annex-B start codes: `00 00 00 01`.
   - Big-Endian 4-byte header tag: `0x00000000` (Slice) vs `0x00000002` (EndFrame marker).
   - Slice chunking: sub-packets capped at 10,240 bytes (10 KB).
3. **Audio Framing**:
   - Dedicated route: `/mirrorVoice.do`.
   - Big-Endian tag: `0x00000002` + 7-byte ADTS Header + AAC payload.
4. **Orientation & Resolution**:
   - On rotation: Re-create `VTCompressionSession` with swapped width/height.
   - Send control strings: `"cmd-Rotation-Resp:%d"` and `"cmd-Resolution-Resp:%d_%d"`.
5. **Memory Protection**:
   - Enforce 50 MB Jetsam guard: drop frames and drain autoreleasepool if footprint >= 41 MB.
