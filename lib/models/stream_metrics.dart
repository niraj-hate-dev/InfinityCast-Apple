/// Real-time stream telemetry metrics reported from the native demuxer/decoder.
class StreamMetrics {
  final double fps;
  final double bitrateMbps;
  final double latencyMs;
  final int width;
  final int height;
  final String codec; // 'H.264' or 'HEVC'
  final int packetsReceived;
  final int droppedFrames;

  const StreamMetrics({
    this.fps = 0.0,
    this.bitrateMbps = 0.0,
    this.latencyMs = 0.0,
    this.width = 1920,
    this.height = 1080,
    this.codec = 'H.264',
    this.packetsReceived = 0,
    this.droppedFrames = 0,
  });

  factory StreamMetrics.fromMap(Map<dynamic, dynamic> map) {
    return StreamMetrics(
      fps: (map['fps'] as num?)?.toDouble() ?? 0.0,
      bitrateMbps: (map['bitrateMbps'] as num?)?.toDouble() ?? 0.0,
      latencyMs: (map['latencyMs'] as num?)?.toDouble() ?? 0.0,
      width: (map['width'] as num?)?.toInt() ?? 1920,
      height: (map['height'] as num?)?.toInt() ?? 1080,
      codec: map['codec']?.toString() ?? 'H.264',
      packetsReceived: (map['packetsReceived'] as num?)?.toInt() ?? 0,
      droppedFrames: (map['droppedFrames'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'fps': fps,
      'bitrateMbps': bitrateMbps,
      'latencyMs': latencyMs,
      'width': width,
      'height': height,
      'codec': codec,
      'packetsReceived': packetsReceived,
      'droppedFrames': droppedFrames,
    };
  }

  static const StreamMetrics empty = StreamMetrics();
}
