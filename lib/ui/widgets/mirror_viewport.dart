import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../models/mirror_state.dart';
import '../../models/stream_metrics.dart';
import 'control_toolbar.dart';
import 'telemetry_hud.dart';

/// Primary Video Rendering Viewport
/// Hosts Flutter's hardware-accelerated [Texture] widget for sub-frame latency presentation.
class MirrorViewport extends StatelessWidget {
  final int? textureId;
  final MirrorConnectionStatus status;
  final bool isRotatedLandscape;
  final bool isHudVisible;
  final StreamMetrics metrics;
  final bool isConsoleVisible;
  final VoidCallback onToggleRotate;
  final VoidCallback onStopMirroring;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleHud;
  final VoidCallback? onToggleConsole;

  const MirrorViewport({
    super.key,
    required this.textureId,
    required this.status,
    required this.isRotatedLandscape,
    required this.isHudVisible,
    this.isConsoleVisible = false,
    required this.metrics,
    required this.onToggleRotate,
    required this.onStopMirroring,
    required this.onToggleFullscreen,
    required this.onToggleHud,
    this.onToggleConsole,
  });

  bool get isMirroring => status == MirrorConnectionStatus.mirroring && textureId != null;

  @override
  Widget build(BuildContext context) {
    if (!isMirroring) {
      return _buildStandbyState(context);
    }

    // Default iPhone portrait aspect ratio (9 / 19.5) vs landscape (19.5 / 9)
    final double targetAspectRatio = isRotatedLandscape ? (19.5 / 9.0) : (9.0 / 19.5);

    return Container(
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background ambient halo glow
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.1,
                colors: [
                  AppleCastTheme.appleBlue.withValues(alpha: 0.12),
                  Colors.transparent,
                ],
              ),
            ),
          ),

          // Core Hardware Video Texture Widget with animated aspect ratio
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: AnimatedAspectRationContainer(
                aspectRatio: targetAspectRatio,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0C10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.7),
                        blurRadius: 36,
                        spreadRadius: 8,
                      ),
                      BoxShadow(
                        color: AppleCastTheme.appleBlue.withValues(alpha: 0.15),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Zero-Copy Hardware Direct3D 11 / PixelBuffer Texture
                      Texture(
                        textureId: textureId!,
                        filterQuality: FilterQuality.medium,
                      ),

                      // Initial frame synchronization overlay (until frames flow)
                      if (metrics.fps == 0)
                        _buildSyncingOverlay(),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Floating Telemetry HUD (Top-Right)
          if (isHudVisible)
            Positioned(
              top: 18,
              right: 18,
              child: TelemetryHud(
                metrics: metrics,
                onToggleVisibility: onToggleHud,
              ),
            ),

          // Floating Control Toolbar (Bottom-Center)
          Positioned(
            bottom: 24,
            child: ControlToolbar(
              isRotated: isRotatedLandscape,
              isConsoleVisible: isConsoleVisible,
              onToggleRotate: onToggleRotate,
              onStopMirroring: onStopMirroring,
              onToggleConsole: onToggleConsole,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncingOverlay() {
    return Container(
      color: const Color(0xFF10121A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                color: AppleCastTheme.appleBlue,
                strokeWidth: 2.5,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Awaiting IDR Keyframe via D3D11VA...',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppleCastTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tunneling port 15333 • usbmuxd virtual socket active',
              style: TextStyle(
                fontSize: 11,
                color: AppleCastTheme.textMuted.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStandbyState(BuildContext context) {
    if (status == MirrorConnectionStatus.disconnected) {
      return _buildDisconnectedState();
    }

    return Container(
      color: AppleCastTheme.darkBackground,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: AppleCastTheme.darkSurfaceElevated,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppleCastTheme.darkBorder, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: AppleCastTheme.appleBlue.withValues(alpha: 0.1),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.cable_rounded,
                    size: 42,
                    color: AppleCastTheme.appleBlue,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Wired iOS Screen Mirroring',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: AppleCastTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Connect your iPhone or iPad with a Lightning or USB-C cable to mirror your screen in 60 FPS with zero latency.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: AppleCastTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                _buildSetupStep('1', 'Plug USB cable into PC and iPhone'),
                const SizedBox(height: 8),
                _buildSetupStep('2', 'Unlock device and tap "Trust This Computer"'),
                const SizedBox(height: 8),
                _buildSetupStep('3', 'Open AppleCast companion on iOS & tap Broadcast'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisconnectedState() {
    return Container(
      color: AppleCastTheme.darkBackground,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppleCastTheme.appleYellow.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppleCastTheme.appleYellow.withValues(alpha: 0.3)),
                ),
                child: const Icon(
                  Icons.link_off_rounded,
                  size: 36,
                  color: AppleCastTheme.appleYellow,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Mirroring Session Disconnected',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppleCastTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'The virtual stream has been closed gracefully. Ready to reconnect.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppleCastTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSetupStep(String stepNumber, String instruction) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppleCastTheme.darkBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppleCastTheme.appleBlue.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                stepNumber,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppleCastTheme.appleBlue,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              instruction,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppleCastTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper widget to animate changes in aspect ratio smoothly.
class AnimatedAspectRationContainer extends StatelessWidget {
  final double aspectRatio;
  final Widget child;

  const AnimatedAspectRationContainer({
    super.key,
    required this.aspectRatio,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: aspectRatio, end: aspectRatio),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      builder: (context, animRatio, _) {
        return AspectRatio(
          aspectRatio: animRatio,
          child: child,
        );
      },
    );
  }
}
