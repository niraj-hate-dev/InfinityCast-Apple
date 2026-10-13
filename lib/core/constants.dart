/// AppleCast Core Architectural Constants
/// Matches the protocol specifications defined in the architecture blueprint.
class AppleCastConstants {
  AppleCastConstants._();

  // Platform Channel Names
  static const String controlChannel = 'com.applecast.mirror/control';
  static const String eventChannelDevices = 'com.applecast.mirror/devices';
  static const String eventChannelMetrics = 'com.applecast.mirror/metrics';
  static const String eventChannelStatus = 'com.applecast.mirror/status';

  // Usbmuxd & Network Protocol Defaults
  static const int usbmuxdPort = 27015;
  static const String usbmuxdLoopbackIp = '127.0.0.1';
  static const int defaultDeviceStreamingPort = 15333;
  static const int appleLockdownPort = 62078;

  // Interleaved RTP Stream Framing Constants (RFC 2326 / Section 3 of blueprint)
  static const int rtpMagicByte = 0x24; // '$' (36)
  static const int rtpChannelVideo = 0x00;
  static const int rtpChannelFeedback = 0x01;
  static const int rtpHeaderSize = 12;

  // Default Stream Encoding Parameters
  static const int defaultWidth = 1920;
  static const int defaultHeight = 1080;
  static const int defaultFramerate = 60;
  static const int defaultBitrateMbps = 15;

  // App Group Identifier for iOS Companion and Broadcast Extension IPC
  static const String iosAppGroupId = 'group.com.applecast.companion';
  static const String iosExtensionBundleId = 'com.applecast.companion.extension';
}
