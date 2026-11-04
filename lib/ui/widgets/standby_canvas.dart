import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../models/mirror_state.dart';

/// Center standby canvas shown when no active screen mirroring session is streaming.
/// Features scanning radar rings with glowing Apple logo, instructional step cards, and privacy badge.
class StandbyCanvas extends StatelessWidget {
  final MirrorState state;
  final VoidCallback? onStartManual;

  const StandbyCanvas({
    super.key,
    required this.state,
    this.onStartManual,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasDevice = state.selectedDevice != null;

    return Container(
      color: AppleCastTheme.navyBackground,
      child: Stack(
        children: [
          // Ambient Radial Glow
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.2),
                  radius: 0.9,
                  colors: [
                    const Color(0xFF1E3A8A).withValues(alpha: 0.15),
                    const Color(0xFF0F172A).withValues(alpha: 0.05),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Main Centered Content
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),

                  // Concentric Radar Rings with glowing Apple Logo
                  SizedBox(
                    width: 220,
                    height: 220,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Radar dashed concentric circles
                        CustomPaint(
                          size: const Size(220, 220),
                          painter: _RadarCirclesPainter(),
                        ),

                        // Soft Blue Glow Backing
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppleCastTheme.iconBlue.withValues(alpha: 0.2),
                                blurRadius: 40,
                                spreadRadius: 10,
                              ),
                            ],
                          ),
                        ),

                        // Glowing Apple Icon
                        const Icon(
                          Icons.apple,
                          size: 72,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Main Heading
                  const Text(
                    'Connect your iOS device via USB',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Subheading
                  Text(
                    hasDevice
                        ? 'Device detected: ${state.selectedDevice?.deviceName ?? "iPhone"}. Start broadcast on your device.'
                        : 'InfinityCast will detect your device automatically.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF8E9BB5),
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.1,
                    ),
                  ),

                  const SizedBox(height: 42),

                  // 3-Column Instruction Cards
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final bool isCompact = constraints.maxWidth < 620;
                        return Flex(
                          direction: isCompact ? Axis.vertical : Axis.horizontal,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Expanded(
                              flex: isCompact ? 0 : 1,
                              child: const _InstructionCard(
                                icon: Icons.usb_rounded,
                                title: '1. Connect',
                                description: 'Plug in your iOS device using a USB cable.',
                              ),
                            ),
                            SizedBox(width: isCompact ? 0 : 16, height: isCompact ? 12 : 0),
                            Expanded(
                              flex: isCompact ? 0 : 1,
                              child: const _InstructionCard(
                                icon: Icons.phone_iphone_rounded,
                                title: '2. Trust This Computer',
                                description: "Tap 'Trust' and enter your passcode on your iOS device.",
                              ),
                            ),
                            SizedBox(width: isCompact ? 0 : 16, height: isCompact ? 12 : 0),
                            Expanded(
                              flex: isCompact ? 0 : 1,
                              child: const _InstructionCard(
                                icon: Icons.check_circle_outline_rounded,
                                title: '3. Allow Permission',
                                description: 'Allow necessary access when prompted.',
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 50),
                ],
              ),
            ),
          ),

          // Security & Safety Footer (Bottom Center)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(
                  Icons.verified_user_outlined,
                  size: 15,
                  color: AppleCastTheme.shieldGreen,
                ),
                SizedBox(width: 8),
                Text(
                  'Your data is safe and never shared.',
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),

          // Bottom Right Sparkle Icon (4-point star)
          Positioned(
            right: 28,
            bottom: 24,
            child: CustomPaint(
              size: const Size(26, 26),
              painter: _SparklePainter(),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstructionCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String description;

  const _InstructionCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  State<_InstructionCard> createState() => _InstructionCardState();
}

class _InstructionCardState extends State<_InstructionCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: const BoxConstraints(minHeight: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: _isHovered
              ? const Color(0xFF0F1A30)
              : AppleCastTheme.cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? AppleCastTheme.iconBlue.withValues(alpha: 0.5)
                : AppleCastTheme.cardBorder,
            width: 1,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: AppleCastTheme.iconBlue.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.icon,
              size: 28,
              color: AppleCastTheme.iconBlue,
            ),
            const SizedBox(height: 10),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.description,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF8E9BB5),
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom painter rendering concentric dashed radar scan rings.
class _RadarCirclesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radii = [60.0, 95.0];

    final paint = Paint()
      ..color = const Color(0xFF2563EB).withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (final radius in radii) {
      _drawDashedCircle(canvas, center, radius, paint, 6, 6);
    }
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset center,
    double radius,
    Paint paint,
    double dashLength,
    double gapLength,
  ) {
    final circumference = 2 * math.pi * radius;
    final totalDashGap = dashLength + gapLength;
    final dashCount = (circumference / totalDashGap).floor();
    final adjustedDashAngle = (dashLength / circumference) * 2 * math.pi;
    final adjustedGapAngle = (gapLength / circumference) * 2 * math.pi;

    for (int i = 0; i < dashCount; i++) {
      final startAngle = i * (adjustedDashAngle + adjustedGapAngle);
      final path = Path()
        ..addArc(
          Rect.fromCircle(center: center, radius: radius),
          startAngle,
          adjustedDashAngle,
        );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Custom painter for the 4-pointed sparkle icon in the bottom-right corner.
class _SparklePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCBD5E1).withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;

    final path = Path()
      ..moveTo(cx, 0)
      ..quadraticBezierTo(cx, cy, w, cy)
      ..quadraticBezierTo(cx, cy, cx, h)
      ..quadraticBezierTo(cx, cy, 0, cy)
      ..quadraticBezierTo(cx, cy, cx, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
