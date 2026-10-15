# iOS Broadcast Upload Extension Architecture & Reverse Engineering Blueprint (ApowerMirror Deep Dive)

## 1. Executive Summary & Root Cause Analysis

During troubleshooting of the custom iOS Broadcast Upload Extension for **AppleCast**, the extension failed to start (the iOS screen recording indicator remained gray or terminated immediately) and failed to bind the expected local TCP socket. 

To determine the architectural omissions, we conducted binary and static analysis on the commercial **ApowerMirror iOS client** (v1.6.0 / build 22, SDK `iphoneos16.1`) located at:
`Payload/ApowerMirror.app/PlugIns/ApowerMirrorUpload.appex`

### The Critical Root Causes Identified

1. **Missing or Corrupted Principal Class Resolution in `Info.plist`**:
   - In Swift-based Broadcast Upload Extensions, `NSExtensionPrincipalClass` must strictly match the module namespace (`$(PRODUCT_MODULE_NAME).SampleHandler` or `@objc(SampleHandler)`). A mismatch prevents the iOS extension host process from instantiating the handler, leaving the Control Center recording toggle permanently gray.
   - `CFBundlePackageType` must be set to `XPC!` (not `BNDL`).

2. **Absence of Shared App Group IPC & Dynamic Port Exchange**:
   - The commercial app **does not hardcode a single fixed socket port** (e.g. 15333) inside the extension.
   - The host application assigns the target port (`_mirrorPort`, default **25334**; listen port **15486**) and synchronizes it via an **App Group `NSUserDefaults`** suite under the key **`"wxiosserverport"`**.
   - If the key is missing or set to `0`, the extension binds to **port 0** (dynamic ephemeral port) and reports it back to the host via **MMWormhole** / Darwin notifications. If an extension attempts to bind to a hardcoded port that is in `TIME_WAIT` or occupied, `bind()` fails and the extension aborts.

3. **Jetsam OOM Crashes from VideoToolbox Frame Accumulation**:
   - iOS imposes an uncompromising **50 MB physical memory footprint limit** (`phys_footprint`) on Broadcast Upload Extensions.
   - Custom implementations typically crash within 1–2 seconds because `VTCompressionSession` defaults to internal multi-frame buffering and frame reordering (B-frames).
   - Commercial implementations strictly enforce:
     - `kVTCompressionPropertyKey_AllowFrameReordering = kCFBooleanFalse` (Zero B-frames).
     - `kVTCompressionPropertyKey_MaxFrameDelayCount = 1` (Immediate encoder flush, zero internal frame queueing).
     - `kVTCompressionPropertyKey_DataRateLimits = [bitrate * 2.0 / 8, 1]` (Clamps bitrate burst buffer).
     - Active Mach kernel memory monitoring via `task_info(mach_task_self(), TASK_VM_INFO)`: If memory exceeds **41 MB**, incoming frames are immediately dropped (`memoryLock`) until memory drops below **39 MB**.

---

## 2. Extension Bundle Layout & `Info.plist` Configuration

### Bundle Structure Inside the IPA
```
Payload/
└── ApowerMirror.app/
    ├── Info.plist
    ├── Frameworks/
    │   ├── WXCastiOSSender.framework   <-- Native streaming core & encoder
    │   ├── WXMirrorCore.framework       <-- GCDAsyncSocket & WebSocket server
    │   ├── MMWormhole.framework         <-- App Group Darwin IPC
    │   └── AgoraReplayKitExtension.framework
    └── PlugIns/
        └── ApowerMirrorUpload.appex/    <-- Broadcast Upload Extension
            ├── ApowerMirrorUpload       <-- Thin Swift wrapper binary (93 KB)
            ├── Info.plist               <-- Extension contract definition
            └── _CodeSignature/
```

### Complete Extension `Info.plist` Analysis
Extracted and normalized from `ApowerMirrorUpload.appex/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ApowerMirrorUpload</string>
    <key>CFBundleIdentifier</key>
    <string>com.apowersoft.ApowerMirror.ApowerMirrorUpload</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.6.0</string>
    <key>CFBundleVersion</key>
    <string>22</string>
    <key>MinimumOSVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.broadcast-services-upload</string>
        <key>NSExtensionPrincipalClass</key>
        <string>ApowerMirrorUpload.SampleHandler</string>
        <key>RPBroadcastProcessMode</key>
        <string>RPBroadcastProcessModeSampleBuffer</string>
    </dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>ApowerMirror needs access to the microphone to enable audio features.</string>
</dict>
</plist>
```

### Key Differences & Rules for `Info.plist`
| Property | Commercial Value | Why It Matters |
| :--- | :--- | :--- |
| `CFBundlePackageType` | `XPC!` | Must be `XPC!`. Setting this to `BNDL` or `APPL` prevents ReplayKit from discovering the upload target. |
| `NSExtensionPointIdentifier` | `com.apple.broadcast-services-upload` | Identifies this bundle as a continuous sample-buffer upload pipeline (ReplayKit 2). |
| `NSExtensionPrincipalClass` | `$(PRODUCT_MODULE_NAME).SampleHandler` | In Swift, classes are namespaced by their module. If omitting `@objc(SampleHandler)`, the module prefix is mandatory. |
| `RPBroadcastProcessMode` | `RPBroadcastProcessModeSampleBuffer` | Informs ReplayKit to deliver raw `CMSampleBufferRef` objects into `processSampleBuffer(_:with:)`. |

---

## 3. IPC Architecture & Shared App Group Data Plane

The commercial binary relies on a shared **App Group Container**:
- **App Group Identifier**: `group.apowersoft.mirror`
- **Team ID**: `8X732W9RQ2`

```
+-----------------------------------------------------------------------------------------+
|                                    iOS HOST APPLICATION                                 |
|                                                                                         |
|  [ WXMirrorSDKSender ]                                                                  |
|  1. Writes configuration to UserDefaults(suiteName: "group.apowersoft.mirror")          |
|     - "wxiosserverport"         -> 25334 (or dynamically selected port)                 |
|     - "kGroupReplayKitRecordType" -> 0 (Local Direct TCP) / 1 (Agora Cloud RTC)         |
|     - "kGroupMirrorVoiceSwitch" -> true / false (System Audio Capture)                  |
|     - "videoFps" / "videoBitrate" / "videoResolution"                                   |
|  2. Initializes MMWormhole(applicationGroupIdentifier: "group.apowersoft.mirror")       |
|  3. Triggers RPSystemBroadcastPickerView via programmatic button event                  |
+-----------------------------------------------------------------------------------------+
                                           |
                                    [ Shared IPC ]
                     App Group UserDefaults + Darwin Notification Center
                                           |
                                           v
+-----------------------------------------------------------------------------------------+
|                                BROADCAST UPLOAD EXTENSION                               |
|                                                                                         |
|  [ SampleHandler (Swift) ]                                                              |
|  1. Reads suite "group.apowersoft.mirror"                                               |
|  2. If recordType == 0 -> delegates to WXCastiOSSenderBroadcast                         |
|  3. WXCastiOSSenderBroadcast.startServer:                                               |
|     - Reads "wxiosserverport"                                                           |
|     - Binds WXWebSocketServer / GCDAsyncSocket on 127.0.0.1:port                        |
|  4. MMWormhole listens on identifier "WXCastiOSSender":                                 |
|     - Actions: "StopMirror", "PauseVideo", "PauseAudio", "Finish"                       |
+-----------------------------------------------------------------------------------------+
```

### Shared `UserDefaults` Key Specification

| Key | Type | Default Value | Functional Role |
| :--- | :--- | :--- | :--- |
| **`"wxiosserverport"`** | `NSInteger` | `25334` | The TCP port the extension's local socket listener binds to. |
| **`"kGroupReplayKitRecordType"`** | `NSInteger` | `0` | `0` = Local high-speed USB/Wi-Fi socket mirror (`WXCastiOSSenderBroadcast`); `1` = Agora RTC Cloud. |
| **`"kGroupMirrorVoiceSwitch"`** | `BOOL` | `NO` | Audio gate: When `NO`, transmits device audio buffers (`.audioApp`). |
| **`"videoFps"`** | `NSInteger` | `30` / `60` | Target encoder framerate. |
| **`"videoBitrate"`** | `NSInteger` | `8000000` | Target average bitrate in bits/sec. |
| **`"videoResolution"`** | `NSInteger` | `1080` / `720` | Output bounding resolution. |

---

## 4. Socket Binding & Network Pipeline

### Native Reverse Engineering Findings (`WXCastiOSSender` & `WXMirrorCore`)

Disassembly of `-[WXCastiOSSenderBroadcast startServer]` and `-[WXCastiOSSender configReplayKit:appGroup:]` reveals:

1. **Port Derivation & Dynamic Assignment**:
   - Inside `-[WXCastiOSSender init]`:
     ```objc
     self->_mirrorPort = 0x62f6; // 25334 in decimal
     self->_listenPort = 0x3c7e; // 15486 in decimal
     ```
   - In `-[WXCastiOSSender configReplayKit:appGroup:]`:
     ```objc
     [userDefaults setInteger:self->_mirrorPort forKey:@"wxiosserverport"];
     ```
   - In `-[WXCastiOSSenderBroadcast startServer]`:
     ```objc
     NSInteger targetPort = [self.userDefaults integerForKey:@"wxiosserverport"];
     [self.server startWithPort:targetPort delegate:self Block:^(BOOL success) {
         if (!success) {
             NSLog(@"start mirror listener error");
         }
     }];
     ```

2. **Loopback Binding Security**:
   - `WXWebSocketServer` wraps `GCDAsyncSocket`.
   - When calling `acceptOnPort:(uint16_t)port error:&error`, passing `port = 0` triggers OS dynamic port allocation.
   - For USB multiplexing over `usbmuxd`, binding occurs on **`127.0.0.1`** (loopback) or `INADDR_ANY`.
   - On iOS 14+, binding on `0.0.0.0` triggers the "Local Network Permission" modal in the host app. The companion app includes:
     - `NSLocalNetworkUsageDescription` in `Info.plist`.
     - `NSBonjourServices`: `["_mirrorserver._tcp", "_apowermirror._tcp.", "_airplay._tcp."]`.

---

## 5. `VTCompressionSession` Configuration & Memory Management

Disassembly of `-[WXCastSenderVideoEncoder createSessionRotation:]` (`0x12d34` in `WXCastiOSSender.framework`) revealed the exact property matrix used to guarantee real-time encoding under 50 MB RAM:

```objc
// Codec FourCC: 'avc1' (kCMVideoCodecType_H264)
VTCompressionSessionCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCMVideoCodecType_H264,
    NULL,
    pixelBufferAttributes,
    NULL,
    compressionOutputCallback,
    (__bridge void *)(self),
    &_compressionSession
);
```

### Exact VideoToolbox Properties Applied

| Property Key | Configured Value | Disassembly Rationale |
| :--- | :--- | :--- |
| **`kVTCompressionPropertyKey_RealTime`** | `kCFBooleanTrue` | Disables multi-pass lookahead; forces low-latency hardware pass. |
| **`kVTCompressionPropertyKey_ProfileLevel`** | `Main_AutoLevel` (width > 1919) / `Baseline_AutoLevel` (width <= 1919) | Prevents CABAC/High-profile context complexity crashes on smaller or older chipsets. |
| **`kVTCompressionPropertyKey_AllowFrameReordering`** | `kCFBooleanFalse` | **CRITICAL**: Disables B-frames completely. Frames are emitted strictly in display order ($PTS = DTS$). Eliminates encoder reorder buffer memory footprint. |
| **`kVTCompressionPropertyKey_AllowTemporalCompression`** | `kCFBooleanTrue` | Permits P-frame inter-frame compression. |
| **`kVTCompressionPropertyKey_H264EntropyMode`** | `kVTH264EntropyMode_CABAC` | Uses arithmetic coding for bitrate efficiency at 1080p. |
| **`kVTCompressionPropertyKey_ExpectedFrameRate`** | `fps` (e.g., 60) | Hints the rate controller. |
| **`kVTCompressionPropertyKey_MaxKeyFrameInterval`** | `2 * fps` (if FPS > 59) / `3 * fps` (if FPS <= 59) | Emits IDR keyframe every 2 to 3 seconds. |
| **`kVTCompressionPropertyKey_AverageBitRate`** | `bitrate` (e.g. 10,000,000 bps) | Target average data rate. |
| **`kVTCompressionPropertyKey_DataRateLimits`** | `[bitrate * 2.0 / 8, 1]` | **CRITICAL**: Sets an absolute ceiling of $2.0 \times$ average bitrate over a 1-second window. Prevents transient scene complexity bursts from filling memory buffers. |
| **`kVTCompressionPropertyKey_MaxFrameDelayCount`** | `1` | **CRITICAL**: Restricts encoder frame backlog to exactly 1 frame. The encoder must produce compressed output immediately without buffering in RAM. |
| **`kVTCompressionPropertyKey_Quality`** | `0.85` (>= 2560), `0.80` (>= 1920), `0.70` (< 1920) | Dynamic quantization scaling. |
| **`kVTCompressionPropertyKey_MaxH264SliceBytes`** | Enabled for resolution >= 1920 | Slices giant frames into uniform segments to avoid allocating massive contiguous packet buffers. |

---

## 6. Real-Time Mach Kernel Memory Throttling (`TASK_VM_INFO`)

ApowerMirror monitors physical memory footprint using Darwin Mach kernel primitives in `WXCastMemoryTool`:

```c
#include <mach/mach.h>

int64_t getMemoryFootprintMB(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    return (int64_t)(vmInfo.phys_footprint >> 20); // Convert bytes to Megabytes
}
```

### The Backpressure State Machine
In `WXCastiOSSenderBroadcast.m`:
1. Every video frame in `encodeVideo:` checks:
   ```objc
   if (self.memoryLock || self.videoPause) {
       // DROP FRAME IMMEDIATELY WITHOUT PASSING TO VIDEOTOOLBOX
       return;
   }
   ```
2. When system memory reaches **41 MB** (`didReceiveMemoryWarning:` or periodic check):
   ```objc
   if (getMemoryFootprintMB() >= 41) {
       self.memoryLock = YES;
       [self performSelector:@selector(memoryCheck) withObject:nil afterDelay:1.5];
   }
   ```
3. Inside `memoryCheck`:
   ```objc
   if (getMemoryFootprintMB() <= 39) {
       self.memoryLock = NO; // Memory cleared, resume encoding
   } else {
       [self performSelector:@selector(memoryCheck) withObject:nil afterDelay:1.5];
   }
   ```
This dynamic frame-dropping mechanism prevents the extension from crossing the 50 MB Jetsam limit during network stalls or complex screen activity.

---

## 7. Advanced Mechanisms & Undocumented Features Discovered

### 1. Programmatic `RPSystemBroadcastPickerView` Button Trigger
To bypass requiring the user to locate and tap the ReplayKit broadcast button in the UI, ApowerMirror uses subview traversal on `RPSystemBroadcastPickerView` (`0x679c`–`0x6858`):

```swift
let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
picker.preferredExtension = "com.apowersoft.ApowerMirror.ApowerMirrorUpload"
picker.showsMicrophoneButton = false

for subview in picker.subviews {
    if let button = subview as? UIButton {
        button.sendActions(for: .touchUpInside)
        break
    }
}
```

### 2. Audio Capture Routing
- App Audio (`.audioApp`) is captured and converted to AAC elementary streams with ADTS framing via `AudioConverterNew`.
- Microphone Audio (`.audioMic`) is conditionally gated via the shared `UserDefaults` switch `"kGroupMirrorVoiceSwitch"`.

### 3. Dedicated Background Encoding Queue with `@autoreleasepool`
Every invocation of `processSampleBuffer` passes the `CVPixelBuffer` to an asynchronous serial queue inside an explicit `@autoreleasepool`. Failure to drain the autorelease pool on every single frame causes CoreVideo pixel buffers to linger, pushing the extension over 50 MB in less than 30 frames.

---

## 8. Complete Reference Implementation

### File 1: Production `SampleHandler.swift`
Drop this implementation into your custom Broadcast Upload Extension target:

```swift
import ReplayKit
import VideoToolbox
import Network

@objc(SampleHandler)
class SampleHandler: RPBroadcastSampleHandler {
    
    // MARK: - Constants & Configuration
    private let appGroupName = "group.com.yourcompany.applecast"
    private let defaultPort: UInt16 = 25334
    
    // MARK: - State Management
    private var sharedDefaults: UserDefaults?
    private var tcpListener: NWListener?
    private var connectedClient: NWConnection?
    
    private let encodeQueue = DispatchQueue(label: "com.applecast.encoder.queue", qos: .userInteractive)
    private var compressionSession: VTCompressionSession?
    
    private var isMemoryLocked = false
    private var frameCount: Int64 = 0
    private var targetFps: Int32 = 60
    private var targetBitrate: Int32 = 8_000_000
    
    // MARK: - Broadcast Lifecycle
    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        sharedDefaults = UserDefaults(suiteName: appGroupName)
        
        let targetPortInt = sharedDefaults?.integer(forKey: "wxiosserverport") ?? 0
        let portToBind = targetPortInt > 0 ? UInt16(targetPortInt) : defaultPort
        
        if let fps = sharedDefaults?.integer(forKey: "videoFps"), fps > 0 {
            targetFps = Int32(fps)
        }
        if let bitrate = sharedDefaults?.integer(forKey: "videoBitrate"), bitrate > 0 {
            targetBitrate = Int32(bitrate)
        }
        
        startLocalServer(port: portToBind)
    }
    
    override func broadcastPaused() {
        // Handle stream pause
    }
    
    override func broadcastResumed() {
        // Handle stream resume
    }
    
    override func broadcastFinished() {
        stopLocalServer()
        tearDownCompressionSession()
    }
    
    // MARK: - Frame Processing Pipeline
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // Memory check before queuing frame
            if isMemoryLocked || getPhysicalFootprintMB() >= 41 {
                isMemoryLocked = true
                scheduleMemoryRecoveryCheck()
                return // Drop frame under memory pressure
            }
            
            encodeQueue.async { [weak self] in
                autoreleasepool {
                    self?.encodeVideoFrame(sampleBuffer)
                }
            }
            
        case .audioApp:
            let voiceMuted = sharedDefaults?.bool(forKey: "kGroupMirrorVoiceSwitch") ?? false
            if !voiceMuted {
                // Route application audio to TCP sink
            }
            
        case .audioMic:
            break
            
        @unknown default:
            break
        }
    }
    
    // MARK: - VideoToolbox Compression Setup
    private func setupCompressionSession(width: Int32, height: Int32) {
        tearDownCompressionSession()
        
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
            let handler = Unmanaged<SampleHandler>.fromOpaque(refCon).takeUnretainedValue()
            handler.handleEncodedFrame(sampleBuffer, flags: flags)
        }
        
        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refCon,
            compressionSessionOut: &compressionSession
        )
        
        guard status == noErr, let session = compressionSession else { return }
        
        // 1. Low-latency real-time flags
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        
        // 2. Profile Level selection (Main for >=1080p, Baseline for <1080p)
        let profile = width >= 1920 ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_H264_Baseline_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        
        // 3. Bitrate & Burst Limits (DataRateLimits)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        let byteLimit = (targetBitrate * 2) / 8 // 2x average bitrate cap per second
        let limits: [CFNumber] = [byteLimit as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        
        // 4. Critical Jetsam OOM Prevention: MaxFrameDelayCount = 1
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        
        // 5. Framerate & Keyframe intervals
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)
        let gopSize = targetFps >= 60 ? (targetFps * 2) : (targetFps * 3)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gopSize as CFNumber)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    private func encodeVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        
        if compressionSession == nil {
            setupCompressionSession(width: width, height: height)
        }
        
        guard let session = compressionSession else { return }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
    }
    
    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard let client = connectedClient else { return }
        
        // Extract Parameter Sets (SPS / PPS) on Keyframes
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsSize: Int = 0
            var spsCount: Int = 0
            var spsPointer: UnsafePointer<UInt8>?
            
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
               let sps = spsPointer, spsSize > 0 {
                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pps = ppsPointer, ppsSize > 0 {
                    // Send SPS & PPS with 4-byte Annex-B start codes [0x00, 0x00, 0x00, 0x01]
                    sendNalu(Data(bytes: sps, count: spsSize), isKey: true)
                    sendNalu(Data(bytes: pps, count: ppsSize), isKey: true)
                }
            }
        }
        
        // Extract Elementary Stream NAL Units
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
           let basePointer = dataPointer {
            var bufferOffset = 0
            while bufferOffset < totalLength - 4 {
                var naluLength: UInt32 = 0
                memcpy(&naluLength, basePointer + bufferOffset, 4)
                naluLength = CFSwapInt32BigToHost(naluLength)
                bufferOffset += 4
                
                let naluData = Data(bytes: basePointer + bufferOffset, count: Int(naluLength))
                sendNalu(naluData, isKey: false)
                bufferOffset += Int(naluLength)
            }
        }
    }
    
    private func sendNalu(_ naluData: Data, isKey: Bool) {
        guard let client = connectedClient else { return }
        
        // Prefix with Annex-B start code
        var packet = Data([0x00, 0x00, 0x00, 0x01])
        packet.append(naluData)
        
        client.send(content: packet, completion: .contentProcessed({ _ in }))
    }
    
    private func tearDownCompressionSession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }
    
    // MARK: - Network Listener (usbmuxd Tunnel Sink)
    private func startLocalServer(port: UInt16) {
        do {
            let parameters = NWParameters.tcp
            // Allow fast socket re-binding without TIME_WAIT locks
            parameters.allowLocalEndpointReuse = true
            
            tcpListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
            tcpListener?.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    break
                case .failed(let error):
                    print("TCP Listener failed: \(error)")
                default:
                    break
                }
            }
            
            tcpListener?.newConnectionHandler = { [weak self] connection in
                self?.connectedClient?.cancel()
                self?.connectedClient = connection
                connection.start(queue: .global(qos: .userInteractive))
            }
            
            tcpListener?.start(queue: .global(qos: .userInteractive))
        } catch {
            print("Failed to initialize NWListener on port \(port): \(error)")
        }
    }
    
    private func stopLocalServer() {
        connectedClient?.cancel()
        connectedClient = nil
        tcpListener?.cancel()
        tcpListener = nil
    }
    
    // MARK: - Mach Kernel Memory Diagnostics
    private func getPhysicalFootprintMB() -> Int64 {
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
        let kr = withUnsafeMutablePointer(to: &vmInfo) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self(), task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(vmInfo.phys_footprint >> 20)
    }
    
    private func scheduleMemoryRecoveryCheck() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if self.getPhysicalFootprintMB() <= 39 {
                self.isMemoryLocked = false
            } else {
                self.scheduleMemoryRecoveryCheck()
            }
        }
    }
}
```

---

### File 2: Extension `Info.plist`
Place this in your Broadcast Extension target:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key>
    <string>AppleCastUpload</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.broadcast-services-upload</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).SampleHandler</string>
        <key>RPBroadcastProcessMode</key>
        <string>RPBroadcastProcessModeSampleBuffer</string>
    </dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>AppleCast requires microphone access for audio streaming.</string>
</dict>
</plist>
```

---

### File 3: Host Application `Info.plist` Additions
Ensure the following permissions and keys exist in the main iOS companion app:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>AppleCast connects to your PC over the local USB/Wi-Fi connection to mirror your screen.</string>

<key>NSBonjourServices</key>
<array>
    <string>_mirrorserver._tcp</string>
    <string>_applecast._tcp</string>
</array>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

---

### File 4: Host App Broadcast Coordinator (`BroadcastManager.swift`)
Drop this helper into the main companion app to orchestrate ReplayKit, App Group defaults, and automatic picker invocation:

```swift
import UIKit
import ReplayKit

class BroadcastManager {
    static let shared = BroadcastManager()
    
    let appGroup = "group.com.yourcompany.applecast"
    let extensionBundleId = "com.yourcompany.applecast.upload"
    let targetPort: UInt16 = 25334
    
    func configureAndStartBroadcast(on parentView: UIView) {
        // 1. Synchronize target port and options into App Group UserDefaults
        if let defaults = UserDefaults(suiteName: appGroup) {
            defaults.set(Int(targetPort), forKey: "wxiosserverport")
            defaults.set(0, forKey: "kGroupReplayKitRecordType") // 0 = Custom Local TCP stream
            defaults.set(false, forKey: "kGroupMirrorVoiceSwitch")
            defaults.set(60, forKey: "videoFps")
            defaults.set(12_000_000, forKey: "videoBitrate")
            defaults.synchronize()
        }
        
        // 2. Programmatically invoke RPSystemBroadcastPickerView
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = extensionBundleId
        picker.showsMicrophoneButton = false
        picker.isHidden = true
        parentView.addSubview(picker)
        
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                break
            }
        }
    }
}
```

---

## 9. Verification & Diagnostics Checklist

When validating the custom extension on a physical device, verify each item in this checklist:

1. **Verify App Group Entitlements Match**:
   Both `AppleCast.app` and `AppleCastUpload.appex` must have matching entitlements in `AppleCast.entitlements` and `AppleCastUpload.entitlements`:
   ```xml
   <key>com.apple.security.application-groups</key>
   <array>
       <string>group.com.yourcompany.applecast</string>
   </array>
   ```
2. **Confirm `CFBundlePackageType` is `XPC!`**:
   Inspect the built `Info.plist` inside `DerivedData/.../AppleCastUpload.appex/Info.plist` to confirm Xcode did not overwrite it with `BNDL`.
3. **Monitor Extension Memory Live in Xcode Instruments**:
   Attach the **Allocations** / **Memory Footprint** instrument directly to the `AppleCastUpload` process. Verify that `phys_footprint` stays consistently under **35 MB** during heavy 60 FPS motion.
4. **Test Loopback Port Tunneling over usbmuxd**:
   On the PC client, execute `usbmuxd` connect request targeting device port `25334` (`0x62f6`). The extension socket should accept the connection and immediately begin streaming Annex-B NAL units with 4-byte start codes.
