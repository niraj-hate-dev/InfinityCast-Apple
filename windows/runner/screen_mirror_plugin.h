#ifndef RUNNER_SCREEN_MIRROR_PLUGIN_H_
#define RUNNER_SCREEN_MIRROR_PLUGIN_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef _WINSOCK_DEPRECATED_NO_WARNINGS
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <flutter/binary_messenger.h>
#include <flutter/texture_registrar.h>
#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>
#include <thread>
#include <atomic>
#include <mutex>

#include "texture_bridge.h"
#include "usbmuxd_client.h"
#include "rtp_demuxer.h"
#include "video_decoder.h"
#include "audio_decoder.h"

namespace applecast {

/// Native Windows Plugin managing Platform Channels & Usbmuxd/FFmpeg Lifecycles.
class ScreenMirrorPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  static void RegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
  static void RegisterWithEngine(flutter::BinaryMessenger* messenger,
                                flutter::TextureRegistrar* texture_registrar);

  ScreenMirrorPlugin(flutter::BinaryMessenger* messenger,
                     flutter::TextureRegistrar* texture_registrar);
  virtual ~ScreenMirrorPlugin();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void EmitDeviceList();
  void StartStreamingWorker(SOCKET sock);
  void StopStreamingWorker();
  void StreamWorkerLoop(SOCKET sock);

  void StartAudioStreamingWorker(uint32_t device_id, const std::string& host_ip);
  void StopAudioStreamingWorker();
  void AudioStreamWorkerLoop();

  flutter::BinaryMessenger* messenger_ = nullptr;
  flutter::TextureRegistrar* texture_registrar_ = nullptr;
  std::unique_ptr<TextureBridge> texture_bridge_;
  std::unique_ptr<UsbmuxdClient> usbmuxd_client_;
  std::unique_ptr<RtpDemuxer> rtp_demuxer_;
  std::unique_ptr<VideoDecoder> video_decoder_;
  std::unique_ptr<AudioDecoder> audio_decoder_;

  // Video tunnel streaming state
  std::atomic<bool> is_streaming_{false};
  SOCKET active_tunnel_sock_ = INVALID_SOCKET;
  std::thread stream_thread_;

  // Audio tunnel streaming state
  std::atomic<bool> is_audio_streaming_{false};
  SOCKET active_audio_tunnel_sock_ = INVALID_SOCKET;
  std::thread audio_stream_thread_;
  uint32_t current_device_id_ = 0;
  std::string current_host_ip_;

  // Telemetry metrics tracking
  std::chrono::steady_clock::time_point last_metrics_time_;
  uint64_t bytes_in_interval_ = 0;
  uint32_t frames_in_interval_ = 0;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> control_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> devices_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> metrics_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> status_channel_;

  std::mutex sinks_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> devices_sink_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> metrics_sink_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> status_sink_;
};

}  // namespace applecast

#endif  // RUNNER_SCREEN_MIRROR_PLUGIN_H_
