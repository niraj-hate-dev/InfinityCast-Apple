import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/mirror_controller.dart';

/// Modal configuration dialog for Video Decoder Mode (Auto / CPU / GPU) and Auto-Connect.
class SettingsDialog extends StatefulWidget {
  final MirrorController controller;

  const SettingsDialog({
    super.key,
    required this.controller,
  });

  static Future<void> show(BuildContext context, MirrorController controller) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => SettingsDialog(controller: controller),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late String _currentMode;
  late bool _autoConnect;

  @override
  void initState() {
    super.initState();
    _currentMode = widget.controller.state.decoderMode;
    _autoConnect = widget.controller.state.autoConnectEnabled;
  }

  Future<void> _selectMode(String mode) async {
    setState(() => _currentMode = mode);
    await widget.controller.setDecoderMode(mode);
  }

  void _toggleAutoConnect(bool value) {
    setState(() => _autoConnect = value);
    widget.controller.setAutoConnectEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final device = state.selectedDevice;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 540,
        decoration: BoxDecoration(
          color: const Color(0xFF0B1426),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF162544),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Dialog Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppleCastTheme.iconBlue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.settings_outlined,
                      size: 20,
                      color: AppleCastTheme.iconBlue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Settings',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20, color: Color(0xFF94A3B8)),
                    splashRadius: 18,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const Divider(color: Color(0xFF162544), height: 1),

            // Dialog Body
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section: Video Decoder Engine
                  const Text(
                    'VIDEO DECODER ENGINE',
                    style: TextStyle(
                      color: Color(0xFF8E9BB5),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 12),

                  _buildDecoderOption(
                    mode: 'auto',
                    title: 'Auto (Recommended)',
                    subtitle: 'Automatically chooses GPU Direct3D 11 acceleration, with seamless CPU fallback.',
                    icon: Icons.auto_awesome_rounded,
                  ),
                  const SizedBox(height: 8),

                  _buildDecoderOption(
                    mode: 'cpu',
                    title: 'CPU (Multi-Core Software)',
                    subtitle: 'Decodes video frames using multi-threaded CPU software. Best for PCs with older or budget graphics cards.',
                    icon: Icons.memory_rounded,
                  ),
                  const SizedBox(height: 8),

                  _buildDecoderOption(
                    mode: 'gpu',
                    title: 'GPU (Direct3D 11 Acceleration)',
                    subtitle: 'Hardware zero-copy Direct3D 11 decoder. Delivers ultra-low latency and minimal CPU load.',
                    icon: Icons.speed_rounded,
                  ),

                  const SizedBox(height: 24),

                  // Section: Auto-Connect
                  const Text(
                    'MIRRORING BEHAVIOR',
                    style: TextStyle(
                      color: Color(0xFF8E9BB5),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF070B16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF162544),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cable_rounded,
                          size: 22,
                          color: AppleCastTheme.iconBlue,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                'Auto-Connect on USB Broadcast',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Automatically starts mirroring when iPhone is connected and broadcasting.',
                                style: TextStyle(
                                  color: Color(0xFF8E9BB5),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _autoConnect,
                          activeThumbColor: Colors.white,
                          activeTrackColor: AppleCastTheme.iconBlue,
                          inactiveThumbColor: const Color(0xFF94A3B8),
                          inactiveTrackColor: const Color(0xFF162544),
                          onChanged: _toggleAutoConnect,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Diagnostic Info Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF070B16).withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF162544).withValues(alpha: 0.7),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          size: 15,
                          color: Color(0xFF64748B),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            device != null
                                ? 'Active Device: ${device.deviceName} (ID: ${device.deviceId}) | Video: ${AppleCastConstants.defaultDeviceStreamingPort} | Audio: 25335'
                                : 'No device connected | Listening on 127.0.0.1:27015',
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Dialog Footer
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppleCastTheme.iconBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDecoderOption({
    required String mode,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final bool isSelected = _currentMode == mode;

    return InkWell(
      onTap: () => _selectMode(mode),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppleCastTheme.iconBlue.withValues(alpha: 0.12)
              : const Color(0xFF070B16),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppleCastTheme.iconBlue : const Color(0xFF162544),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: isSelected ? AppleCastTheme.iconBlue : const Color(0xFF64748B),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? Colors.white : const Color(0xFFE2E8F0),
                      fontSize: 13.5,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF8E9BB5),
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? AppleCastTheme.iconBlue : const Color(0xFF475569),
                  width: 2,
                ),
                color: isSelected ? AppleCastTheme.iconBlue : Colors.transparent,
              ),
              child: isSelected
                  ? const Center(
                      child: Icon(Icons.check, size: 12, color: Colors.white),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
