# System Architecture & Reverse Engineering Findings

## 1. Executive Overview

This document provides a comprehensive technical breakdown of the architecture, communication protocols, and media pipelines powering commercial iOS screen mirroring applications (specifically reverse-engineered from ApowerMirror). It serves as the authoritative blueprint for engineering an equivalent high-performance, open-source Apple device screen mirroring client (**AppleCast**).

### Core Wired Communication Mechanism
Unlike older solutions that depended strictly on Apple's proprietary `iTunesMobileDevice.dll` (from iTunes installations), modern screen mirroring tools interface with iOS devices over USB through the open-source **USB Multiplexer (`usbmuxd`)** protocol. Communication occurs without requiring a full iTunes installation:
1. An incoming USB connection exposes the device via Apple's standard USB composite interface (Vendor ID `0x05AC`).
2. The host runs or connects to a local usbmux daemon listening on loopback TCP port **`127.0.0.1:27015`**.
3. Multiplexed bidirectional TCP virtual streams are tunneled across the physical USB cable directly into target ports exposed by services or background apps running on the iOS device.

### High-Level Data Pipeline
```
+------------------------------------------------------------------------------------------------+
|                                           iOS DEVICE                                           |
|                                                                                                |
|  [ Screen Capture ]          [ Hardware Encoder ]                [ Network / IPC Socket ]      |
|  ReplayKit 2 SampleHandler -> VideoToolbox (VTCompressionSession) -> BSD TCP Client Socket     |
|  (CMSampleBuffer / CVPixelBuffer) -> (H.264/HEVC NAL Units)           (Localhost Port :X)      |
+------------------------------------------------------------------------------------------------+
                                              |
                                     [ USB Cable (Lightning / USB-C) ]
                                     Tunneled via usbmuxd (TCP Port 27015)
                                              v
+------------------------------------------------------------------------------------------------+
|                                            PC HOST                                             |
|                                                                                                |
|  [ Usbmux Client Bridge ]            [ Local Socket Sink ]        [ Demuxer & Decoder ]        |
|  usbmuxd.dll / libwxaus.dll       -> WXTcpMedia.dll (Loopback) -> libffmpeg / HW Accel         |
|  usbmuxd_connect(dev_id, port)       (127.0.0.1:DynamicPort)      (NVENC / D3D11VA / DXVA2)    |
|                                                                             |                  |
|                                                                             v                  |
|                                                                    [ Rendering Canvas ]        |
|                                                                    SDL2 / Direct3D 11 Surface  |
+------------------------------------------------------------------------------------------------+
```

---

## 2. Technology Stack & Dependencies Identified

### Desktop Client Runtime & Architecture
* **GUI & Application Orchestration**: .NET Framework 4.5 WPF (Windows Presentation Foundation) compiled for x86 (32-bit).
* **Binary Packaging & Protection**: The main executable (`ApowerMirror.exe`) is packed with **Netz** (`netz.NetzStarter`). At runtime, it dynamically extracts and loads compressed managed assemblies (`ApowerMirror.dll` internal core, `Apowersoft.CommUtilities.Native.dll`, `Apowersoft.ApowerMirror.WPF.dll`) from an embedded zlib-compressed resource (`app.resources`) directly into the AppDomain.
* **Native C/C++ Interop**: Managed layers interface with high-performance native DLLs via P/Invoke (`[DllImport]`).

### Native Libraries & Component Matrix

| Binary / DLL | Vendor / Origin | Primary Architectural Role |
| :--- | :--- | :--- |
| **`usbmuxd.dll`** | libimobiledevice project | USB multiplexer client library communicating with `127.0.0.1:27015`. |
| **`imobiledevice.dll`** | Quamotion / libimobiledevice | Device lockdown handshake, pairing management, and mobile services. |
| **`plist.dll` / `libplist.dll`** | libimobiledevice | Apple Binary & XML Property List (bplist00) serializer/deserializer. |
| **`libwxaus.dll`** | Apowersoft (*WangXu Apple USB Service*) | Custom bridge DLL managing USB screen session lifecycle (`initUsbScreen`, `setPort`, `startUsbScreen`). |
| **`WXTcpMedia.dll`** | Apowersoft | Local loopback TCP socket listener and media packet demuxer. |
| **`libairplay.dll`** | Apowersoft | AirPlay video receiver, FairPlay key exchange, and screen mirror server. |
| **`libshairplay-1.dll`** | ShairPlay fork | RTSP/RAOP audio and session control negotiation engine. |
| **`dnssd.dll` / `Bonjour64.msi`** | Apple Inc. | Apple Bonjour mDNS Zeroconf engine for wireless service discovery. |
| **`libffmpeg.dll`** (~30 MB) | FFmpeg Project | Multi-format video/audio decoding core (H.264, HEVC, AAC). |
| **`libhwcodec.dll`** | Custom | Hardware acceleration abstraction (DirectX Video Acceleration DXVA2 / D3D11VA / Intel QSV / NVDEC). |
| **`SDL2.dll` & `SDL2_image.dll`** | Simple DirectMedia Layer | Cross-platform video window surface and low-latency audio rendering. |

---

## 3. Communication & Protocol Specifications

### Transport Layer: USB Multiplexing & Port Forwarding
1. **Daemon Connection**:
   - The PC client opens a stream socket to `127.0.0.1:27015`.
   - On Linux/macOS, this connects to `/var/run/usbmuxd`; on Windows, usbmuxd listens on loopback TCP port `27015`.
2. **Device Discovery (`Listen` / `Subscribe`)**:
   - The PC client sends a plist packet with `MessageType`: `"Listen"`.
   - usbmuxd responds with asynchronous events when devices attach or detach:
     ```xml
     <plist version="1.0">
     <dict>
         <key>MessageType</key><string>Attached</string>
         <key>DeviceID</key><integer>3</integer>
         <key>Properties</key>
         <dict>
             <key>ConnectionSpeed</key><integer>480000000</integer>
             <key>ConnectionType</key><string>USB</string>
             <key>DeviceID</key><integer>3</integer>
             <key>SerialNumber</key><string>[Device_UDID]</string>
         </dict>
     </dict>
     </plist>
     ```
3. **Tunnel Establishment (`Connect`)**:
   - To establish a socket connection with a port running inside the iOS device, the host sends:
     ```xml
     <plist version="1.0">
     <dict>
         <key>MessageType</key><string>Connect</string>
         <key>DeviceID</key><integer>3</integer>
         <key>PortNumber</key><integer>[Target_Port_In_Network_Byte_Order]</integer>
     </dict>
     </plist>
     ```
   - Upon receiving a result code of `0` (`Success`), the usbmuxd socket transparently transforms into a raw, full-duplex TCP stream connected to that port on the iOS device.

---

### Control Plane: Authentication, Pairing & State Machine

#### USB Pairing & Trust Sequence
Prior to establishing custom screen data sockets, the host must guarantee that the iOS device trusts the computer:
1. **Lockdown Session Initialization**: Connect to port `62078` (Apple Lockdown daemon `lockdownd`).
2. **Query Type**: Send `QueryType` request to verify the service status.
3. **Pair Record Verification**:
   - Reads host pairing records from `%ProgramData%\Apple\Lockdown` (or local storage).
   - If untrusted, sends `lockdownd_set_untrusted_host_buid` and polls until the user accepts the "Trust This Computer" prompt on iOS.
4. **Validation**: Calls `lockdownd_validate_pair` using the stored certificate pair (Host Certificate + Device Certificate).

#### AirPlay Wireless Control Plane (RTSP / RAOP)
For wireless mirroring, the control plane operates over standard RTSP sessions:
* **Service Advertisement**: Apple Bonjour registers:
  - `_airplay._tcp` on port **7000** (Features: `0x5A7FFFF7,0x1E`)
  - `_raop._tcp` on port **5000** (Audio & session negotiation)
* **Handshake Sequence**:
  1. `OPTIONS * RTSP/1.0` -> Receiver returns supported methods: `ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER`.
  2. `POST /pair-setup` & `POST /pair-verify` -> Curve25519 / Ed25519 key exchange generating shared AES session keys.
  3. `POST /fp-setup` -> FairPlay DRM setup stage 1 & 2 for encrypted screen mirroring.
  4. `SETUP rtsp://... RTSP/1.0` -> Establishes transport parameters:
     `Transport: RTP/AVP/TCP;unicast;interleaved=0-1;mode=record;server_port=7100`
  5. `RECORD rtsp://... RTSP/1.0` -> Starts stream transmission.
  6. `GET_PARAMETER / SET_PARAMETER` -> Periodically exchanged as a heartbeat / keep-alive mechanism and volume/display mode update.

---

### Data Plane: Video/Audio Framing & Codec Specifications

#### Packet Framing Format (Interleaved Stream)
The raw stream transmitted over the TCP tunnel consists of interleaved packets:
```
+---------------+---------------+-------------------------------+-------------------------+
| Magic Byte    | Channel ID    | Payload Length (16-bit BE)    | Payload Data            |
| 0x24 ('$')    | 0x00 or 0x01  | uint16 (0x0000 - 0xFFFF)      | [RTP Header + NAL Unit] |
+---------------+---------------+-------------------------------+-------------------------+
|<--- 1 byte -->|<--- 1 byte -->|<---------- 2 bytes ---------->|<----- N bytes --------->|
```
* **Channel `0x00`**: Video stream payloads.
* **Channel `0x01`**: Control / timing feedback packets.

#### Payload Structure (RTP Header + Video Payload)
Inside the interleaved payload:
* **RTP Header (12 bytes)**:
  - Byte 0: Version (`2`), Padding (`0`), Extension (`0`), CSRC Count (`0`) $\rightarrow$ `0x80`
  - Byte 1: Marker bit (set on the last slice of a video frame) + Payload Type (e.g., `96` dynamic)
  - Bytes 2-3: Sequence number (monotonic 16-bit integer for drop detection)
  - Bytes 4-7: Presentation Timestamp (PTS, 32-bit integer, 90 kHz clock)
  - Bytes 8-11: Synchronization Source (SSRC) identifier
* **NAL Unit Framing (Annex B or AVCC Format)**:
  - Parameter sets (**SPS** - Sequence Parameter Set, **PPS** - Picture Parameter Set, **VPS** in HEVC) are transmitted at stream initiation and before each IDR keyframe (NAL type `0x05` in H.264 / `0x13-0x14` in HEVC).
  - Delimiters: 4-byte length prefix (`AVCC`) or 4-byte start code `0x00 0x00 0x00 0x01` (`Annex B`).

---

## 4. iOS Companion App Role

To achieve ultra-low-latency 60 FPS mirroring over a wired USB cable, modern mirroring apps avoid the Wi-Fi AirPlay overhead by using an iOS Broadcast Extension:

### Screen Capture via ReplayKit
* **Extension Target**: A lightweight `RPBroadcastSampleHandler` packaged inside an iOS Companion App.
* **API Entry Point**:
  ```swift
  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
      switch sampleBufferType {
      case .video:
          // Extract CVPixelBuffer and feed into VideoToolbox
          encodeFrame(sampleBuffer)
      case .audioApp, .audioMic:
          // Encode AAC audio frames
          encodeAudio(sampleBuffer)
      @unknown default:
          break
      }
  }
  ```

### Hardware Compression (VideoToolbox)
* Creates a `VTCompressionSession` configuring:
  - `kVTCompressionPropertyKey_RealTime`: `kCFBooleanTrue`
  - `kVTCompressionPropertyKey_ProfileLevel`: `kVTProfileLevel_H264_High_AutoLevel`
  - `kVTCompressionPropertyKey_AverageBitRate`: 10–25 Mbps
  - `kVTCompressionPropertyKey_MaxKeyFrameInterval`: 60 (1 keyframe per second)
  - `kVTCompressionPropertyKey_AllowFrameReordering`: `kCFBooleanFalse` (disables B-frames for zero latency)
* The output callback receives `CMSampleBuffer` containing elementary H.264/HEVC NAL units with parameter sets.

### Networking to USB Tunnel Interface
Because iOS sandboxing prevents arbitrary network listeners from opening wide firewalls, the iOS Companion App/Extension uses one of two architectures:
1. **Local Server Architecture**:
   - The iOS extension binds a lightweight BSD socket server on `127.0.0.1:[Port]` (e.g., `127.0.0.1:15333` or dynamically assigned).
   - The PC client issues a usbmux `Connect` request to that port.
   - The iOS extension accepts the connection and begins streaming encoded video frames.
2. **Reverse Tunnel Architecture**:
   - The PC runs a local server sink (`WXTcpMedia`), and usbmux/reverse proxy forwards device traffic to the PC socket.

---

## 5. Implementation Blueprint for a Custom Clone (AppleCast)

To build a high-performance open-source clone without legacy vendor dependencies, implement the following four modular layers:

```
+-----------------------------------------------------------------------------------------------+
|                                      APPLECAST ARCHITECTURE                                   |
+-----------------------------------------------------------------------------------------------+
|                                                                                               |
|  [ Module 1: Usbmux Client ]                                                                  |
|  - Connect to 127.0.0.1:27015                                                                 |
|  - Parse plist Attach/Detach events                                                           |
|  - Issue 'Connect' to Target Port                                                             |
|                                                                                               |
|                                     |  Raw TCP Stream                                         |
|                                     v                                                         |
|  [ Module 2: Protocol Parser & Demuxer ]                                                      |
|  - Strip 4-byte RTP Interleaved Header ('$' | Ch | Len)                                       |
|  - Parse 12-byte RTP Header & extract 90 kHz PTS                                              |
|  - Extract SPS / PPS Parameter Sets and assemble Annex B NALUs                                |
|                                                                                               |
|                                     |  Continuous Elementary Video Stream                     |
|                                     v                                                         |
|  [ Module 3: Hardware Decoder & Renderer ]                                                    |
|  - FFmpeg (libavcodec) / Windows Media Foundation (MF)                                        |
|  - D3D11VA / DXVA2 Hardware Acceleration                                                      |
|  - Render directly to DirectX 11 / SwapChain / SDL2 Surface                                  |
|                                                                                               |
+-----------------------------------------------------------------------------------------------+
```

### Module 1: USB Multiplexer Client (PC Side)
* **Language/Framework**: C#, C++, or Rust.
* **Implementation Steps**:
  1. Open a TCP socket to `127.0.0.1:27015`.
  2. Send a 4-byte length prefix followed by the XML/Binary plist `{"MessageType": "Listen"}`.
  3. Listen for incoming device connections, capturing the `DeviceID` and `SerialNumber` (UDID).
  4. Perform Lockdown handshake if needed using a minimal `libimobiledevice` binding.
  5. Send `{"MessageType": "Connect", "DeviceID": id, "PortNumber": htons(target_port)}`.
  6. Verify response `{"Number": 0}`. The socket handle is now a direct tunnel to the iOS app.

### Module 2: Protocol Parser & Packet Demuxer
* **Implementation Steps**:
  1. Implement a state machine parser for RFC 2326 interleaved frames:
     - Read 1 byte: check for `$` (`0x24`).
     - Read 1 byte: stream index (`0x00` = video, `0x01` = audio).
     - Read 2 bytes: payload length $N$ (big-endian).
     - Read $N$ bytes into a ring buffer.
  2. Parse the 12-byte RTP header:
     - Verify payload type (H.264/HEVC).
     - Extract presentation timestamp (PTS) and sequence number.
  3. Convert AVCC length-prefixed NALUs to Annex B format (`0x00000001` start codes) before feeding to the decoder.
  4. Cache the latest SPS and PPS packets so incoming IDR keyframes can always be decoded immediately upon stream connection or resolution switch.

### Module 3: Hardware Video Decoder & Rendering Canvas
* **Implementation Steps**:
  1. Initialize `libavcodec` with hardware acceleration enabled:
     - Codec: `AV_CODEC_ID_H264` or `AV_CODEC_ID_HEVC`.
     - Hardware device: `AV_HWDEVICE_TYPE_D3D11VA` (or `DXVA2`).
  2. Set low-latency parser flags:
     - `AV_CODEC_FLAG_LOW_DELAY`
     - `threads = 1` or slice-based multi-threading to eliminate decode buffering delay.
  3. Feed incoming NAL packets into `avcodec_send_packet()` and receive decoded frames via `avcodec_receive_frame()`.
  4. Transfer the decoded GPU texture surface directly to a DirectX 11 SwapChain or SDL2 Texture for 60 FPS presentation with $< 15$ ms display latency.

### Module 4: iOS Companion App & Broadcast Extension
* **Implementation Steps**:
  1. Create an iOS application with a **Broadcast Upload Extension** target (`RPBroadcastSampleHandler`).
  2. In `broadcastStarted(withSetupInfo:)`:
     - Open a BSD TCP server socket listening on loopback port (e.g. `15333`).
     - Configure `VTCompressionSession` for real-time baseline/high H.264 encoding at $1920 \times 1080$ @ 60 FPS.
  3. In `processSampleBuffer(_:with:)`:
     - Pass video `CVPixelBuffer` frames into the compression session.
  4. In the compression output callback:
     - Package the encoded NALUs into interleaved RTP packets.
     - Send the formatted buffer over the accepted client socket.
  5. The PC client detects the connection over usbmuxd and immediately begins rendering the live screen.
