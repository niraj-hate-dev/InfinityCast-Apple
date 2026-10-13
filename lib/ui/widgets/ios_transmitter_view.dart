import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/mirror_controller.dart';

/// iOS Companion Mode View
/// Provides the UI when running on an iPhone / iPad to initiate ReplayKit broadcast.
class IosTransmitterView extends StatelessWidget {
  final MirrorController controller;

  const IosTransmitterView({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AppleCast Companion'),
        actions: [
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
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppleCastTheme.darkBorder),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppleCastTheme.appleGreen.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.sensors_rounded,
              color: AppleCastTheme.appleGreen,
              size: 36,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'USB Wired Transmitter Ready',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Local listener: 127.0.0.1:15333 • Tunneled via usbmuxd',
            style: TextStyle(
              fontSize: 12,
              color: AppleCastTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

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
          const Text(
            'Start Screen Mirroring',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppleCastTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap below to open iOS ReplayKit Screen Broadcast picker. Select "AppleCast" to begin streaming frames to your PC.',
            style: TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () {
              controller.launchIosBroadcastPicker();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Triggering ReplayKit RPSystemBroadcastPickerView...'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppleCastTheme.appleBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.screen_share_rounded),
            label: const Text(
              'Launch ReplayKit Picker',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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
          _buildConfigRow('Tunnel Port', '${AppleCastConstants.defaultDeviceStreamingPort} (TCP Loopback)'),
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
            '• ReplayKit captures screen and app audio at ultra-low latency without Wi-Fi congestion.',
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
