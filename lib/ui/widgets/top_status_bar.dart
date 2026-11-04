import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../models/mirror_state.dart';
import '../../services/platform_channel_service.dart';

/// Top bar with live connection indicator, dark theme toggle, and native window control buttons.
class TopStatusBar extends StatelessWidget {
  final MirrorState state;
  final VoidCallback? onToggleTheme;
  final PlatformChannelService _channelService;

  TopStatusBar({
    super.key,
    required this.state,
    this.onToggleTheme,
    PlatformChannelService? channelService,
  }) : _channelService = channelService ?? PlatformChannelService();

  @override
  Widget build(BuildContext context) {
    final bool isConnected = state.isMirroring;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Native Draggable Window Caption Area
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => _channelService.startDragging(),
              onDoubleTap: () => _channelService.maximizeWindow(),
              child: const SizedBox(
                height: 48,
                width: double.infinity,
              ),
            ),
          ),

          // Connection Status Indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected ? AppleCastTheme.shieldGreen : AppleCastTheme.appleRed,
                    boxShadow: [
                      BoxShadow(
                        color: (isConnected ? AppleCastTheme.shieldGreen : AppleCastTheme.appleRed).withValues(alpha: 0.6),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isConnected ? 'Connected' : 'Disconnected',
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Theme Toggle Icon
          IconButton(
            icon: const Icon(
              Icons.nightlight_round,
              size: 18,
              color: AppleCastTheme.moonYellow,
            ),
            tooltip: 'Dark Theme',
            splashRadius: 16,
            onPressed: onToggleTheme ?? () {},
          ),
          const SizedBox(width: 8),

          // Window Controls: Minimize
          _WindowButton(
            icon: Icons.remove_rounded,
            tooltip: 'Minimize',
            onTap: () => _channelService.minimizeWindow(),
          ),

          // Window Controls: Maximize / Restore
          _WindowButton(
            icon: Icons.crop_square_rounded,
            tooltip: 'Maximize',
            onTap: () => _channelService.maximizeWindow(),
          ),

          // Window Controls: Close
          _WindowButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            isClose: true,
            onTap: () => _channelService.closeWindow(),
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 36,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: _isHovered
                  ? (widget.isClose ? const Color(0xFFE81123) : Colors.white.withValues(alpha: 0.1))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 15,
              color: _isHovered && widget.isClose ? Colors.white : const Color(0xFF94A3B8),
            ),
          ),
        ),
      ),
    );
  }
}
