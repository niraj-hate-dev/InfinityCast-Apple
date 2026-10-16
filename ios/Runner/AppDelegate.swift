import Flutter
import UIKit
import ReplayKit
import Network
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private let appGroup = "group.applecast.mirror"
  private let defaultPort: UInt16 = 25334
  private let controlPort: UInt16 = 25333

  private var flutterChannel: FlutterMethodChannel?
  private var controlListener: NWListener?
  private var controlConnection: NWConnection?
  private var isLaptopConnected = false
  private var laptopClientName = ""
  private var laptopLastSeen: Double = 0
  private var isScreenBroadcastActive = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Enable battery monitoring to detect physical USB cable power link
    UIDevice.current.isBatteryMonitoringEnabled = true

    // Synchronize initial broadcast configuration
    synchronizeBroadcastConfiguration(targetPort: defaultPort)

    // Listen for system screen recording changes (fires when ReplayKit starts/stops)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenCaptureChanged),
      name: UIScreen.capturedDidChangeNotification,
      object: nil
    )

    // Start background control & laptop detector listener on port 15332
    startControlServer(port: controlPort)

    // Listen for Darwin IPC notifications from AppleCastExtension (like MMWormhole in ApowerMirror)
    setupDarwinNotificationObservers()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func screenCaptureChanged() {
    let isCaptured = UIScreen.main.isCaptured
    self.isScreenBroadcastActive = isCaptured
    NSLog("[AppleCast Host] UIScreen.capturedDidChangeNotification: isCaptured = %@", String(isCaptured))
    DispatchQueue.main.async { [weak self] in
      self?.flutterChannel?.invokeMethod("onScreenCaptureChanged", arguments: ["isCaptured": isCaptured])
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(
      name: "com.applecast.mirror/control",
      binaryMessenger: messenger
    )
    self.flutterChannel = channel

    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }
      if call.method == "launchBroadcastPicker" {
        var port = self.defaultPort
        if let args = call.arguments as? [String: Any],
           let customPort = args["port"] as? Int, customPort > 0 {
          port = UInt16(customPort)
        }
        self.synchronizeBroadcastConfiguration(targetPort: port)
        self.presentBroadcastPicker()
        result(true)
      } else if call.method == "getDetectorStatus" || call.method == "getExtensionStatus" {
        let isCaptured = UIScreen.main.isCaptured || self.isScreenBroadcastActive
        let isCharging = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
        let now = Date().timeIntervalSince1970
        let isRecentlySeen = (self.isLaptopConnected && (now - self.laptopLastSeen < 8.0))

        let defaults = UserDefaults(suiteName: self.appGroup) ?? UserDefaults.standard
        let status = isCaptured ? "RUNNING" : (defaults.string(forKey: "extension_status") ?? "STOPPED")
        let socketState = defaults.string(forKey: "extension_socket_state") ?? (isCaptured ? "LISTENING" : "IDLE")

        result([
          "status": status,
          "isCaptured": isCaptured,
          "laptopConnected": isRecentlySeen,
          "laptopName": self.laptopClientName,
          "laptopLastSeen": self.laptopLastSeen,
          "usbCableConnected": isCharging,
          "streamingPort": Int(self.defaultPort),
          "controlPort": Int(self.controlPort),
          "socketState": socketState,
          "interfaces": self.getActiveNetworkInterfaces()
        ])
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var controlServerSocket: Int32 = -1
  private var activeControlClientSocket: Int32 = -1

  /// Starts a local BSD TCP listener on port 15332 for Laptop / usbmuxd connection detection
  private func startControlServer(port: UInt16) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }

      let sock = socket(AF_INET, SOCK_STREAM, 0)
      guard sock >= 0 else {
        NSLog("[AppleCast Host] Failed to create control socket: errno %d", errno)
        return
      }

      var opt: Int32 = 1
      setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &opt, socklen_t(MemoryLayout<Int32>.size))

      var addr = sockaddr_in()
      addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = port.bigEndian
      addr.sin_addr.s_addr = in_addr_t(0) // Bind to INADDR_ANY (0.0.0.0) so it accepts usbmuxd loopback 127.0.0.1!

      let bindRes = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }

      guard bindRes == 0 else {
        NSLog("[AppleCast Host] Failed to bind control socket on port %d: errno %d", port, errno)
        close(sock)
        return
      }

      guard listen(sock, 5) == 0 else {
        NSLog("[AppleCast Host] Failed to listen on control socket on port %d: errno %d", port, errno)
        close(sock)
        return
      }

      self.controlServerSocket = sock
      NSLog("[AppleCast Host] >>> SUCCESS: Control BSD Server listening on port %d! <<<", port)

      while true {
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &clientAddr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            accept(sock, $0, &clientLen)
          }
        }

        guard client >= 0 else { continue }

        var flag: Int32 = 1
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))

        NSLog("[AppleCast Host] >>> Client CONNECTED to control port %d! <<<", port)
        self.handleBsdControlClient(client: client)
      }
    }
  }

  private func handleBsdControlClient(client: Int32) {
    self.activeControlClientSocket = client
    self.isLaptopConnected = true
    self.laptopClientName = "Windows PC (usbmuxd)"
    self.laptopLastSeen = Date().timeIntervalSince1970

    DispatchQueue.main.async { [weak self] in
      self?.flutterChannel?.invokeMethod("onLaptopDetected", arguments: [
        "connected": true,
        "name": "Windows PC (usbmuxd)"
      ])
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { close(client); return }

      var buffer = [UInt8](repeating: 0, count: 1024)
      while true {
        let bytesRead = recv(client, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { break }

        buffer[bytesRead] = 0
        let str = String(cString: buffer)
        NSLog("[AppleCast Host] Control packet: %@", str.trimmingCharacters(in: .whitespacesAndNewlines))

        self.isLaptopConnected = true
        self.laptopLastSeen = Date().timeIntervalSince1970
        if str.contains("Windows") {
          self.laptopClientName = "Windows PC (AppleCast)"
        }

        let isCaptured = UIScreen.main.isCaptured
        let resp = "{\"status\":\"OK\",\"isCaptured\":\(isCaptured),\"streamingPort\":\(self.defaultPort),\"model\":\"\(UIDevice.current.model)\",\"name\":\"\(UIDevice.current.name)\"}\n"
        if let respData = resp.data(using: .utf8) {
          respData.withUnsafeBytes { rawPtr in
            if let ptr = rawPtr.baseAddress {
              send(client, ptr, respData.count, 0)
            }
          }
        }
      }

      NSLog("[AppleCast Host] Control client disconnected")
      close(client)
      if self.activeControlClientSocket == client {
        self.activeControlClientSocket = -1
      }
      self.isLaptopConnected = false
      DispatchQueue.main.async { [weak self] in
        self?.flutterChannel?.invokeMethod("onLaptopDetected", arguments: [
          "connected": false,
          "name": ""
        ])
      }
    }
  }

  /// Enumerates active network interfaces on device (Loopback, Personal Hotspot USB bridge, Wi-Fi)
  private func getActiveNetworkInterfaces() -> [[String: String]] {
    var interfaces: [[String: String]] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0 {
      var ptr = ifaddr
      while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }
        guard let interface = ptr?.pointee else { continue }
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
          let name = String(cString: interface.ifa_name)
          var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                      &hostname, socklen_t(hostname.count),
                      nil, 0, NI_NUMERICHOST)
          let ip = String(cString: hostname)
          interfaces.append(["name": name, "ip": ip])
        }
      }
      freeifaddrs(ifaddr)
    }
    return interfaces
  }

  /// Synchronizes dynamic port and encoding profiles to App Group UserDefaults
  private func synchronizeBroadcastConfiguration(targetPort: UInt16) {
    let defaults = UserDefaults(suiteName: appGroup) ?? UserDefaults.standard
    defaults.set(Int(targetPort), forKey: "wxiosserverport")
    defaults.set(0, forKey: "kGroupReplayKitRecordType") // 0 = Custom Local TCP stream
    defaults.set(false, forKey: "kGroupMirrorVoiceSwitch")
    defaults.set(60, forKey: "videoFps")
    defaults.set(8_000_000, forKey: "videoBitrate") // 8 Mbps safe budget under 50MB Jetsam limit
    defaults.set(1080, forKey: "videoResolution")
    defaults.synchronize()
  }

  /// Dynamically detects the runtime Bundle Identifier of AppleCastExtension.appex
  private func resolveExtensionBundleIdentifier() -> String {
    if let pluginsPath = Bundle.main.builtInPlugInsPath {
      let fileManager = FileManager.default
      if let items = try? fileManager.contentsOfDirectory(atPath: pluginsPath) {
        for item in items where item.hasSuffix(".appex") {
          let plistPath = (pluginsPath as NSString).appendingPathComponent("\(item)/Info.plist")
          if let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
             let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
             let bundleId = plist["CFBundleIdentifier"] as? String, !bundleId.isEmpty {
            NSLog("[AppleCast Host] Discovered runtime extension bundle ID from %@: %@", item, bundleId)
            return bundleId
          }
        }
      }
    }

    if let mainBundleId = Bundle.main.bundleIdentifier, !mainBundleId.isEmpty {
      let fallbackId = "\(mainBundleId).AppleCastExtension"
      NSLog("[AppleCast Host] Using fallback extension bundle ID: %@", fallbackId)
      return fallbackId
    }

    return "com.applecast.applecast.AppleCastExtension"
  }

  /// Automatically triggers RPSystemBroadcastPickerView presentation
  private func presentBroadcastPicker() {
    DispatchQueue.main.async {
      let extensionId = self.resolveExtensionBundleIdentifier()
      NSLog("[AppleCast Host] Presenting RPSystemBroadcastPickerView with target: %@", extensionId)

      let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
      pickerView.preferredExtension = extensionId
      pickerView.showsMicrophoneButton = false
      pickerView.alpha = 0.05

      if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first {
        window.addSubview(pickerView)
      } else if let rootVC = self.window?.rootViewController {
        rootVC.view.addSubview(pickerView)
      }

      for subview in pickerView.subviews {
        if let button = subview as? UIButton {
          button.sendActions(for: .touchUpInside)
          button.sendActions(for: .allTouchEvents)
          break
        }
      }
    }
  }

  // MARK: - Darwin Notifications (Cross-process IPC without App Groups)
  private func setupDarwinNotificationObservers() {
    let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let events = ["BroadcastStarted", "Finish", "PauseVideo", "ResumeVideo"]
    for event in events {
      let notificationName = CFNotificationName("com.applecast.broadcast.\(event)" as CFString)
      CFNotificationCenterAddObserver(
        darwinCenter,
        observer,
        { (_, observer, name, _, _) in
          guard let observer = observer, let name = name else { return }
          let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
          let rawName = name.rawValue as String
          let isStarted = rawName.contains("BroadcastStarted") || rawName.contains("ResumeVideo")
          NSLog("[AppleCast Host] Darwin notification received: %@ -> isRecording: %@", rawName, String(isStarted))
          appDelegate.isScreenBroadcastActive = isStarted
          DispatchQueue.main.async {
            appDelegate.flutterChannel?.invokeMethod("onScreenCaptureChanged", arguments: [
              "isCaptured": isStarted,
              "source": "darwin"
            ])
          }
        },
        notificationName.rawValue,
        nil,
        .deliverImmediately
      )
    }
  }
}
