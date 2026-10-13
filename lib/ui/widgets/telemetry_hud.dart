import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../models/stream_metrics.dart';

/// Floating Glassmorphic Telemetry HUD Overlay
/// Displays real-time sub-millisecond video metrics (FPS, Bitrate, Latency, Codec, Dropped Frames).
class TelemetryHud extends StatefulWidget {
  final StreamMetrics metrics;
  final VoidCallback? onToggleVisibility;

  const TelemetryHud({
    super.key,
    required this.metrics,
    this.onToggleVisibility,
  });

  @override
  State<TelemetryHud> createState() => _TelemetryHudState();
}

class _TelemetryHudState extends State<TelemetryHud> {
  bool _isMinimized = false;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(
            horizontal: _isMinimized ? 10 : 14,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.14),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: _isMinimized ? _buildMinimizedContent() : _buildExpandedContent(),
        ),
      ),
    );
  }

  Widget _buildMinimizedContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: _getFpsColor(widget.metrics.fps),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${widget.metrics.fps.toStringAsFixed(0)} FPS • ${widget.metrics.latencyMs.toStringAsFixed(1)} ms',
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            color: AppleCastTheme.textPrimary,
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => setState(() => _isMinimized = false),
          child: const Icon(Icons.unfold_more_rounded, size: 14, color: AppleCastTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildExpandedContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Live stream status dot
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: _getFpsColor(widget.metrics.fps),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _getFpsColor(widget.metrics.fps).withValues(alpha: 0.6),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _buildMetricItem(
          label: 'FPS',
          value: widget.metrics.fps.toStringAsFixed(0),
          color: _getFpsColor(widget.metrics.fps),
        ),
        _buildDivider(),
        _buildMetricItem(
          label: 'LATENCY',
          value: '${widget.metrics.latencyMs.toStringAsFixed(1)} ms',
          color: _getLatencyColor(widget.metrics.latencyMs),
        ),
        _buildDivider(),
        _buildMetricItem(
          label: 'BITRATE',
          value: '${widget.metrics.bitrateMbps.toStringAsFixed(1)} Mbps',
          color: AppleCastTheme.appleBlue,
        ),
        _buildDivider(),
        _buildMetricItem(
          label: 'CODEC',
          value: widget.metrics.codec,
          color: AppleCastTheme.applePurple,
        ),
        _buildDivider(),
        _buildMetricItem(
          label: 'RESOLUTION',
          value: '${widget.metrics.width}x${widget.metrics.height}',
          color: AppleCastTheme.textSecondary,
        ),
        if (widget.metrics.droppedFrames > 0) ...[
          _buildDivider(),
          _buildMetricItem(
            label: 'DROPS',
            value: '${widget.metrics.droppedFrames}',
            color: AppleCastTheme.appleRed,
          ),
        ],
        const SizedBox(width: 8),
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => setState(() => _isMinimized = true),
          child: const Padding(
            padding: EdgeInsets.all(2.0),
            child: Icon(Icons.unfold_less_rounded, size: 14, color: AppleCastTheme.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 20,
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withValues(alpha: 0.12),
    );
  }

  Widget _buildMetricItem({
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: AppleCastTheme.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            color: color,
          ),
        ),
      ],
    );
  }

  Color _getFpsColor(double fps) {
    if (fps >= 55) return AppleCastTheme.appleGreen;
    if (fps >= 30) return AppleCastTheme.appleYellow;
    return AppleCastTheme.appleRed;
  }

  Color _getLatencyColor(double latency) {
    if (latency <= 16.0) return AppleCastTheme.appleGreen;
    if (latency <= 30.0) return AppleCastTheme.appleYellow;
    return AppleCastTheme.appleRed;
  }
}
