import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/mirror_controller.dart';

/// iOS Companion Mode View
/// Provides the UI when running on an iPhone / iPad to initiate ReplayKit broadcast
/// and monitor the broadcast extension's live lifecycle state.
class IosTransmitterView extends StatefulWidget {
  final MirrorController controller;

  const IosTransmitterView({
    super.key,
    required this.controller,
  });

  @override
  State<IosTransmitterView> createState() => _IosTransmitterViewState();
}

class _IosTransmitterViewState extends State<IosTransmitterView> {
  Timer? _statusTimer;
  String _extensionStatus = 'CHECKING';
  int _activePort = AppleCastConstants.defaultDeviceStreamingPort;
  String _socketState = 'IDLE';

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final statusMap = await widget.controller.getExtensionStatus();
    if (!mounted) return;
    setState(() {
      _extensionStatus = (statusMap['status'] as String?) ?? 'STOPPED';
      _activePort = (statusMap['port'] as int?) ?? AppleCastConstants.defaultDeviceStreamingPort;
      _socketState = (statusMap['socketState'] as String?) ?? 'IDLE';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AppleCast Companion'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Status',
            onPressed: _refreshStatus,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfoDialog(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusHeader(),
            const SizedBox(height: 24),
            _buildBroadcastActionCard(context),
            const SizedBox(height: 20),
            _buildConfigurationCard(),
            const SizedBox(height: 20),
            _buildInstructionsCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusHeader() {
    final bool isRunning = _extensionStatus == 'RUNNING';
    final Color badgeColor = isRunning ? AppleCastTheme.appleGreen : AppleCastTheme.appleYellow;
    final IconData badgeIcon = isRunning ? Icons.sensors_rounded : Icons.sensors_off_rounded;

    final String title = isRunning ? 'Broadcast Extension Active' : 'Broadcast Extension Idle';
    final String subtitle = isRunning
        ? 'Listening on 0.0.0.0:$_activePort (${_socketState == "CLIENT_CONNECTED" ? "PC Connected" : "Awaiting Windows usbmuxd tunnel"})'
        : 'ReplayKit not running yet • Tap "Launch ReplayKit Picker" below';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isRunning ? AppleCastTheme.appleGreen.withValues(alpha: 0.5) : AppleCastTheme.darkBorder,
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              badgeIcon,
              color: badgeColor,
              size: 36,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isRunning ? AppleCastTheme.appleGreen : AppleCastTheme.textSecondary,
              fontWeight: isRunning ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBroadcastActionCard(BuildContext context) {
    final bool isRunning = _extensionStatus == 'RUNNING';

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
            isRunning ? 'Screen Broadcast is Running' : 'Start Screen Mirroring',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isRunning
                ? 'ReplayKit is encoding and streaming frames on port $_activePort. Open AppleCast on Windows and click "Mirror" to start desktop display.'
                : 'Tap below to open iOS ReplayKit Screen Broadcast picker. Select "AppleCast" and tap "Start Broadcast" to begin streaming frames to your PC.',
            style: const TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () {
              widget.controller.launchIosBroadcastPicker();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Triggering ReplayKit Screen Broadcast picker...'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: isRunning ? AppleCastTheme.appleGreen : AppleCastTheme.appleBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: Icon(isRunning ? Icons.check_circle_outline_rounded : Icons.screen_share_rounded),
            label: Text(
              isRunning ? 'ReplayKit Active (Tap to Open Picker)' : 'Launch ReplayKit Picker',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigurationCard() {
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
            'Stream Encoder Profile',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          _buildConfigRow('Target Resolution', '1080p (1920x1080 Native)'),
          const Divider(height: 20),
          _buildConfigRow('Framerate', '${AppleCastConstants.defaultFramerate} FPS (Real-Time Zero B-Frame)'),
          const Divider(height: 20),
          _buildConfigRow('Hardware Codec', 'VideoToolbox H.264 / High Profile'),
          const Divider(height: 20),
          _buildConfigRow('Bitrate', '${AppleCastConstants.defaultBitrateMbps} Mbps (Variable CBR/ABR)'),
          const Divider(height: 20),
          _buildConfigRow('Tunnel Port', '$_activePort (TCP Loopback)'),
        ],
      ),
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

  Widget _buildInstructionsCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppleCastTheme.darkBorder),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline, size: 18, color: AppleCastTheme.appleYellow),
              SizedBox(width: 8),
              Text(
                'Wired Pairing Tips',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppleCastTheme.appleYellow),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            '• Keep the Lightning/USB-C cable connected directly to the PC.\n'
            '• Ensure "Trust This Computer" is confirmed on your lock screen.\n'
            '• Tap "Launch ReplayKit Picker", choose "AppleCast", and tap "Start Broadcast".\n'
            '• Once active, click "Mirror" on the Windows AppleCast application.',
            style: TextStyle(fontSize: 12, height: 1.5, color: AppleCastTheme.textSecondary),
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
        title: const Text('About AppleCast iOS Companion'),
        content: const Text(
          'AppleCast utilizes an embedded iOS ReplayKit 2 RPBroadcastSampleHandler extension and VideoToolbox hardware encoder to stream elementary H.264 NALUs over a local usbmuxd virtual tunnel socket.',
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
