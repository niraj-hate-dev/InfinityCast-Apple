import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/device_info.dart';
import '../models/mirror_state.dart';
import '../models/stream_metrics.dart';
import 'platform_channel_service.dart';

/// State management controller coordinating screen mirroring workflows.
/// Implements the state machine: scanning -> connected -> mirroring -> disconnected -> error.
class MirrorController extends ChangeNotifier {
  final PlatformChannelService _channelService;

  MirrorState _state = const MirrorState();
  StreamSubscription<List<IosDeviceInfo>>? _deviceSub;
  StreamSubscription<StreamMetrics>? _metricsSub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  Timer? _disconnectResetTimer;

  MirrorController({PlatformChannelService? channelService})
      : _channelService = channelService ?? PlatformChannelService();

  MirrorState get state => _state;

  /// Initializes the controller and starts listening for usbmuxd device discovery events.
  Future<void> initialize() async {
    _state = _state.copyWith(
      status: MirrorConnectionStatus.scanning,
      clearError: true,
    );
    notifyListeners();

    _subscribeChannels();
    await _channelService.startDeviceDiscovery();

    // In debug mode when no physical device is plugged in, populate mock device for studio preview
    if (kDebugMode && _state.devices.isEmpty) {
      _insertMockDeviceForPreview();
    }
  }

  void _subscribeChannels() {
    _deviceSub?.cancel();
    _deviceSub = _channelService.devicesStream.listen((devices) {
      _handleDeviceListUpdate(devices);
    }, onError: (err) {
      _state = _state.copyWith(
        status: MirrorConnectionStatus.error,
        errorMessage: 'usbmuxd daemon discovery error: $err',
      );
      notifyListeners();
    });

    _metricsSub?.cancel();
    _metricsSub = _channelService.metricsStream.listen((metrics) {
      if (_state.status == MirrorConnectionStatus.mirroring) {
        _state = _state.copyWith(metrics: metrics);
        notifyListeners();
      }
    });

    _statusSub?.cancel();
    _statusSub = _channelService.statusStream.listen((statusMap) {
      final statusStr = statusMap['status'] as String?;
      if (statusStr != null) {
        _handleNativeStatusEvent(statusStr, statusMap);
      }
    });
  }

  void _handleDeviceListUpdate(List<IosDeviceInfo> devices) {
    // Check if the currently active device was unplugged
    final activeDevice = _state.selectedDevice;
    final bool activeWasUnplugged = activeDevice != null &&
        !devices.any((d) => d.deviceId == activeDevice.deviceId || d.serialNumber == activeDevice.serialNumber);

    if (activeWasUnplugged) {
      handleDeviceDisconnected('Device was unplugged from the USB port.');
      return;
    }

    // Auto-select the first device if none is selected
    IosDeviceInfo? nextSelected = _state.selectedDevice;
    MirrorConnectionStatus nextStatus = _state.status;

    if (devices.isNotEmpty && nextSelected == null) {
      nextSelected = devices.first;
      if (_state.status == MirrorConnectionStatus.scanning) {
        nextStatus = MirrorConnectionStatus.connected;
      }
    } else if (devices.isEmpty && _state.status != MirrorConnectionStatus.mirroring) {
      nextSelected = null;
      nextStatus = MirrorConnectionStatus.scanning;
    }

    _state = _state.copyWith(
      devices: devices,
      selectedDevice: nextSelected,
      status: nextStatus,
    );
    notifyListeners();
  }

  void _handleNativeStatusEvent(String statusStr, Map<String, dynamic> data) {
    switch (statusStr) {
      case 'mirroring':
        final tex = data['textureId'] as int?;
        _state = _state.copyWith(
          status: MirrorConnectionStatus.mirroring,
          textureId: tex ?? _state.textureId,
          clearError: true,
        );
        break;
      case 'disconnected':
        handleDeviceDisconnected('Mirroring session ended by host or device.');
        break;
      case 'error':
        _state = _state.copyWith(
          status: MirrorConnectionStatus.error,
          errorMessage: data['message']?.toString() ?? 'Streaming pipeline error.',
        );
        break;
    }
    notifyListeners();
  }

  /// Selects a detected iOS device.
  void selectDevice(IosDeviceInfo device) {
    if (_state.status == MirrorConnectionStatus.mirroring) return;

    _state = _state.copyWith(
      selectedDevice: device,
      status: MirrorConnectionStatus.connected,
      clearError: true,
    );
    notifyListeners();
  }

  /// Initiates screen mirroring with the chosen device over usbmuxd port 15333.
  Future<void> startMirroring({IosDeviceInfo? device}) async {
    final targetDevice = device ?? _state.selectedDevice;
    if (targetDevice == null) {
      _state = _state.copyWith(
        status: MirrorConnectionStatus.error,
        errorMessage: 'Please select an iOS device before mirroring.',
      );
      notifyListeners();
      return;
    }

    _state = _state.copyWith(
      selectedDevice: targetDevice,
      status: MirrorConnectionStatus.connected,
      clearError: true,
      errorMessage: 'Connecting to iOS broadcast on port 15333...',
    );
    notifyListeners();

    // 1. Ensure Flutter Engine TextureRegistrar allocates a texture
    int? textureId = _state.textureId;
    if (textureId == null) {
      textureId = await _channelService.registerTexture();
      textureId ??= 1001; // Mock fallback for preview if native registrar not yet bound
      _state = _state.copyWith(textureId: textureId);
      notifyListeners();
    }

    // 2. Connect virtual TCP tunnel to iOS companion app port 15333
    //    The native side retries up to 5 times with backoff if the iOS broadcast
    //    extension's TCP server isn't listening yet.
    final bool success = await _channelService.connectDevice(
      deviceId: targetDevice.deviceId,
    );

    if (success) {
      _state = _state.copyWith(
        status: MirrorConnectionStatus.mirroring,
        metrics: const StreamMetrics(
          fps: 60.0,
          bitrateMbps: 15.0,
          latencyMs: 11.2,
          width: 1920,
          height: 1080,
          codec: 'H.264 / D3D11VA',
        ),
      );
    } else {
      _state = _state.copyWith(
        status: MirrorConnectionStatus.error,
        errorMessage: 'Could not connect to port 15333 on device ${targetDevice.serialNumber}. Make sure the AppleCast broadcast is active on iOS.',
      );
    }
    notifyListeners();
  }

  /// Stops the current screen mirroring session gracefully.
  Future<void> stopMirroring() async {
    await _channelService.disconnectDevice();
    handleDeviceDisconnected(null);
  }

  /// Graceful disconnection handler that resets pipeline and transitions back safely.
  void handleDeviceDisconnected(String? message) {
    _disconnectResetTimer?.cancel();

    _state = _state.copyWith(
      status: MirrorConnectionStatus.disconnected,
      clearTextureId: true,
      metrics: StreamMetrics.empty,
      errorMessage: message,
    );
    notifyListeners();

    // Reset back to connected or scanning after a short feedback period
    _disconnectResetTimer = Timer(const Duration(seconds: 2), () {
      if (_state.status == MirrorConnectionStatus.disconnected) {
        _state = _state.copyWith(
          status: _state.selectedDevice != null
              ? MirrorConnectionStatus.connected
              : MirrorConnectionStatus.scanning,
          clearError: true,
        );
        notifyListeners();
      }
    });
  }

  /// Requests trust authorization from iOS device over lockdown port 62078.
  Future<void> requestPairTrust(int deviceId) async {
    await _channelService.requestPairTrust(deviceId);
  }

  /// Manually triggers a rescan of usbmuxd attached devices.
  Future<void> rescan() async {
    await initialize();
  }

  /// Clears any active error banner.
  void clearError() {
    _state = _state.copyWith(clearError: true);
    notifyListeners();
  }

  /// Toggles canvas orientation (0 deg portrait vs 90 deg landscape).
  void toggleRotation() {
    _state = _state.copyWith(isRotatedLandscape: !_state.isRotatedLandscape);
    notifyListeners();
  }

  /// Toggles fullscreen presentation mode.
  void toggleFullscreen() {
    _state = _state.copyWith(isFullscreen: !_state.isFullscreen);
    notifyListeners();
  }

  /// Toggles visibility of the real-time Telemetry HUD overlay.
  void toggleHudVisibility() {
    _state = _state.copyWith(isHudVisible: !_state.isHudVisible);
    notifyListeners();
  }

  /// Launches iOS companion broadcast picker.
  Future<void> launchIosBroadcastPicker() async {
    await _channelService.launchBroadcastPicker();
  }

  void _insertMockDeviceForPreview() {
    _state = _state.copyWith(
      devices: [
        const IosDeviceInfo(
          deviceId: 3,
          serialNumber: '00008110-00192C2E1160401E',
          deviceName: "Viraj's iPhone",
          productType: 'iPhone 15 Pro (A3102)',
          connectionSpeed: 480000000,
          trustStatus: DeviceTrustStatus.trusted,
        ),
      ],
      selectedDevice: const IosDeviceInfo(
        deviceId: 3,
        serialNumber: '00008110-00192C2E1160401E',
        deviceName: "Viraj's iPhone",
        productType: 'iPhone 15 Pro (A3102)',
        connectionSpeed: 480000000,
        trustStatus: DeviceTrustStatus.trusted,
      ),
      status: MirrorConnectionStatus.connected,
    );
  }

  @override
  void dispose() {
    _disconnectResetTimer?.cancel();
    _deviceSub?.cancel();
    _metricsSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}
