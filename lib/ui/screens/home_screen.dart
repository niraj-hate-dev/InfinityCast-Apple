import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme.dart';
import '../../services/mirror_controller.dart';
import '../widgets/debug_console.dart';
import '../widgets/ios_transmitter_view.dart';
import '../widgets/mirror_viewport.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/sidebar_navigation.dart';
import '../widgets/standby_canvas.dart';
import '../widgets/top_status_bar.dart';

/// Primary Master Screen of InfinityCast.
/// Renders the desktop studio layout matching the modern deep-navy interface on Windows,
/// or the transmitter controller view on iOS devices.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final MirrorController _controller;
  SidebarItem _selectedSidebarItem = SidebarItem.mirrorMode;

  @override
  void initState() {
    super.initState();
    _controller = MirrorController();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSidebarItemSelected(SidebarItem item) {
    if (item == SidebarItem.settings) {
      SettingsDialog.show(context, _controller);
      return;
    }
    setState(() => _selectedSidebarItem = item);
  }

  @override
  Widget build(BuildContext context) {
    // If running on an iOS device, display the Companion Transmitter UI
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return IosTransmitterView(controller: _controller);
    }

    // Windows Desktop Studio UI
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;

        // When in Fullscreen mode, dedicate 100% of the screen to the viewport
        if (state.isFullscreen) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                MirrorViewport(
                  textureId: state.textureId,
                  status: state.status,
                  isRotatedLandscape: state.isRotatedLandscape,
                  isHudVisible: state.isHudVisible,
                  isConsoleVisible: state.isConsoleVisible,
                  metrics: state.metrics,
                  onToggleRotate: _controller.toggleRotation,
                  onStopMirroring: _controller.stopMirroring,
                  onToggleFullscreen: _controller.toggleFullscreen,
                  onToggleHud: _controller.toggleHudVisibility,
                  onToggleConsole: _controller.toggleConsoleVisibility,
                ),
                Positioned(
                  top: 16,
                  left: 16,
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white70),
                    tooltip: 'Exit Fullscreen (Esc)',
                    onPressed: _controller.toggleFullscreen,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                // Floating Developer Console Overlay in Fullscreen
                if (state.isConsoleVisible)
                  Positioned(
                    right: 20,
                    bottom: 20,
                    width: 580,
                    height: 320,
                    child: DebugConsole(
                      logs: state.logs,
                      onClose: _controller.toggleConsoleVisibility,
                      onClear: _controller.clearLogs,
                    ),
                  ),
              ],
            ),
          );
        }

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.f11): _controller.toggleFullscreen,
            const SingleActivator(LogicalKeyboardKey.f12): _controller.toggleConsoleVisibility,
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: AppleCastTheme.navyBackground,
              body: Row(
                children: [
                  // Left Navigation Sidebar
                  SidebarNavigation(
                    selectedItem: _selectedSidebarItem,
                    onItemSelected: _onSidebarItemSelected,
                    onOpenSettings: () => SettingsDialog.show(context, _controller),
                  ),

                  // Main Content & Top Header Area
                  Expanded(
                    child: Column(
                      children: [
                        // Window Header & Status Bar
                        TopStatusBar(
                          state: state,
                          onToggleTheme: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('InfinityCast is running in Dark Mode'),
                                duration: Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),

                        // Center Canvas: Active Mirror Stream OR Standby Screen
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: state.isMirroring
                                    ? MirrorViewport(
                                        textureId: state.textureId,
                                        status: state.status,
                                        isRotatedLandscape: state.isRotatedLandscape,
                                        isHudVisible: state.isHudVisible,
                                        isConsoleVisible: state.isConsoleVisible,
                                        metrics: state.metrics,
                                        onToggleRotate: _controller.toggleRotation,
                                        onStopMirroring: _controller.stopMirroring,
                                        onToggleFullscreen: _controller.toggleFullscreen,
                                        onToggleHud: _controller.toggleHudVisibility,
                                        onToggleConsole: _controller.toggleConsoleVisibility,
                                      )
                                    : StandbyCanvas(
                                        state: state,
                                        onStartManual: () {
                                          if (state.selectedDevice != null) {
                                            _controller.startMirroring(device: state.selectedDevice);
                                          }
                                        },
                                      ),
                              ),

                              // Floating Developer Console Overlay
                              if (state.isConsoleVisible)
                                Positioned(
                                  right: 20,
                                  bottom: 20,
                                  width: 580,
                                  height: 320,
                                  child: DebugConsole(
                                    logs: state.logs,
                                    onClose: _controller.toggleConsoleVisibility,
                                    onClear: _controller.clearLogs,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
