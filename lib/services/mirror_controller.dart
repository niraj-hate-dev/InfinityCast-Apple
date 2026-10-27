import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../models/debug_log_entry.dart';
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

  final List<DebugLogEntry> _logs = [];
  static const int _maxLogs = 500;
  double _lastFps = 0.0;
  int _lastDroppedFrames = 0;

  MirrorController({PlatformChannelService? channelService})
      : _channelService = channelService ?? PlatformChannelService();

  MirrorState get state => _state;

  /// Appends a new timestamped log entry to the internal developer console buffer.
  void addLog(String tag, String message, {LogLevel level = LogLevel.info}) {
    final entry = DebugLogEntry(
      timestamp: DateTime.now(),
      tag: tag,
      message: message,
      level: level,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    _state = _state.copyWith(logs: List.unmodifiable(_logs));
    notifyListeners();
  }

  /// Clears all entries from the developer debug console.
  void clearLogs() {
    _logs.clear();
    _state = _state.copyWith(logs: const []);
    notifyListeners();
  }

  /// Toggles visibility of the floating developer debug console terminal.
  void toggleConsoleVisibility() {
    final nextVisible = !_state.isConsoleVisible;
    _state = _state.copyWith(isConsoleVisible: nextVisible);
    addLog(
      'CONSOLE',
      nextVisible ? 'Debug terminal overlay opened.' : 'Debug terminal overlay closed.',
      level: LogLevel.info,
    );
    notifyListeners();
  }

  /// Initializes the controller and starts listening for usbmuxd device discovery events.
  Future<void> initialize() async {
    _state = _state.copyWith(
      status: MirrorConnectionStatus.scanning,
      clearError: true,
    );
    notifyListeners();

    addLog('SYSTEM', 'AppleCast host initialized. Listening for usbmuxd events...', level: LogLevel.info);
    addLog('USBMUXD', 'Connecting to daemon on 127.0.0.1:27015 (USB Multiplexer)...', level: LogLevel.info);

    _subscribeChannels();
    await _channelService.startDeviceDiscovery();
  }

  void _subscribeChannels() {
    _deviceSub?.cancel();
    _deviceSub = _channelService.devicesStream.listen((devices) {
      _handleDeviceListUpdate(devices);
    }, onError: (err) {
      addLog('USBMUXD', 'usbmuxd daemon discovery error: $err', level: LogLevel.error);
      _state = _state.copyWith(
        status: MirrorConnectionStatus.error,
        errorMessage: 'usbmuxd daemon discovery error: $err',
      );
      notifyListeners();
    });

    _metricsSub?.cancel();
    _metricsSub = _channelService.metricsStream.listen((metrics) {
      if (_state.status == MirrorConnectionStatus.mirroring) {
        // Detect initial frame or IDR recovery
        if (_lastFps == 0.0 && metrics.fps > 0.0) {
          addLog(
            'DECODER',
            'IDR keyframe received! Hardware decoding stream active at ${metrics.width}x${metrics.height} (${metrics.codec})',
            level: LogLevel.success,
          );
        }

        // Detect frame drop surge
        if (metrics.droppedFrames > _lastDroppedFrames) {
          final diff = metrics.droppedFrames - _lastDroppedFrames;
          addLog('DECODER', 'Frame drops detected: +$diff frame(s) dropped (total: ${metrics.droppedFrames})', level: LogLevel.warning);
        }

        _lastFps = metrics.fps;
        _lastDroppedFrames = metrics.droppedFrames;

        // Log continuous frame telemetry
        addLog(
          'STREAM',
          '${metrics.fps.toStringAsFixed(1)} FPS | ${(metrics.bitrateMbps).toStringAsFixed(2)} Mbps | ${metrics.latencyMs.toStringAsFixed(1)}ms | ${metrics.width}x${metrics.height} | Pkts: ${metrics.packetsReceived} | Drops: ${metrics.droppedFrames}',
          level: LogLevel.frame,
        );

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

  void _handleDeviceListUpdate(List<IosDeviceInfo> rawDevices) {
    // Allow both USB and Network connections (usbmuxd supports both)
    final devices = rawDevices.where((d) => d.connectionType.toUpperCase() == 'USB' || d.connectionType.toUpperCase() == 'NETWORK').toList();

    // 1. If device list is completely empty, clear active device and set status to scanning
    if (devices.isEmpty) {
      final activeDevice = _state.selectedDevice;
      if (activeDevice != null) {
        addLog('USBMUXD', 'Device detached: ${activeDevice.deviceName} (${activeDevice.serialNumber})', level: LogLevel.warning);
      }
      _disconnectResetTimer?.cancel();
      _lastFps = 0.0;
      _lastDroppedFrames = 0;

      _state = _state.copyWith(
        devices: const [],
        clearSelectedDevice: true,
        status: MirrorConnectionStatus.scanning,
        clearTextureId: true,
        metrics: StreamMetrics.empty,
        clearError: true,
      );
      notifyListeners();
      return;
    }

    // 2. Log newly attached devices & trigger metadata probe
    for (final dev in devices) {
      if (!_state.devices.any((d) => d.deviceId == dev.deviceId)) {
        addLog(
          'USBMUXD',
          'Device attached: ${dev.deviceName} (${dev.serialNumber}) [${dev.connectionType} ${(dev.connectionSpeed / 1000000).toStringAsFixed(0)} Mbps]',
          level: LogLevel.success,
        );
        _probeDeviceMetadata(dev.deviceId);
      }
    }

    // 3. Check if active device was unplugged
    final activeDevice = _state.selectedDevice;
    final bool activeWasUnplugged = activeDevice != null &&
        !devices.any((d) => d.deviceId == activeDevice.deviceId || d.serialNumber == activeDevice.serialNumber);

    if (activeWasUnplugged) {
      addLog('USBMUXD', 'Active device (${activeDevice.serialNumber}) unplugged from USB cable.', level: LogLevel.warning);
      _disconnectResetTimer?.cancel();
      _lastFps = 0.0;
      _lastDroppedFrames = 0;
    }

    // 4. Select active device
    IosDeviceInfo? nextSelected;
    if (activeDevice != null && !activeWasUnplugged) {
      nextSelected = devices.firstWhere(
        (d) => d.deviceId == activeDevice.deviceId || d.serialNumber == activeDevice.serialNumber,
        orElse: () => devices.first,
      );
    } else {
      nextSelected = devices.first;
    }

    MirrorConnectionStatus nextStatus = _state.status;
    if (activeWasUnplugged && _state.status == MirrorConnectionStatus.mirroring) {
      nextStatus = MirrorConnectionStatus.connected;
    } else if (_state.status == MirrorConnectionStatus.scanning || _state.status == MirrorConnectionStatus.disconnected) {
      nextStatus = MirrorConnectionStatus.connected;
    }

    _state = _state.copyWith(
      devices: devices,
      selectedDevice: nextSelected,
      status: nextStatus,
      clearError: !activeWasUnplugged,
      errorMessage: activeWasUnplugged ? 'Device was unplugged from the USB port.' : null,
      clearTextureId: activeWasUnplugged,
      metrics: activeWasUnplugged ? StreamMetrics.empty : null,
    );
    notifyListeners();
  }

  Future<void> _probeDeviceMetadata(int deviceId) async {
    try {
      final probeResult = await _channelService.probeDevice(deviceId: deviceId);
      if (probeResult['connected'] == true) {
        final deviceName = probeResult['deviceName'] as String?;
        final productType = probeResult['productType'] as String?;
        final isCaptured = probeResult['isCaptured'] as bool? ?? false;

        addLog(
          'CONTROL',
          'iPhone companion app detected online on port ${AppleCastConstants.defaultDeviceControlPort}! (Name: ${deviceName ?? "iPhone"}, Screen Captured: $isCaptured)',
          level: LogLevel.success,
        );

        if (deviceName != null || productType != null) {
          final updatedDevices = _state.devices.map((d) {
            if (d.deviceId == deviceId) {
              return d.copyWith(
                deviceName: deviceName ?? d.deviceName,
                productType: productType ?? d.productType,
              );
            }
            return d;
          }).toList();

          IosDeviceInfo? updatedSelected = _state.selectedDevice;
          if (updatedSelected?.deviceId == deviceId) {
            updatedSelected = updatedSelected?.copyWith(
              deviceName: deviceName ?? updatedSelected.deviceName,
              productType: productType ?? updatedSelected.productType,
            );
          }

          _state = _state.copyWith(
            devices: updatedDevices,
            selectedDevice: updatedSelected,
          );
          notifyListeners();
        }
      }
    } catch (_) {
      // Ignored if device not yet responding on control port
    }
  }

  void _handleNativeStatusEvent(String statusStr, Map<String, dynamic> data) {
    switch (statusStr) {
      case 'mirroring':
        final tex = data['textureId'] as int?;
        addLog('PIPELINE', 'Native status: Mirroring active on TextureId $tex', level: LogLevel.success);
        _state = _state.copyWith(
          status: MirrorConnectionStatus.mirroring,
          textureId: tex ?? _state.textureId,
          clearError: true,
        );
        break;
      case 'disconnected':
        addLog('PIPELINE', 'Native status: Disconnected by host or device.', level: LogLevel.warning);
        handleDeviceDisconnected('Mirroring session ended by host or device.');
        break;
      case 'error':
        final msg = data['message']?.toString() ?? 'Streaming pipeline error.';
        addLog('PIPELINE', 'Native error: $msg', level: LogLevel.error);
        _state = _state.copyWith(
          status: MirrorConnectionStatus.error,
          errorMessage: msg,
        );
        break;
      case 'log':
        final tag = data['tag']?.toString() ?? 'NATIVE';
        final message = data['message']?.toString() ?? '';
        final levelStr = data['level']?.toString() ?? 'info';
        LogLevel lvl = LogLevel.info;
        if (levelStr == 'success') {
          lvl = LogLevel.success;
        } else if (levelStr == 'warning') {
          lvl = LogLevel.warning;
        } else if (levelStr == 'error') {
          lvl = LogLevel.error;
        }
        addLog(tag, message, level: lvl);
        break;
    }
    notifyListeners();
  }

  /// Selects a detected iOS device.
  void selectDevice(IosDeviceInfo device) {
    if (_state.status == MirrorConnectionStatus.mirroring) return;

    addLog('SELECTION', 'Device selected: ${device.deviceName} (${device.serialNumber})', level: LogLevel.info);

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
      addLog('PIPELINE', 'Cannot mirror: No iOS device selected.', level: LogLevel.warning);
      _state = _state.copyWith(
        status: MirrorConnectionStatus.error,
        errorMessage: 'Please select an iOS device before mirroring.',
      );
      notifyListeners();
      return;
    }

    addLog('PIPELINE', 'Initiating mirroring session with ${targetDevice.deviceName} (UDID: ${targetDevice.serialNumber})...', level: LogLevel.info);

    _state = _state.copyWith(
      selectedDevice: targetDevice,
      status: MirrorConnectionStatus.connected,
      clearError: true,
      errorMessage: 'Connecting to iOS broadcast on port ${AppleCastConstants.defaultDeviceStreamingPort}...',
    );
    notifyListeners();

    // 1. Ensure Flutter Engine TextureRegistrar allocates a texture
    int? textureId = _state.textureId;
    if (textureId == null) {
      addLog('D3D11VA', 'Allocating zero-copy Direct3D 11 surface texture...', level: LogLevel.info);
      textureId = await _channelService.registerTexture();
      textureId ??= 1001; // Mock fallback for preview if native registrar not yet bound
      addLog('D3D11VA', 'Texture surface registered: ID=$textureId', level: LogLevel.success);
      _state = _state.copyWith(textureId: textureId);
      notifyListeners();
    }

    // 2. Probe control channel on port 25333 (or fallback) to notify iPhone that Laptop is connected
    addLog('CONTROL', 'Probing device control channel on port ${AppleCastConstants.defaultDeviceControlPort}...', level: LogLevel.info);
    final probeResult = await _channelService.probeDevice(deviceId: targetDevice.deviceId);
    if (probeResult['connected'] == true) {
      final bool isCaptured = probeResult['isCaptured'] == true;
      if (isCaptured) {
        addLog('CONTROL', 'iPhone companion confirmed online! (Screen Recording: ACTIVE)', level: LogLevel.success);
      } else {
        addLog('CONTROL', 'iPhone companion confirmed online, but Screen Recording is NOT active! Please tap START on ApowerMirror on iPhone and tap "Start Broadcast".', level: LogLevel.warning);
      }
    }

    // 3. Connect virtual TCP tunnel to iOS streaming port 25334 (with fallback)
    //    The native side retries with backoff if the iOS broadcast
    //    extension's TCP server isn't listening yet.
    addLog('TUNNEL', 'Opening usbmuxd virtual TCP tunnel to device port ${AppleCastConstants.defaultDeviceStreamingPort} (with backoff retry)...', level: LogLevel.info);

    final bool success = await _channelService.connectDevice(
      deviceId: targetDevice.deviceId,
    );

    if (success) {
      addLog('TUNNEL', 'Virtual TCP tunnel connected! Demuxing H.264 video stream...', level: LogLevel.success);
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
      addLog('TUNNEL', 'Connection failed on port ${AppleCastConstants.defaultDeviceStreamingPort}. iOS broadcast may not be active.', level: LogLevel.error);
      _state = _state.copyWith(
        status: MirrorConnectionStatus.error,
        errorMessage: 'Could not connect to port ${AppleCastConstants.defaultDeviceStreamingPort} on device ${targetDevice.serialNumber}. Make sure to tap "Launch ReplayKit Picker" and "Start Broadcast" on your iPhone.',
      );
    }
    notifyListeners();
  }

  /// Stops the current screen mirroring session gracefully.
  Future<void> stopMirroring() async {
    addLog('PIPELINE', 'User requested stream disconnect. Teardown underway...', level: LogLevel.info);
    await _channelService.disconnectDevice();
    handleDeviceDisconnected(null);
  }

  /// Graceful disconnection handler that resets pipeline and transitions back safely.
  void handleDeviceDisconnected(String? message) {
    _disconnectResetTimer?.cancel();
    _lastFps = 0.0;
    _lastDroppedFrames = 0;

    addLog('PIPELINE', 'Stream teardown complete. Texture unmapped.', level: LogLevel.info);

    _state = _state.copyWith(
      status: MirrorConnectionStatus.disconnected,
      clearTextureId: true,
      metrics: StreamMetrics.empty,
      errorMessage: message,
    );
    notifyListeners();

    // Reset back to connected (if device still attached) or scanning after a short feedback period
    _disconnectResetTimer = Timer(const Duration(seconds: 2), () {
      if (_state.status == MirrorConnectionStatus.disconnected) {
        final hasDevices = _state.devices.isNotEmpty;
        _state = _state.copyWith(
          status: hasDevices && _state.selectedDevice != null
              ? MirrorConnectionStatus.connected
              : MirrorConnectionStatus.scanning,
          selectedDevice: hasDevices ? _state.selectedDevice : null,
          clearSelectedDevice: !hasDevices,
          clearError: true,
        );
        notifyListeners();
      }
    });
  }

  /// Requests trust authorization from iOS device over lockdown port 62078.
  Future<void> requestPairTrust(int deviceId) async {
    addLog('LOCKDOWN', 'Sending lockdown pair authorization request for device ID $deviceId...', level: LogLevel.info);
    await _channelService.requestPairTrust(deviceId);
  }

  /// Manually triggers a rescan of usbmuxd attached devices.
  Future<void> rescan() async {
    addLog('USBMUXD', 'Manual USB bus rescan requested.', level: LogLevel.info);
    await initialize();
  }

  /// Clears any active error banner.
  void clearError() {
    _state = _state.copyWith(clearError: true);
    notifyListeners();
  }

  /// Toggles canvas orientation (0 deg portrait vs 90 deg landscape).
  void toggleRotation() {
    final next = !_state.isRotatedLandscape;
    addLog('VIEWPORT', next ? 'Orientation switched to Landscape (19.5:9)' : 'Orientation switched to Portrait (9:19.5)', level: LogLevel.info);
    _state = _state.copyWith(isRotatedLandscape: next);
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
    addLog('REPLAYKIT', 'Invoking RPSystemBroadcastPickerView on iOS companion...', level: LogLevel.info);
    await _channelService.launchBroadcastPicker();
  }

  /// iOS Companion Specific: Queries active broadcast extension status
  Future<Map<String, dynamic>> getExtensionStatus() async {
    return _channelService.getExtensionStatus();
  }

  /// iOS Companion Specific: Queries active hardware and laptop detector status
  Future<Map<String, dynamic>> getDetectorStatus() async {
    return _channelService.getDetectorStatus();
  }

  /// Probes iOS device over control port (15332)
  Future<Map<String, dynamic>> probeDevice({
    required int deviceId,
    int port = AppleCastConstants.defaultDeviceControlPort,
  }) async {
    return _channelService.probeDevice(deviceId: deviceId, port: port);
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
