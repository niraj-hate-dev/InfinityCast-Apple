import 'device_info.dart';
import 'stream_metrics.dart';

/// Connection and streaming lifecycle state machine.
enum MirrorConnectionStatus {
  scanning,      // Listening on 127.0.0.1:27015 for attached iOS devices
  connected,     // Device discovered and selected, ready to establish tunnel
  mirroring,     // Active stream over usbmuxd tunnel (port 15333) with live texture rendering
  disconnected,  // Stream gracefully ended or USB cable unplugged
  error,         // Error during tunnel connect, pairing rejected, or daemon unreachable
}

/// Immutable state snapshot of the active screen mirroring session.
class MirrorState {
  final MirrorConnectionStatus status;
  final List<IosDeviceInfo> devices;
  final IosDeviceInfo? selectedDevice;
  final int? textureId;
  final StreamMetrics metrics;
  final String? errorMessage;
  final bool isRotatedLandscape;
  final bool isFullscreen;
  final bool isHudVisible;

  const MirrorState({
    this.status = MirrorConnectionStatus.scanning,
    this.devices = const [],
    this.selectedDevice,
    this.textureId,
    this.metrics = StreamMetrics.empty,
    this.errorMessage,
    this.isRotatedLandscape = false,
    this.isFullscreen = false,
    this.isHudVisible = true,
  });

  bool get isMirroring => status == MirrorConnectionStatus.mirroring && textureId != null;
  bool get hasActiveDevice => selectedDevice != null;
  bool get isScanning => status == MirrorConnectionStatus.scanning;

  MirrorState copyWith({
    MirrorConnectionStatus? status,
    List<IosDeviceInfo>? devices,
    IosDeviceInfo? selectedDevice,
    bool clearSelectedDevice = false,
    int? textureId,
    bool clearTextureId = false,
    StreamMetrics? metrics,
    String? errorMessage,
    bool clearError = false,
    bool? isRotatedLandscape,
    bool? isFullscreen,
    bool? isHudVisible,
  }) {
    return MirrorState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      selectedDevice: clearSelectedDevice ? null : (selectedDevice ?? this.selectedDevice),
      textureId: clearTextureId ? null : (textureId ?? this.textureId),
      metrics: metrics ?? this.metrics,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isRotatedLandscape: isRotatedLandscape ?? this.isRotatedLandscape,
      isFullscreen: isFullscreen ?? this.isFullscreen,
      isHudVisible: isHudVisible ?? this.isHudVisible,
    );
  }
}
