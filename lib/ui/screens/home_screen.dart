import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/mirror_state.dart';
import '../../services/mirror_controller.dart';
import '../widgets/debug_console.dart';
import '../widgets/device_card.dart';
import '../widgets/ios_transmitter_view.dart';
import '../widgets/mirror_viewport.dart';

/// Primary Master Screen of AppleCast
/// Adapts dynamically between Windows Host Studio (Receiver / Decoder) and iOS Companion (Transmitter).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final MirrorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MirrorController();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If running on an iOS device, display the Companion Transmitter UI
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return IosTransmitterView(controller: _controller);
    }

    // Windows Desktop Host Studio UI
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;

        // When in Fullscreen mode, dedicate 100% of the screen real-estate to the viewport
        if (state.isFullscreen) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                MirrorViewport(
                  textureId: state.textureId,
                  status: state.status,
                  isRotatedLandscape: state.isRotatedLandscape,
                  isHudVisible: state.isHudVisible,
                  isConsoleVisible: state.isConsoleVisible,
                  metrics: state.metrics,
                  onToggleRotate: _controller.toggleRotation,
                  onStopMirroring: _controller.stopMirroring,
                  onToggleFullscreen: _controller.toggleFullscreen,
                  onToggleHud: _controller.toggleHudVisibility,
                  onToggleConsole: _controller.toggleConsoleVisibility,
                ),
                Positioned(
                  top: 16,
                  left: 16,
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white70),
                    tooltip: 'Exit Fullscreen',
                    onPressed: _controller.toggleFullscreen,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                // Floating Developer Console Overlay in Fullscreen
                if (state.isConsoleVisible)
                  Positioned(
                    right: 20,
                    bottom: 20,
                    width: 580,
                    height: 320,
                    child: DebugConsole(
                      logs: state.logs,
                      onClose: _controller.toggleConsoleVisibility,
                      onClear: _controller.clearLogs,
                    ),
                  ),
              ],
            ),
          );
        }

        return Scaffold(
          backgroundColor: AppleCastTheme.darkBackground,
          appBar: _buildDesktopAppBar(state),
          body: Stack(
            children: [
              Row(
                children: [
                  // Left Sidebar: Device Management & Usbmuxd Discovery
                  SizedBox(
                    width: 330,
                    child: _buildDeviceSidebar(state),
                  ),
                  const VerticalDivider(width: 1, color: AppleCastTheme.darkBorder),
                  // Main Video Viewport Canvas
                  Expanded(
                    child: MirrorViewport(
                      textureId: state.textureId,
                      status: state.status,
                      isRotatedLandscape: state.isRotatedLandscape,
                      isHudVisible: state.isHudVisible,
                      isConsoleVisible: state.isConsoleVisible,
                      metrics: state.metrics,
                      onToggleRotate: _controller.toggleRotation,
                      onStopMirroring: _controller.stopMirroring,
                      onToggleFullscreen: _controller.toggleFullscreen,
                      onToggleHud: _controller.toggleHudVisibility,
                      onToggleConsole: _controller.toggleConsoleVisibility,
                    ),
                  ),
                ],
              ),
              // Floating Developer Debug Console Overlay
              if (state.isConsoleVisible)
                Positioned(
                  right: 20,
                  bottom: 20,
                  width: 580,
                  height: 320,
                  child: DebugConsole(
                    logs: state.logs,
                    onClose: _controller.toggleConsoleVisibility,
                    onClear: _controller.clearLogs,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildDesktopAppBar(MirrorState state) {
    return AppBar(
      backgroundColor: AppleCastTheme.darkSurface,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppleCastTheme.appleBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.cast_connected_rounded,
              color: AppleCastTheme.appleBlue,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AppleCast',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3,
                  color: AppleCastTheme.textPrimary,
                ),
              ),
              Text(
                'Wired USB Mirroring Studio',
                style: TextStyle(fontSize: 11, color: AppleCastTheme.textSecondary),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Flexible(
            child: _buildDaemonStatusBadge(state),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(
            state.isHudVisible ? Icons.analytics_rounded : Icons.analytics_outlined,
            size: 20,
            color: state.isHudVisible ? AppleCastTheme.appleBlue : AppleCastTheme.textSecondary,
          ),
          tooltip: 'Toggle Telemetry HUD',
          onPressed: _controller.toggleHudVisibility,
        ),
        IconButton(
          icon: Icon(
            state.isConsoleVisible ? Icons.terminal_rounded : Icons.terminal_outlined,
            size: 20,
            color: state.isConsoleVisible ? AppleCastTheme.appleGreen : AppleCastTheme.textSecondary,
          ),
          tooltip: 'Toggle Developer Debug Console',
          onPressed: _controller.toggleConsoleVisibility,
        ),
        IconButton(
          icon: const Icon(Icons.fullscreen_rounded, size: 22),
          tooltip: 'Toggle Fullscreen Mode',
          onPressed: _controller.toggleFullscreen,
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: 'Rescan USB Devices',
          onPressed: () => _controller.rescan(),
        ),
        IconButton(
          icon: const Icon(Icons.tune_rounded, size: 20),
          tooltip: 'Decoder & Rendering Settings',
          onPressed: () => _showSettingsModal(context),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildDaemonStatusBadge(MirrorState state) {
    Color badgeColor = AppleCastTheme.appleGreen;
    String statusText = 'usbmuxd: 127.0.0.1:27015';

    if (state.status == MirrorConnectionStatus.mirroring) {
      statusText = 'Streaming (60 FPS)';
      badgeColor = AppleCastTheme.appleGreen;
    } else if (state.status == MirrorConnectionStatus.scanning) {
      statusText = 'Scanning USB...';
      badgeColor = AppleCastTheme.appleBlue;
    } else if (state.status == MirrorConnectionStatus.disconnected) {
      statusText = 'Disconnected';
      badgeColor = AppleCastTheme.appleYellow;
    } else if (state.status == MirrorConnectionStatus.error) {
      statusText = 'Connection Error';
      badgeColor = AppleCastTheme.appleRed;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: badgeColor.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: badgeColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: badgeColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSidebar(MirrorState state) {
    return Container(
      color: AppleCastTheme.darkSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ATTACHED DEVICES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppleCastTheme.textMuted,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppleCastTheme.darkSurfaceElevated,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppleCastTheme.darkBorder),
                  ),
                  child: Text(
                    '${state.devices.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppleCastTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Error / Status Alert Banner
          if (state.errorMessage != null)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (state.status == MirrorConnectionStatus.error
                        ? AppleCastTheme.appleRed
                        : AppleCastTheme.appleYellow)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: (state.status == MirrorConnectionStatus.error
                          ? AppleCastTheme.appleRed
                          : AppleCastTheme.appleYellow)
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    state.status == MirrorConnectionStatus.error
                        ? Icons.error_outline_rounded
                        : Icons.info_outline_rounded,
                    color: state.status == MirrorConnectionStatus.error
                        ? AppleCastTheme.appleRed
                        : AppleCastTheme.appleYellow,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.errorMessage!,
                      style: TextStyle(
                        fontSize: 11,
                        color: state.status == MirrorConnectionStatus.error
                            ? AppleCastTheme.appleRed
                            : AppleCastTheme.appleYellow,
                        height: 1.3,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _controller.clearError,
                    child: const Icon(Icons.close_rounded, size: 14, color: AppleCastTheme.textMuted),
                  ),
                ],
              ),
            ),

          // Discovered Devices List
          Expanded(
            child: state.devices.isEmpty
                ? _buildEmptyDeviceList(state)
                : ListView.builder(
                    itemCount: state.devices.length,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemBuilder: (context, index) {
                      final device = state.devices[index];
                      final isSelected = state.selectedDevice?.deviceId == device.deviceId;
                      final isLive = state.isMirroring && isSelected;

                      return DeviceCard(
                        device: device,
                        isSelected: isSelected,
                        isMirroring: isLive,
                        onSelect: () => _controller.selectDevice(device),
                        onConnect: () => _controller.startMirroring(device: device),
                        onDisconnect: () => _controller.stopMirroring(),
                        onRequestTrust: () => _controller.requestPairTrust(device.deviceId),
                      );
                    },
                  ),
          ),
          _buildSidebarFooter(),
        ],
      ),
    );
  }

  Widget _buildEmptyDeviceList(MirrorState state) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppleCastTheme.darkSurfaceElevated,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.usb_rounded,
              size: 32,
              color: AppleCastTheme.textMuted,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Listening for USB Devices...',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppleCastTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Plug your iPhone into PC over USB.\nMake sure lock screen is unlocked.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: AppleCastTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarFooter() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: const BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        border: Border(top: BorderSide(color: AppleCastTheme.darkBorder)),
      ),
      child: const Row(
        children: [
          Icon(Icons.bolt_rounded, size: 16, color: AppleCastTheme.appleGreen),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Zero-Copy Direct3D 11 Renderer Active',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppleCastTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettingsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppleCastTheme.darkSurfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hardware & Pipeline Configuration',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppleCastTheme.textPrimary),
            ),
            const SizedBox(height: 16),
            _buildSettingOption('Hardware Decoder', 'FFmpeg / Direct3D 11 Video Acceleration (D3D11VA)'),
            _buildSettingOption('Tunnel Port', '${AppleCastConstants.defaultDeviceStreamingPort} (TCP Loopback)'),
            _buildSettingOption('Framerate Target', '60 FPS Real-Time (Zero B-Frames)'),
            _buildSettingOption('Compositor Texture', 'flutter::GpuSurfaceTexture (IDXGIResource)'),
            _buildSettingOption('Daemon Port', '${AppleCastConstants.usbmuxdPort} (Localhost Multiplexer)'),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingOption(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppleCastTheme.textSecondary)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppleCastTheme.textPrimary)),
        ],
      ),
    );
  }
}
