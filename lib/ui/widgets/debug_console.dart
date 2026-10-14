import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme.dart';
import '../../models/debug_log_entry.dart';

/// Floating, scrollable developer terminal overlay.
/// Real-time stream of usbmuxd socket events, video decode metrics, and errors.
class DebugConsole extends StatefulWidget {
  final List<DebugLogEntry> logs;
  final VoidCallback onClose;
  final VoidCallback onClear;

  const DebugConsole({
    super.key,
    required this.logs,
    required this.onClose,
    required this.onClear,
  });

  @override
  State<DebugConsole> createState() => _DebugConsoleState();
}

class _DebugConsoleState extends State<DebugConsole> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  String _filter = 'ALL'; // 'ALL', 'STREAM', 'USBMUXD', 'ERRORS'

  @override
  void initState() {
    super.initState();
    _scrollToBottom();
  }

  @override
  void didUpdateWidget(DebugConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.logs.length != oldWidget.logs.length && _autoScroll) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<DebugLogEntry> get _filteredLogs {
    if (_filter == 'ALL') return widget.logs;
    if (_filter == 'STREAM') {
      return widget.logs.where((l) => l.tag == 'STREAM' || l.tag == 'DECODER').toList();
    }
    if (_filter == 'USBMUXD') {
      return widget.logs.where((l) => l.tag == 'USBMUXD' || l.tag == 'TUNNEL').toList();
    }
    if (_filter == 'ERRORS') {
      return widget.logs.where((l) => l.level == LogLevel.error || l.level == LogLevel.warning).toList();
    }
    return widget.logs;
  }

  void _copyAllLogs() {
    final text = widget.logs.map((l) => l.toString()).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied console logs to clipboard.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xEE0A0D14),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppleCastTheme.appleBlue.withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.75),
                blurRadius: 32,
                spreadRadius: 6,
              ),
              BoxShadow(
                color: AppleCastTheme.appleBlue.withValues(alpha: 0.15),
                blurRadius: 16,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Terminal Top Title Bar
              _buildTitleBar(),
              // Filter Toolbar
              _buildFilterBar(),
              const Divider(height: 1, color: Color(0xFF1E2638)),
              // Log List Terminal Area
              Expanded(
                child: logs.isEmpty ? _buildEmptyState() : _buildLogList(logs),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF101522),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E2638)),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppleCastTheme.appleGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.terminal_rounded,
              color: AppleCastTheme.appleGreen,
              size: 15,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'DEVELOPER DEBUG CONSOLE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
              color: AppleCastTheme.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${widget.logs.length} msgs',
              style: const TextStyle(
                fontSize: 10,
                color: AppleCastTheme.textSecondary,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const Spacer(),
          // Auto-scroll toggle
          IconButton(
            icon: Icon(
              Icons.vertical_align_bottom_rounded,
              size: 16,
              color: _autoScroll ? AppleCastTheme.appleGreen : AppleCastTheme.textSecondary,
            ),
            tooltip: _autoScroll ? 'Auto-scroll Enabled' : 'Auto-scroll Paused',
            onPressed: () {
              setState(() {
                _autoScroll = !_autoScroll;
                if (_autoScroll) _scrollToBottom();
              });
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          // Copy button
          IconButton(
            icon: const Icon(Icons.copy_all_rounded, size: 16, color: AppleCastTheme.textSecondary),
            tooltip: 'Copy All Logs',
            onPressed: _copyAllLogs,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          // Clear button
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, size: 16, color: AppleCastTheme.textSecondary),
            tooltip: 'Clear Logs',
            onPressed: widget.onClear,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          // Close button
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16, color: AppleCastTheme.appleRed),
            tooltip: 'Close Terminal',
            onPressed: widget.onClose,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final filters = [
      {'id': 'ALL', 'label': 'All'},
      {'id': 'STREAM', 'label': 'Video/FPS'},
      {'id': 'USBMUXD', 'label': 'Usbmuxd'},
      {'id': 'ERRORS', 'label': 'Warnings/Errors'},
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: const Color(0xFF0C101A),
      child: Row(
        children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _filter = f['id']!;
                    _scrollToBottom();
                  });
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _filter == f['id']
                        ? AppleCastTheme.appleBlue.withValues(alpha: 0.25)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _filter == f['id']
                          ? AppleCastTheme.appleBlue
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Text(
                    f['label']!,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: _filter == f['id'] ? FontWeight.bold : FontWeight.normal,
                      color: _filter == f['id'] ? Colors.white : AppleCastTheme.textSecondary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLogList(List<DebugLogEntry> logs) {
    return SelectionArea(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final entry = logs[index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timestamp
                Text(
                  entry.timeFormatted,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748B),
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                // Tag Badge
                _buildTagBadge(entry.tag, entry.level),
                const SizedBox(width: 8),
                // Message
                Expanded(
                  child: Text(
                    entry.message,
                    style: TextStyle(
                      fontSize: 11,
                      color: _colorForLevel(entry.level),
                      fontFamily: 'monospace',
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTagBadge(String tag, LogLevel level) {
    final color = _colorForLevel(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 0.8,
        ),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Color _colorForLevel(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return const Color(0xFF94A3B8);
      case LogLevel.success:
        return AppleCastTheme.appleGreen;
      case LogLevel.warning:
        return AppleCastTheme.appleYellow;
      case LogLevel.error:
        return AppleCastTheme.appleRed;
      case LogLevel.frame:
        return const Color(0xFF64D2FF);
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.terminal_rounded, size: 36, color: Color(0xFF334155)),
          SizedBox(height: 10),
          Text(
            'Console Initialized',
            style: TextStyle(fontSize: 13, color: AppleCastTheme.textSecondary, fontFamily: 'monospace'),
          ),
          SizedBox(height: 4),
          Text(
            'Listening for usbmuxd tunnel and Direct3D 11 video frames...',
            style: TextStyle(fontSize: 11, color: Color(0xFF475569), fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
