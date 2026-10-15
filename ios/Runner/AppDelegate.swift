import Flutter
import UIKit
import ReplayKit
import Network
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private let appGroup = "group.applecast.mirror"
  private let defaultPort: UInt16 = 15333
  private let controlPort: UInt16 = 15332

  private var flutterChannel: FlutterMethodChannel?
  private var controlListener: NWListener?
  private var controlConnection: NWConnection?
  private var isLaptopConnected = false
  private var laptopClientName = ""
  private var laptopLastSeen: Double = 0

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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func screenCaptureChanged() {
    let isCaptured = UIScreen.main.isCaptured
    NSLog("[AppleCast Host] UIScreen.capturedDidChangeNotification: isCaptured = %@", String(isCaptured))
    DispatchQueue.main.async { [weak self] in
      self?.flutterChannel?.invokeMethod("onScreenCaptureChanged", ["isCaptured": isCaptured])
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
        let isCaptured = UIScreen.main.isCaptured
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

  /// Starts a local loopback TCP listener on port 15332 for Laptop / usbmuxd connection detection
  private func startControlServer(port: UInt16) {
    do {
      let tcpOptions = NWProtocolTCP.Options()
      tcpOptions.noDelay = true
      let params = NWParameters(tls: nil, tcp: tcpOptions)
      params.requiredInterfaceType = .loopback
      params.allowLocalEndpointReuse = true

      let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? 15332)
      listener.stateUpdateHandler = { state in
        NSLog("[AppleCast Host] Control listener on port %d state: %@", port, String(describing: state))
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self = self else { return }
        NSLog("[AppleCast Host] SUCCESS: Laptop connected to control port %d via usbmuxd tunnel!", port)
        self.controlConnection?.cancel()
        self.controlConnection = connection
        self.isLaptopConnected = true
        self.laptopClientName = "Windows PC (usbmuxd)"
        self.laptopLastSeen = Date().timeIntervalSince1970

        DispatchQueue.main.async {
          self.flutterChannel?.invokeMethod("onLaptopDetected", [
            "connected": true,
            "name": self.laptopClientName
          ])
        }

        self.receiveControlMessage(connection: connection)
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
      }
      self.controlListener = listener
      listener.start(queue: DispatchQueue.global(qos: .userInitiated))
      NSLog("[AppleCast Host] Control listener initialized on port %d (loopback)", port)
    } catch {
      NSLog("[AppleCast Host] Control listener failed on port %d: %@", port, String(describing: error))
    }
  }

  private func receiveControlMessage(connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }
      if let data = data, !data.isEmpty,
         let text = String(data: data, encoding: .utf8) {
        NSLog("[AppleCast Host] Control packet received: %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.isLaptopConnected = true
        self.laptopLastSeen = Date().timeIntervalSince1970
        if text.contains("Windows") {
          self.laptopClientName = "Windows PC (AppleCast)"
        }

        let isCaptured = UIScreen.main.isCaptured
        let resp = "{\"status\":\"OK\",\"isCaptured\":\(isCaptured),\"streamingPort\":\(self.defaultPort),\"model\":\"\(UIDevice.current.model)\"}\n"
        if let respData = resp.data(using: .utf8) {
          connection.send(content: respData, completion: .idempotent)
        }
      }

      if isComplete || error != nil {
        self.isLaptopConnected = false
        DispatchQueue.main.async {
          self.flutterChannel?.invokeMethod("onLaptopDetected", [
            "connected": false,
            "name": ""
          ])
        }
      } else {
        self.receiveControlMessage(connection: connection)
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
}
