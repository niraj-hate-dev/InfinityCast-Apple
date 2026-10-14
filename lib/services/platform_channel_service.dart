import 'dart:async';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../models/device_info.dart';
import '../models/stream_metrics.dart';

/// Service interfacing with native Windows C++ and iOS Swift host implementations.
/// Manages MethodChannel RPCs and EventChannel continuous streams.
class PlatformChannelService {
  final MethodChannel _controlChannel;
  final EventChannel _devicesChannel;
  final EventChannel _metricsChannel;
  final EventChannel _statusChannel;

  PlatformChannelService({
    MethodChannel? controlChannel,
    EventChannel? devicesChannel,
    EventChannel? metricsChannel,
    EventChannel? statusChannel,
  })  : _controlChannel = controlChannel ?? const MethodChannel(AppleCastConstants.controlChannel),
        _devicesChannel = devicesChannel ?? const EventChannel(AppleCastConstants.eventChannelDevices),
        _metricsChannel = metricsChannel ?? const EventChannel(AppleCastConstants.eventChannelMetrics),
        _statusChannel = statusChannel ?? const EventChannel(AppleCastConstants.eventChannelStatus);

  /// Registers a native video texture (Direct3D 11 / PixelBuffer) with Flutter's TextureRegistrar.
  /// Returns the allocated 64-bit texture ID.
  Future<int?> registerTexture() async {
    try {
      final dynamic result = await _controlChannel.invokeMethod('registerTexture');
      if (result is int) return result;
      if (result is num) return result.toInt();
      return null;
    } on PlatformException {
      // In development/mock environments when native plugin isn't yet compiled, return a fallback ID
      // or rethrow depending on mode.
      return null;
    }
  }

  /// Unregisters the native video texture and releases D3D11 / pixel buffer handles.
  Future<bool> unregisterTexture(int textureId) async {
    try {
      final bool? success = await _controlChannel.invokeMethod<bool>(
        'unregisterTexture',
        {'textureId': textureId},
      );
      return success ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Starts listening for usbmuxd device events on loopback port 27015.
  Future<bool> startDeviceDiscovery() async {
    try {
      final bool? success = await _controlChannel.invokeMethod<bool>('startDeviceDiscovery');
      return success ?? true;
    } on PlatformException {
      return false;
    }
  }

  /// Connects to the specified iOS device by issuing a usbmuxd 'Connect' request to target port.
  Future<bool> connectDevice({
    required int deviceId,
    int port = AppleCastConstants.defaultDeviceStreamingPort,
  }) async {
    try {
      final bool? success = await _controlChannel.invokeMethod<bool>('connectDevice', {
        'deviceId': deviceId,
        'port': port,
      });
      return success ?? true;
    } on PlatformException {
      return false;
    }
  }

  /// Closes active TCP virtual tunnel and stops decoding pipeline.
  Future<bool> disconnectDevice() async {
    try {
      final bool? success = await _controlChannel.invokeMethod<bool>('disconnectDevice');
      return success ?? true;
    } on PlatformException {
      return false;
    }
  }

  /// Triggers Apple Lockdown pairing trust handshake sequence (port 62078).
  Future<bool> requestPairTrust(int deviceId) async {
    try {
      final bool? success = await _controlChannel.invokeMethod<bool>('requestPairTrust', {
        'deviceId': deviceId,
      });
      return success ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// iOS Companion Specific: Triggers RPSystemBroadcastPickerView presentation
  Future<bool> launchBroadcastPicker() async {
    try {
      final bool? success = await _controlChannel.invokeMethod<bool>('launchBroadcastPicker', {
        'extensionBundleId': AppleCastConstants.iosExtensionBundleId,
      });
      return success ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// iOS Companion Specific: Queries runtime resolved extension bundle identifier
  Future<String?> getExtensionBundleId() async {
    try {
      final String? bundleId = await _controlChannel.invokeMethod<String>('getExtensionBundleId');
      return bundleId;
    } on PlatformException {
      return null;
    }
  }

  /// iOS Companion Specific: Queries active broadcast extension status from App Group UserDefaults
  Future<Map<String, dynamic>> getExtensionStatus() async {
    try {
      final dynamic result = await _controlChannel.invokeMethod('getExtensionStatus');
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return {'status': 'STOPPED', 'port': AppleCastConstants.defaultDeviceStreamingPort};
    } on PlatformException {
      return {'status': 'UNAVAILABLE', 'port': AppleCastConstants.defaultDeviceStreamingPort};
    }
  }

  /// Stream of attached iOS devices received from usbmuxd daemon.
  Stream<List<IosDeviceInfo>> get devicesStream {
    return _devicesChannel.receiveBroadcastStream().map((dynamic event) {
      if (event is List) {
        return event
            .map((item) => IosDeviceInfo.fromMap(Map<dynamic, dynamic>.from(item as Map)))
            .toList();
      }
      return <IosDeviceInfo>[];
    }).handleError((error) {
      // Return empty list on channel errors
      return <IosDeviceInfo>[];
    });
  }

  /// Stream of hardware demuxer & decoder telemetry updates.
  Stream<StreamMetrics> get metricsStream {
    return _metricsChannel.receiveBroadcastStream().map((dynamic event) {
      if (event is Map) {
        return StreamMetrics.fromMap(event);
      }
      return StreamMetrics.empty;
    }).handleError((error) {
      return StreamMetrics.empty;
    });
  }

  /// Stream of connection state updates from native controller.
  Stream<Map<String, dynamic>> get statusStream {
    return _statusChannel.receiveBroadcastStream().map((dynamic event) {
      if (event is Map) {
        return Map<String, dynamic>.from(event);
      }
      return <String, dynamic>{};
    }).handleError((error) {
      return <String, dynamic>{};
    });
  }
}
