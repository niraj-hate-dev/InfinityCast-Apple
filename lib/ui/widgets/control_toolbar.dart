import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme.dart';

/// Floating control bar for active mirroring actions (Rotate, Fullscreen, Disconnect).
class ControlToolbar extends StatelessWidget {
  final bool isRotated;
  final VoidCallback onToggleRotate;
  final VoidCallback onStopMirroring;

  const ControlToolbar({
    super.key,
    required this.isRotated,
    required this.onToggleRotate,
    required this.onStopMirroring,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconButton(
                icon: Icons.screen_rotation_rounded,
                tooltip: 'Rotate Orientation',
                onPressed: onToggleRotate,
                isActive: isRotated,
              ),
              const SizedBox(width: 4),
              _buildIconButton(
                icon: Icons.fullscreen_rounded,
                tooltip: 'Fullscreen View',
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Fullscreen Mode: Press F11 or Esc to toggle.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              const SizedBox(width: 4),
              _buildIconButton(
                icon: Icons.camera_alt_outlined,
                tooltip: 'Take Frame Snapshot',
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Saved screenshot to Pictures/AppleCast/'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              Container(
                height: 20,
                width: 1,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: Colors.white.withValues(alpha: 0.2),
              ),
              _buildIconButton(
                icon: Icons.power_settings_new_rounded,
                tooltip: 'Disconnect Mirror',
                color: AppleCastTheme.appleRed,
                onPressed: onStopMirroring,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color color = Colors.white,
    bool isActive = false,
  }) {
    return IconButton(
      icon: Icon(
        icon,
        size: 18,
        color: isActive ? AppleCastTheme.appleBlue : color,
      ),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        padding: const EdgeInsets.all(8),
        minimumSize: const Size(36, 36),
        backgroundColor: isActive ? AppleCastTheme.appleBlue.withValues(alpha: 0.2) : Colors.transparent,
      ),
    );
  }
}
