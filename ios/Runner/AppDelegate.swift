import Flutter
import UIKit
import ReplayKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private let appGroup = "group.applecast.mirror"
  private let defaultPort: UInt16 = 15333

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Synchronize initial broadcast configuration to shared App Group container
    synchronizeBroadcastConfiguration(targetPort: defaultPort)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(
      name: "com.applecast.mirror/control",
      binaryMessenger: messenger
    )

    // Register native PlatformView factory for RPSystemBroadcastPickerView
    // This allows Flutter to embed Apple's real, native broadcast picker button
    // which users tap directly, avoiding UIKit programmatic touch suppression.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleCastBroadcastPicker")
    let factory = BroadcastPickerViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "com.applecast.mirror/broadcast_picker")

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
      } else if call.method == "getExtensionStatus" {
        let defaults = UserDefaults(suiteName: self.appGroup)
        let status = defaults?.string(forKey: "extension_status") ?? "STOPPED"
        let port = defaults?.integer(forKey: "extension_active_port") ?? Int(self.defaultPort)
        let startTime = defaults?.double(forKey: "extension_start_time") ?? 0.0
        let socketState = defaults?.string(forKey: "extension_socket_state") ?? "IDLE"
        result([
          "status": status,
          "port": port,
          "startTime": startTime,
          "socketState": socketState
        ])
      } else if call.method == "getExtensionBundleId" {
        result(self.resolveExtensionBundleIdentifier())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Synchronizes dynamic port and encoding profiles to App Group UserDefaults
  /// As reverse-engineered in brainapple.md Section 3 & 8 (wxiosserverport key)
  private func synchronizeBroadcastConfiguration(targetPort: UInt16) {
    if let defaults = UserDefaults(suiteName: appGroup) {
      defaults.set(Int(targetPort), forKey: "wxiosserverport")
      defaults.set(0, forKey: "kGroupReplayKitRecordType") // 0 = Custom Local TCP stream
      defaults.set(false, forKey: "kGroupMirrorVoiceSwitch")
      defaults.set(60, forKey: "videoFps")
      defaults.set(8_000_000, forKey: "videoBitrate") // 8 Mbps safe budget under 50MB Jetsam limit
      defaults.set(1080, forKey: "videoResolution")
      defaults.synchronize()
    }
  }

  /// Dynamically detects the runtime Bundle Identifier of AppleCastExtension.appex
  /// Sideloaders (AltStore, Sideloadly) rewrite both the host app and extension Bundle IDs
  /// upon re-signing. Reading the actual CFBundleIdentifier directly from the installed .appex
  /// guarantees that RPSystemBroadcastPickerView matches the exact re-signed extension ID.
  func resolveExtensionBundleIdentifier() -> String {
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
  /// Embeds picker into window hierarchy and sends action to internal UIButton
  private func presentBroadcastPicker() {
    DispatchQueue.main.async {
      let extensionId = self.resolveExtensionBundleIdentifier()
      NSLog("[AppleCast Host] Presenting RPSystemBroadcastPickerView with target: %@", extensionId)

      let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
      pickerView.preferredExtension = extensionId
      pickerView.showsMicrophoneButton = false
      pickerView.alpha = 0.05

      // Attach to active window or root view
      if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first {
        window.addSubview(pickerView)
      } else if let rootVC = self.window?.rootViewController {
        rootVC.view.addSubview(pickerView)
      }

      // Programmatically trigger button tap in pickerView to open system broadcast modal
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

/// Native PlatformView for embedding RPSystemBroadcastPickerView directly in Flutter UI.
/// Tapping this view is a genuine user touch directly on Apple's UI, guaranteeing
/// reliable invocation of the ReplayKit broadcast sheet without synthetic touch suppression.
class BroadcastPickerPlatformView: NSObject, FlutterPlatformView {
  private let containerView: UIView
  private let pickerView: RPSystemBroadcastPickerView

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    self.containerView = UIView(frame: frame)
    let pickerSize = CGSize(
      width: frame.size.width > 0 ? frame.size.width : 60,
      height: frame.size.height > 0 ? frame.size.height : 60
    )
    self.pickerView = RPSystemBroadcastPickerView(frame: CGRect(origin: .zero, size: pickerSize))
    super.init()

    if let args = args as? [String: Any],
       let extId = args["preferredExtension"] as? String, !extId.isEmpty {
      pickerView.preferredExtension = extId
      NSLog("[AppleCast PlatformView] Initialized RPSystemBroadcastPickerView with preferredExtension: %@", extId)
    }
    pickerView.showsMicrophoneButton = false
    pickerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    containerView.addSubview(pickerView)
  }

  func view() -> UIView {
    return containerView
  }
}

class BroadcastPickerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return BroadcastPickerPlatformView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}
