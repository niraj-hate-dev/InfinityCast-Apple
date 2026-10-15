import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/mirror_controller.dart';

/// iOS Companion Mode View
/// Provides an interactive status HUD on the iPhone / iPad:
/// 1. Detects whether the Windows Laptop is connected over USB/usbmuxd.
/// 2. Live ReplayKit Screen Recording detector (Pulsing Red badge with live stopwatch).
/// 3. Physical USB cable charging detection & active network interface enumeration.
class IosTransmitterView extends StatefulWidget {
  final MirrorController controller;

  const IosTransmitterView({
    super.key,
    required this.controller,
  });

  @override
  State<IosTransmitterView> createState() => _IosTransmitterViewState();
}

class _IosTransmitterViewState extends State<IosTransmitterView>
    with SingleTickerProviderStateMixin {
  Timer? _statusTimer;
  Timer? _recordingStopwatchTimer;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Real-time detector state
  bool _isCaptured = false;
  bool _laptopConnected = false;
  String _laptopName = '';
  bool _usbCableConnected = false;
  int _streamingPort = AppleCastConstants.defaultDeviceStreamingPort;
  int _controlPort = AppleCastConstants.defaultDeviceControlPort;
  String _socketState = 'IDLE';
  List<Map<String, String>> _interfaces = [];
  int _recordingSeconds = 0;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _refreshDetectorStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshDetectorStatus());

    _recordingStopwatchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isCaptured) {
        setState(() {
          _recordingSeconds++;
        });
      } else {
        if (_recordingSeconds != 0) {
          setState(() {
            _recordingSeconds = 0;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _recordingStopwatchTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _refreshDetectorStatus() async {
    final statusMap = await widget.controller.getDetectorStatus();
    if (!mounted) return;

    final isCaptured = (statusMap['isCaptured'] as bool?) ?? false;
    final laptopConnected = (statusMap['laptopConnected'] as bool?) ?? false;
    final laptopName = (statusMap['laptopName'] as String?) ?? '';
    final usbCableConnected = (statusMap['usbCableConnected'] as bool?) ?? false;
    final streamingPort = (statusMap['streamingPort'] as int?) ?? AppleCastConstants.defaultDeviceStreamingPort;
    final controlPort = (statusMap['controlPort'] as int?) ?? AppleCastConstants.defaultDeviceControlPort;
    final socketState = (statusMap['socketState'] as String?) ?? 'IDLE';

    final rawInterfaces = statusMap['interfaces'];
    List<Map<String, String>> ifList = [];
    if (rawInterfaces is List) {
      for (final item in rawInterfaces) {
        if (item is Map) {
          ifList.add({
            'name': item['name']?.toString() ?? '',
            'ip': item['ip']?.toString() ?? '',
          });
        }
      }
    }

    setState(() {
      _isCaptured = isCaptured;
      _laptopConnected = laptopConnected;
      _laptopName = laptopName;
      _usbCableConnected = usbCableConnected;
      _streamingPort = streamingPort;
      _controlPort = controlPort;
      _socketState = socketState;
      if (ifList.isNotEmpty) {
        _interfaces = ifList;
      }
    });
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AppleCast Companion HUD'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Detector',
            onPressed: _refreshDetectorStatus,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfoDialog(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildScreenRecordingHero(),
            const SizedBox(height: 18),
            _buildLaptopDetectorCard(),
            const SizedBox(height: 18),
            _buildBroadcastActionCard(context),
            const SizedBox(height: 18),
            _buildNetworkInterfacesCard(),
            const SizedBox(height: 18),
            _buildEncoderProfileCard(),
          ],
        ),
      ),
    );
  }

  /// Top Hero: Visual Screen Recording Detector (Pulsing Red circle with live stopwatch)
  Widget _buildScreenRecordingHero() {
    final bool isRecording = _isCaptured;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isRecording ? AppleCastTheme.appleRed.withValues(alpha: 0.6) : AppleCastTheme.darkBorder,
          width: isRecording ? 2 : 1,
        ),
        boxShadow: isRecording
            ? [
                BoxShadow(
                  color: AppleCastTheme.appleRed.withValues(alpha: 0.25),
                  blurRadius: 18,
                  spreadRadius: 2,
                )
              ]
            : null,
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isRecording)
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: AppleCastTheme.appleRed,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppleCastTheme.appleRed,
                          blurRadius: 10,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                  ),
                )
              else
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppleCastTheme.textSecondary, width: 2),
                  ),
                ),
              const SizedBox(width: 12),
              Text(
                isRecording ? 'SCREEN RECORDING ACTIVE' : 'SCREEN RECORDING IDLE',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: isRecording ? AppleCastTheme.appleRed : AppleCastTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isRecording) ...[
            Text(
              _formatDuration(_recordingSeconds),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: AppleCastTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Encoding 60 FPS H.264 stream • Zero B-Frames',
              style: TextStyle(fontSize: 12, color: AppleCastTheme.appleGreen, fontWeight: FontWeight.w600),
            ),
          ] else ...[
            const Text(
              'ReplayKit broadcast extension is not capturing yet.\nTap "Launch ReplayKit Picker" below to start.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary, height: 1.4),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildPill(
                label: isRecording ? 'Capture: ON' : 'Capture: OFF',
                color: isRecording ? AppleCastTheme.appleRed : AppleCastTheme.textSecondary,
                icon: isRecording ? Icons.fiber_manual_record : Icons.stop_circle_outlined,
              ),
              const SizedBox(width: 8),
              _buildPill(
                label: 'Port $_streamingPort',
                color: AppleCastTheme.appleBlue,
                icon: Icons.router_outlined,
              ),
              const SizedBox(width: 8),
              _buildPill(
                label: _socketState == 'CLIENT_CONNECTED' ? 'Tunnel: LINKED' : 'Tunnel: READY',
                color: _socketState == 'CLIENT_CONNECTED' ? AppleCastTheme.appleGreen : AppleCastTheme.appleYellow,
                icon: Icons.sync_alt_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Laptop USB / usbmuxd Connection Detector HUD
  Widget _buildLaptopDetectorCard() {
    final bool isDetected = _laptopConnected;
    final Color badgeColor = isDetected ? AppleCastTheme.appleGreen : AppleCastTheme.appleYellow;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDetected ? AppleCastTheme.appleGreen.withValues(alpha: 0.6) : AppleCastTheme.darkBorder,
          width: isDetected ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.laptop_chromebook_rounded,
                  color: badgeColor,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isDetected ? 'Laptop Detected: Connected' : 'Laptop Status: Awaiting Connection',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDetected ? AppleCastTheme.appleGreen : AppleCastTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isDetected
                          ? (_laptopName.isNotEmpty ? _laptopName : 'Windows PC (usbmuxd virtual tunnel)')
                          : 'Checking local USB multiplexer tunnel on port $_controlPort...',
                      style: const TextStyle(fontSize: 12, color: AppleCastTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),
          _buildInfoRow(
            icon: Icons.power_rounded,
            label: 'USB Cable Link',
            value: _usbCableConnected ? 'Connected (Charging ⚡)' : 'Unplugged / No Power',
            isPositive: _usbCableConnected,
          ),
          const SizedBox(height: 10),
          _buildInfoRow(
            icon: Icons.settings_ethernet_rounded,
            label: 'usbmuxd Control Channel',
            value: isDetected ? 'Active (Port $_controlPort Synced)' : 'Listening on 127.0.0.1:$_controlPort',
            isPositive: isDetected,
          ),
          const SizedBox(height: 10),
          _buildInfoRow(
            icon: Icons.screen_share_outlined,
            label: 'Video Tunnel Status',
            value: _isCaptured
                ? (_socketState == 'CLIENT_CONNECTED' ? 'Transmitting to Desktop' : 'Listening on Port $_streamingPort')
                : 'Ready (Awaiting ReplayKit Start)',
            isPositive: _isCaptured,
          ),
        ],
      ),
    );
  }

  /// Broadcast Action Card
  Widget _buildBroadcastActionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppleCastTheme.darkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isCaptured ? 'Screen Mirroring in Progress' : 'Start Screen Mirroring',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isCaptured
                ? 'Your screen is being broadcasted. Keep AppleCast open on your Windows laptop to view the live mirror.'
                : '1. Tap the button below to open iOS Screen Broadcast picker.\n2. Ensure "AppleCast" is selected with a checkmark.\n3. Tap "Start Broadcast" (countdown 3, 2, 1 will start).',
            style: const TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () {
              widget.controller.launchIosBroadcastPicker();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Opening ReplayKit Screen Broadcast picker...'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _isCaptured ? AppleCastTheme.appleGreen : AppleCastTheme.appleBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: Icon(_isCaptured ? Icons.check_circle_rounded : Icons.screen_share_rounded),
            label: Text(
              _isCaptured ? 'Broadcast Active (Tap to Manage)' : 'Launch ReplayKit Picker',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Network Interfaces Card
  Widget _buildNetworkInterfacesCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppleCastTheme.darkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.hub_outlined, size: 20, color: AppleCastTheme.appleBlue),
              SizedBox(width: 10),
              Text(
                'Detected Network Interfaces',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppleCastTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_interfaces.isEmpty)
            const Text(
              'Enumerating local interfaces (lo0, bridge100, en0)...',
              style: TextStyle(fontSize: 12, color: AppleCastTheme.textSecondary),
            )
          else
            ..._interfaces.map((iface) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        iface['name'] ?? '',
                        style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppleCastTheme.textSecondary),
                      ),
                      Text(
                        iface['ip'] ?? '',
                        style: const TextStyle(fontSize: 13, fontFamily: 'monospace', fontWeight: FontWeight.w600, color: AppleCastTheme.textPrimary),
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }

  /// Stream Encoder Profile Card
  Widget _buildEncoderProfileCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppleCastTheme.darkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Encoder Pipeline Configuration',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          _buildConfigRow('Target Resolution', '1080p (Native Dynamic Scale)'),
          const Divider(height: 16),
          _buildConfigRow('Framerate', '${AppleCastConstants.defaultFramerate} FPS (Zero B-Frames)'),
          const Divider(height: 16),
          _buildConfigRow('Hardware Codec', 'VideoToolbox H.264 (High Profile)'),
          const Divider(height: 16),
          _buildConfigRow('Target Bitrate', '${AppleCastConstants.defaultBitrateMbps} Mbps (CBR/ABR)'),
          const Divider(height: 16),
          _buildConfigRow('Video Port', '$_streamingPort (Loopback Tunnel)'),
          const Divider(height: 16),
          _buildConfigRow('Control Port', '$_controlPort (Laptop Detector)'),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    required bool isPositive,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: isPositive ? AppleCastTheme.appleGreen : AppleCastTheme.textSecondary),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isPositive ? AppleCastTheme.appleGreen : AppleCastTheme.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildConfigRow(String title, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppleCastTheme.textPrimary)),
      ],
    );
  }

  Widget _buildPill({required String label, required Color color, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppleCastTheme.darkSurfaceElevated,
        title: const Text('About AppleCast Companion'),
        content: const Text(
          'AppleCast pairs an embedded ReplayKit 2 RPBroadcastSampleHandler extension with a high-performance VideoToolbox hardware encoder to stream low-latency H.264 video frames directly over a USB cable via usbmuxd.\n\n'
          'The on-device detector monitors Apple usbmuxd virtual tunnel connections, screen capture states, and active local interfaces in real-time.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: AppleCastTheme.appleBlue)),
          ),
        ],
      ),
    );
  }
}
