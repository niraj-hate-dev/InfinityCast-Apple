/// Severity and category levels for debug console entries.
enum LogLevel {
  info,
  success,
  warning,
  error,
  frame,
}

/// Immutable record of an internal system event or telemetry frame.
class DebugLogEntry {
  final DateTime timestamp;
  final String tag;
  final String message;
  final LogLevel level;

  const DebugLogEntry({
    required this.timestamp,
    required this.tag,
    required this.message,
    this.level = LogLevel.info,
  });

  /// Formatted timestamp string `HH:mm:ss.SSS`
  String get timeFormatted {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  @override
  String toString() => '[$timeFormatted] [$tag] $message';
}
