import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme.dart';
import '../../models/device_info.dart';

/// Card component presenting a detected iOS device with trust status, USB metrics, and mirroring trigger.
class DeviceCard extends StatefulWidget {
  final IosDeviceInfo device;
  final bool isSelected;
  final bool isMirroring;
  final VoidCallback onSelect;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onRequestTrust;

  const DeviceCard({
    super.key,
    required this.device,
    required this.isSelected,
    required this.isMirroring,
    required this.onSelect,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRequestTrust,
  });

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isMirroring) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant DeviceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isMirroring && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isMirroring && _pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final isLive = widget.isMirroring;

    final borderColor = isLive
        ? AppleCastTheme.appleGreen.withValues(alpha: 0.8)
        : (isSelected ? AppleCastTheme.appleBlue : AppleCastTheme.darkBorder);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isSelected
            ? AppleCastTheme.appleBlue.withValues(alpha: 0.08)
            : AppleCastTheme.darkSurfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: borderColor,
          width: (isSelected || isLive) ? 1.5 : 1.0,
        ),
        boxShadow: (isSelected || isLive)
            ? [
                BoxShadow(
                  color: (isLive ? AppleCastTheme.appleGreen : AppleCastTheme.appleBlue)
                      .withValues(alpha: 0.15),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onSelect,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: Device icon, name, product type, and trust badge
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isLive
                            ? AppleCastTheme.appleGreen.withValues(alpha: 0.15)
                            : AppleCastTheme.appleBlue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.phone_iphone_rounded,
                        color: isLive ? AppleCastTheme.appleGreen : AppleCastTheme.appleBlue,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.device.deviceName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: AppleCastTheme.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.device.productType,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppleCastTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildTrustBadge(),
                  ],
                ),
                const SizedBox(height: 12),
                // Serial Number Snippet & Copy Action
                Row(
                  children: [
                    Text(
                      'UDID: ${_formatUdid(widget.device.serialNumber)}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppleCastTheme.textMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.device.serialNumber));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied UDID: ${widget.device.serialNumber}'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(2.0),
                        child: Icon(
                          Icons.copy_rounded,
                          size: 12,
                          color: AppleCastTheme.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: AppleCastTheme.darkBorder),
                const SizedBox(height: 12),
                // Footer: USB link speed & Connect / Disconnect button
                Row(
                  children: [
                    const Icon(
                      Icons.usb_rounded,
                      size: 14,
                      color: AppleCastTheme.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'USB (${(widget.device.connectionSpeed / 1000000).toStringAsFixed(0)} Mbps)',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppleCastTheme.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    if (!widget.isMirroring)
                      ElevatedButton.icon(
                        onPressed: widget.onConnect,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppleCastTheme.appleBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          visualDensity: VisualDensity.compact,
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.cast_rounded, size: 14),
                        label: const Text(
                          'Mirror',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      )
                    else
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FadeTransition(
                            opacity: _pulseAnimation,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppleCastTheme.appleGreen.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.fiber_manual_record, color: AppleCastTheme.appleGreen, size: 8),
                                  SizedBox(width: 6),
                                  Text(
                                    'Streaming',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: AppleCastTheme.appleGreen,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.stop_circle_outlined, size: 18),
                            color: AppleCastTheme.appleRed,
                            tooltip: 'Stop Mirroring',
                            onPressed: widget.onDisconnect,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrustBadge() {
    switch (widget.device.trustStatus) {
      case DeviceTrustStatus.trusted:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppleCastTheme.appleGreen.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppleCastTheme.appleGreen.withValues(alpha: 0.3)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded, size: 12, color: AppleCastTheme.appleGreen),
              SizedBox(width: 4),
              Text(
                'Trusted',
                style: TextStyle(fontSize: 11, color: AppleCastTheme.appleGreen, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      case DeviceTrustStatus.untrusted:
      case DeviceTrustStatus.pairingInProgress:
        return InkWell(
          onTap: widget.onRequestTrust,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppleCastTheme.appleYellow.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppleCastTheme.appleYellow.withValues(alpha: 0.4)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_open_rounded, size: 12, color: AppleCastTheme.appleYellow),
                SizedBox(width: 4),
                Text(
                  'Trust Device',
                  style: TextStyle(fontSize: 11, color: AppleCastTheme.appleYellow, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        );
      case DeviceTrustStatus.unknown:
        return const SizedBox.shrink();
    }
  }

  String _formatUdid(String udid) {
    if (udid.length <= 16) return udid;
    return '${udid.substring(0, 8)}...${udid.substring(udid.length - 6)}';
  }
}
