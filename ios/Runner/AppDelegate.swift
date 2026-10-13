import Flutter
import UIKit
import ReplayKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let controller = engineBridge.pluginRegistry.registrar(forPlugin: "AppleCastCompanion")
    let channel = FlutterMethodChannel(
      name: "com.applecast.mirror/control",
      binaryMessenger: engineBridge.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }
      if call.method == "launchBroadcastPicker" {
        self.presentBroadcastPicker()
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func presentBroadcastPicker() {
    DispatchQueue.main.async {
      let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
      pickerView.preferredExtension = "com.applecast.companion.extension"
      pickerView.showsMicrophoneButton = false

      // Programmatically trigger button tap in pickerView to open system broadcast modal
      for subview in pickerView.subviews {
        if let button = subview as? UIButton {
          button.sendActions(for: .allTouchEvents)
          break
        }
      }
    }
  }
}
