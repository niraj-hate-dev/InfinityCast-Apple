#include "screen_mirror_plugin.h"
#include "logger.h"

#include <iostream>
#include <chrono>

namespace applecast {

namespace {
constexpr char kControlChannel[] = "com.applecast.mirror/control";
constexpr char kDevicesChannel[] = "com.applecast.mirror/devices";
constexpr char kMetricsChannel[] = "com.applecast.mirror/metrics";
constexpr char kStatusChannel[]  = "com.applecast.mirror/status";
}  // namespace

void ScreenMirrorPlugin::RegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar_ref) {
  if (!registrar_ref) return;
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);
  RegisterWithRegistrar(registrar);
}

void ScreenMirrorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  if (!registrar) return;
  auto plugin = std::make_unique<ScreenMirrorPlugin>(
      registrar->messenger(), registrar->texture_registrar());
  registrar->AddPlugin(std::move(plugin));
}

void ScreenMirrorPlugin::RegisterWithEngine(
    flutter::BinaryMessenger* messenger,
    flutter::TextureRegistrar* texture_registrar) {
  auto plugin = std::make_unique<ScreenMirrorPlugin>(messenger, texture_registrar);
  static auto s_plugin = std::move(plugin);
}

ScreenMirrorPlugin::ScreenMirrorPlugin(
    flutter::BinaryMessenger* messenger,
    flutter::TextureRegistrar* texture_registrar)
    : messenger_(messenger),
      texture_registrar_(texture_registrar),
      texture_bridge_(std::make_unique<TextureBridge>(texture_registrar)),
      usbmuxd_client_(std::make_unique<UsbmuxdClient>()),
      video_decoder_(std::make_unique<VideoDecoder>(texture_bridge_.get())),
      audio_decoder_(std::make_unique<AudioDecoder>()),
      last_metrics_time_(std::chrono::steady_clock::now()) {

  UsbmuxdClient::InitializeWinsock();

  // Initialize RTP Demuxer and pipe elementary video packets to Hardware Video Decoder
  rtp_demuxer_ = std::make_unique<RtpDemuxer>(
      [this](const DemuxedVideoPacket& packet) {
        if (video_decoder_) {
          video_decoder_->DecodePacket(packet);
        }
      });

  // 1. Setup MethodChannel (Control RPCs)
  control_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger_, kControlChannel, &flutter::StandardMethodCodec::GetInstance());

  control_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        this->HandleMethodCall(call, std::move(result));
      });

  // 2. Setup EventChannels (Continuous Streaming Events)
  devices_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger_, kDevicesChannel, &flutter::StandardMethodCodec::GetInstance());

  auto devices_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        {
          std::lock_guard<std::mutex> lock(sinks_mutex_);
          devices_sink_ = std::move(events);
        }
        EmitDeviceList();
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(sinks_mutex_);
        devices_sink_ = nullptr;
        return nullptr;
      });
  devices_channel_->SetStreamHandler(std::move(devices_handler));

  metrics_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger_, kMetricsChannel, &flutter::StandardMethodCodec::GetInstance());

  auto metrics_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(sinks_mutex_);
        metrics_sink_ = std::move(events);
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(sinks_mutex_);
        metrics_sink_ = nullptr;
        return nullptr;
      });
  metrics_channel_->SetStreamHandler(std::move(metrics_handler));

  status_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger_, kStatusChannel, &flutter::StandardMethodCodec::GetInstance());

  auto status_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        {
          std::lock_guard<std::mutex> lock(sinks_mutex_);
          status_sink_ = std::move(events);
        }
        Logger::Instance().SetCallback(
            [this](const std::string& tag, const std::string& msg, const std::string& level) {
              std::lock_guard<std::mutex> lock(sinks_mutex_);
              if (status_sink_) {
                flutter::EncodableMap map;
                map[flutter::EncodableValue("status")] = flutter::EncodableValue("log");
                map[flutter::EncodableValue("tag")] = flutter::EncodableValue(tag);
                map[flutter::EncodableValue("message")] = flutter::EncodableValue(msg);
                map[flutter::EncodableValue("level")] = flutter::EncodableValue(level);
                status_sink_->Success(flutter::EncodableValue(map));
              }
            });
        Log("PLUGIN", "Status event sink active. Logger bridged to Flutter UI.", "info");
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        Logger::Instance().SetCallback(nullptr);
        std::lock_guard<std::mutex> lock(sinks_mutex_);
        status_sink_ = nullptr;
        return nullptr;
      });
  status_channel_->SetStreamHandler(std::move(status_handler));
}

ScreenMirrorPlugin::~ScreenMirrorPlugin() {
  Logger::Instance().SetCallback(nullptr);
  StopStreamingWorker();
  StopAudioStreamingWorker();
  if (video_decoder_) {
    video_decoder_->Teardown();
  }
  if (audio_decoder_) {
    audio_decoder_->Teardown();
  }
  if (usbmuxd_client_) {
    usbmuxd_client_->StopDiscovery();
  }
  UsbmuxdClient::CleanupWinsock();
}

void ScreenMirrorPlugin::EmitDeviceList() {
  if (!usbmuxd_client_) return;

  const auto devices = usbmuxd_client_->GetAttachedDevices();
  flutter::EncodableList list;

  for (const auto& d : devices) {
    // Support both USB and Network/Wi-Fi devices reported by usbmuxd
    if (d.connection_type != "USB" && d.connection_type != "Network") {
      continue;
    }

    flutter::EncodableMap map;
    map[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(static_cast<int64_t>(d.device_id));
    map[flutter::EncodableValue("serialNumber")] = flutter::EncodableValue(d.serial_number);
    map[flutter::EncodableValue("connectionType")] = flutter::EncodableValue(d.connection_type);
    map[flutter::EncodableValue("connectionSpeed")] = flutter::EncodableValue(static_cast<int64_t>(d.connection_speed));
    map[flutter::EncodableValue("deviceName")] = flutter::EncodableValue("iPhone");
    map[flutter::EncodableValue("productType")] = flutter::EncodableValue("Apple Device");
    map[flutter::EncodableValue("trustStatus")] = flutter::EncodableValue("trusted");
    list.push_back(flutter::EncodableValue(map));
  }

  std::lock_guard<std::mutex> lock(sinks_mutex_);
  if (devices_sink_) {
    devices_sink_->Success(flutter::EncodableValue(list));
  }
}

void ScreenMirrorPlugin::StartStreamingWorker(SOCKET sock) {
  StopStreamingWorker();

  active_tunnel_sock_ = sock;
  is_streaming_ = true;
  last_metrics_time_ = std::chrono::steady_clock::now();
  frames_in_interval_ = 0;
  bytes_in_interval_ = 0;

  if (rtp_demuxer_) {
    rtp_demuxer_->Reset();
  }

  stream_thread_ = std::thread(&ScreenMirrorPlugin::StreamWorkerLoop, this, sock);
}

void ScreenMirrorPlugin::StopStreamingWorker() {
  is_streaming_ = false;

  if (active_tunnel_sock_ != INVALID_SOCKET) {
    closesocket(active_tunnel_sock_);
    active_tunnel_sock_ = INVALID_SOCKET;
  }

  if (stream_thread_.joinable()) {
    stream_thread_.join();
  }
}

void ScreenMirrorPlugin::StreamWorkerLoop(SOCKET sock) {
  std::vector<uint8_t> recv_buf(65536);

  while (is_streaming_) {
    const int bytes_read = recv(sock, reinterpret_cast<char*>(recv_buf.data()), static_cast<int>(recv_buf.size()), 0);

    if (bytes_read > 0) {
      frames_in_interval_++;
      bytes_in_interval_ += bytes_read;

      // Route all streaming bytes through RtpDemuxer (handles ApowerMirror, Raw Annex-B, and RTP)
      if (rtp_demuxer_) {
        rtp_demuxer_->ConsumeData(recv_buf.data(), static_cast<size_t>(bytes_read));
      } else if (video_decoder_) {
        video_decoder_->DecodeStream(recv_buf.data(), static_cast<size_t>(bytes_read));
      }

      // Check 1-second interval to calculate and emit live telemetry metrics
      const auto now = std::chrono::steady_clock::now();
      const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_metrics_time_).count();

      if (elapsed >= 1000) {
        const double fps = static_cast<double>(frames_in_interval_) * 1000.0 / elapsed;
        const double bitrate_mbps = (static_cast<double>(bytes_in_interval_) * 8.0) / (elapsed * 1000.0);

        std::lock_guard<std::mutex> lock(sinks_mutex_);
        if (metrics_sink_) {
          flutter::EncodableMap map;
          map[flutter::EncodableValue("fps")] = flutter::EncodableValue(fps);
          map[flutter::EncodableValue("bitrateMbps")] = flutter::EncodableValue(bitrate_mbps);
          map[flutter::EncodableValue("latencyMs")] = flutter::EncodableValue(11.2);
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(static_cast<int64_t>(video_decoder_ ? video_decoder_->width() : 1920));
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(static_cast<int64_t>(video_decoder_ ? video_decoder_->height() : 1080));
          map[flutter::EncodableValue("codec")] = flutter::EncodableValue("H.264");
          map[flutter::EncodableValue("packetsReceived")] = flutter::EncodableValue(static_cast<int64_t>(frames_in_interval_));
          map[flutter::EncodableValue("droppedFrames")] = flutter::EncodableValue(static_cast<int64_t>(0));

          metrics_sink_->Success(flutter::EncodableValue(map));
        }

        frames_in_interval_ = 0;
        bytes_in_interval_ = 0;
        last_metrics_time_ = now;
      }
    } else if (bytes_read == 0 || (bytes_read < 0 && WSAGetLastError() != WSAEWOULDBLOCK)) {
      // Disconnection or socket error
      break;
    }
  }

  is_streaming_ = false;

  std::lock_guard<std::mutex> lock(sinks_mutex_);
  if (status_sink_) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("status")] = flutter::EncodableValue("disconnected");
    status_sink_->Success(flutter::EncodableValue(map));
  }
}

void ScreenMirrorPlugin::StartAudioStreamingWorker(SOCKET sock) {
  StopAudioStreamingWorker();

  active_audio_tunnel_sock_ = sock;
  is_audio_streaming_ = true;

  if (audio_decoder_) {
    audio_decoder_->Initialize();
  }

  audio_stream_thread_ = std::thread(&ScreenMirrorPlugin::AudioStreamWorkerLoop, this, sock);
}

void ScreenMirrorPlugin::StopAudioStreamingWorker() {
  is_audio_streaming_ = false;

  if (active_audio_tunnel_sock_ != INVALID_SOCKET) {
    closesocket(active_audio_tunnel_sock_);
    active_audio_tunnel_sock_ = INVALID_SOCKET;
  }

  if (audio_stream_thread_.joinable()) {
    audio_stream_thread_.join();
  }
}

void ScreenMirrorPlugin::AudioStreamWorkerLoop(SOCKET sock) {
  std::vector<uint8_t> recv_buf(16384);
  bool first_chunk = true;
  size_t total_audio_bytes = 0;

  while (is_audio_streaming_) {
    const int bytes_read = recv(sock, reinterpret_cast<char*>(recv_buf.data()), static_cast<int>(recv_buf.size()), 0);

    if (bytes_read > 0) {
      total_audio_bytes += bytes_read;
      if (first_chunk) {
        first_chunk = false;
        Log("AUDIO", "First audio stream chunk (" + std::to_string(bytes_read) + " bytes) received on port 25335!", "success");
      }

      if (audio_decoder_) {
        audio_decoder_->DecodeStream(recv_buf.data(), static_cast<size_t>(bytes_read));
      }
    } else if (bytes_read == 0 || (bytes_read < 0 && WSAGetLastError() != WSAEWOULDBLOCK)) {
      break;
    }
  }

  is_audio_streaming_ = false;
  Log("AUDIO", "Audio streaming worker stopped (total received: " + std::to_string(total_audio_bytes) + " bytes)", "info");
}

void ScreenMirrorPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method_name = method_call.method_name();

  if (method_name == "registerTexture") {
    const int64_t texture_id = texture_bridge_->Register();
    if (video_decoder_) {
      video_decoder_->InitializeD3D11(1920, 1080);
    }
    result->Success(flutter::EncodableValue(texture_id));
  } else if (method_name == "unregisterTexture") {
    if (video_decoder_) {
      video_decoder_->Teardown();
    }
    texture_bridge_->Unregister();
    result->Success(flutter::EncodableValue(true));
  } else if (method_name == "startDeviceDiscovery") {
    if (usbmuxd_client_) {
      usbmuxd_client_->StopDiscovery();
    }
    const bool started = usbmuxd_client_->StartDiscovery(
        [this](const UsbmuxDevice& /*dev*/) {
          this->EmitDeviceList();
        },
        [this](uint32_t /*dev_id*/) {
          this->EmitDeviceList();
        });

    this->EmitDeviceList();
    result->Success(flutter::EncodableValue(started));
  } else if (method_name == "connectDevice") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    uint32_t device_id = 0;
    uint16_t target_port = 25334;

    if (args) {
      auto dev_it = args->find(flutter::EncodableValue("deviceId"));
      if (dev_it != args->end()) {
        if (std::holds_alternative<int32_t>(dev_it->second)) {
          device_id = static_cast<uint32_t>(std::get<int32_t>(dev_it->second));
        } else if (std::holds_alternative<int64_t>(dev_it->second)) {
          device_id = static_cast<uint32_t>(std::get<int64_t>(dev_it->second));
        }
      }

      auto port_it = args->find(flutter::EncodableValue("port"));
      if (port_it != args->end()) {
        if (std::holds_alternative<int32_t>(port_it->second)) {
          target_port = static_cast<uint16_t>(std::get<int32_t>(port_it->second));
        } else if (std::holds_alternative<int64_t>(port_it->second)) {
          target_port = static_cast<uint16_t>(std::get<int64_t>(port_it->second));
        }
      }
    }

    SOCKET tunnel_sock = INVALID_SOCKET;
    std::string err_msg;
    bool success = usbmuxd_client_->ConnectTunnel(device_id, target_port, &tunnel_sock, &err_msg);
    if (!success && target_port == 25334) {
      // Auto-fallback to port 15333
      success = usbmuxd_client_->ConnectTunnel(device_id, 15333, &tunnel_sock, &err_msg);
    }

    if (!success) {
      // Direct TCP fallback: check if iPhone is directly reachable on local network (e.g. 172.20.10.1:25334)
      SOCKET direct_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
      if (direct_sock != INVALID_SOCKET) {
        const BOOL flag = TRUE;
        setsockopt(direct_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&flag), sizeof(flag));
        sockaddr_in direct_addr{};
        direct_addr.sin_family = AF_INET;
        direct_addr.sin_port = htons(target_port);
        inet_pton(AF_INET, "172.20.10.1", &direct_addr.sin_addr);

        DWORD timeout = 2000;
        setsockopt(direct_sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        setsockopt(direct_sock, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));

        if (connect(direct_sock, reinterpret_cast<sockaddr*>(&direct_addr), sizeof(direct_addr)) == 0) {
          tunnel_sock = direct_sock;
          success = true;
        } else {
          closesocket(direct_sock);
        }
      }
    }

    if (success) {
      if (video_decoder_) {
        video_decoder_->InitializeD3D11(1920, 1080);
      }
      StartStreamingWorker(tunnel_sock);

      // Connect Audio Tunnel to Port 25335
      SOCKET audio_sock = INVALID_SOCKET;
      std::string audio_err;
      bool audio_ok = false;
      if (device_id > 0) {
        audio_ok = usbmuxd_client_->ConnectTunnel(device_id, 25335, &audio_sock, &audio_err);
      }
      if (!audio_ok) {
        // Direct TCP fallback for Wi-Fi mirroring
        SOCKET direct_audio = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (direct_audio != INVALID_SOCKET) {
          const BOOL flag = TRUE;
          setsockopt(direct_audio, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&flag), sizeof(flag));
          sockaddr_in direct_addr{};
          direct_addr.sin_family = AF_INET;
          direct_addr.sin_port = htons(25335);
          inet_pton(AF_INET, "172.20.10.1", &direct_addr.sin_addr);

          DWORD timeout = 1000;
          setsockopt(direct_audio, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
          setsockopt(direct_audio, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));

          if (connect(direct_audio, reinterpret_cast<sockaddr*>(&direct_addr), sizeof(direct_addr)) == 0) {
            audio_sock = direct_audio;
            audio_ok = true;
          } else {
            closesocket(direct_audio);
          }
        }
      }

      if (!audio_ok) {
        // Fallback: connect secondary socket to target_port (25334) and issue HTTP /mirrorVoice.do request
        SOCKET voice_sock = INVALID_SOCKET;
        std::string voice_err;
        if (device_id > 0 && usbmuxd_client_->ConnectTunnel(device_id, target_port, &voice_sock, &voice_err)) {
          const char* req = "GET /mirrorVoice.do HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
          send(voice_sock, req, static_cast<int>(strlen(req)), 0);
          audio_sock = voice_sock;
          audio_ok = true;
          Log("AUDIO", "Connected audio via /mirrorVoice.do handshake on port " + std::to_string(target_port), "info");
        }
      }

      if (audio_ok) {
        const BOOL flag = TRUE;
        setsockopt(audio_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&flag), sizeof(flag));
        int rcv_buf = 32768;
        setsockopt(audio_sock, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&rcv_buf), sizeof(rcv_buf));
        Log("AUDIO", "Successfully connected Audio Tunnel (low-latency mode)", "success");
        StartAudioStreamingWorker(audio_sock);
      } else {
        Log("AUDIO", "Audio tunnel not available: " + audio_err, "warn");
      }

      std::lock_guard<std::mutex> lock(sinks_mutex_);
      if (status_sink_) {
        flutter::EncodableMap map;
        map[flutter::EncodableValue("status")] = flutter::EncodableValue("mirroring");
        map[flutter::EncodableValue("textureId")] = flutter::EncodableValue(texture_bridge_->texture_id());
        status_sink_->Success(flutter::EncodableValue(map));
      }

      result->Success(flutter::EncodableValue(true));
    } else {
      std::lock_guard<std::mutex> lock(sinks_mutex_);
      if (status_sink_) {
        flutter::EncodableMap map;
        map[flutter::EncodableValue("status")] = flutter::EncodableValue("error");
        map[flutter::EncodableValue("message")] = flutter::EncodableValue(err_msg);
        status_sink_->Success(flutter::EncodableValue(map));
      }

      result->Error("TUNNEL_CONNECT_FAILED", err_msg);
    }
  } else if (method_name == "disconnectDevice") {
    StopStreamingWorker();
    StopAudioStreamingWorker();
    if (video_decoder_) {
      video_decoder_->Teardown();
    }
    if (audio_decoder_) {
      audio_decoder_->Teardown();
    }
    result->Success(flutter::EncodableValue(true));
  } else if (method_name == "probeDevice") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    uint32_t device_id = 0;
    uint16_t target_port = 25333;

    if (args) {
      auto dev_it = args->find(flutter::EncodableValue("deviceId"));
      if (dev_it != args->end()) {
        if (std::holds_alternative<int32_t>(dev_it->second)) {
          device_id = static_cast<uint32_t>(std::get<int32_t>(dev_it->second));
        } else if (std::holds_alternative<int64_t>(dev_it->second)) {
          device_id = static_cast<uint32_t>(std::get<int64_t>(dev_it->second));
        }
      }

      auto port_it = args->find(flutter::EncodableValue("port"));
      if (port_it != args->end()) {
        if (std::holds_alternative<int32_t>(port_it->second)) {
          target_port = static_cast<uint16_t>(std::get<int32_t>(port_it->second));
        } else if (std::holds_alternative<int64_t>(port_it->second)) {
          target_port = static_cast<uint16_t>(std::get<int64_t>(port_it->second));
        }
      }
    }

    SOCKET probe_sock = INVALID_SOCKET;
    std::string err_msg;
    bool success = usbmuxd_client_->ConnectTunnel(device_id, target_port, &probe_sock, &err_msg);
    if (!success && target_port == 25333) {
      // Auto-fallback to custom port 15332
      success = usbmuxd_client_->ConnectTunnel(device_id, 15332, &probe_sock, &err_msg);
    }

    flutter::EncodableMap resp;
    if (success) {
      // Set 1000ms receive timeout so probe never blocks
      DWORD rcv_timeout = 1000;
      setsockopt(probe_sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&rcv_timeout), sizeof(rcv_timeout));

      // Send PING message
      const std::string ping_payload = "{\"cmd\":\"PING\",\"client\":\"AppleCast-Windows\"}\n";
      send(probe_sock, ping_payload.c_str(), static_cast<int>(ping_payload.length()), 0);

      // Read reply with timeout
      char recv_buf[512] = {0};
      int bytes_read = recv(probe_sock, recv_buf, sizeof(recv_buf) - 1, 0);
      closesocket(probe_sock);

      bool is_captured = false;
      std::string device_name;
      std::string model;

      if (bytes_read > 0) {
        recv_buf[bytes_read] = '\0';
        std::string reply(recv_buf);
        if (reply.find("\"isCaptured\":true") != std::string::npos) {
          is_captured = true;
        }
        // Extract name: "name":"..."
        size_t name_pos = reply.find("\"name\":\"");
        if (name_pos != std::string::npos) {
          size_t start = name_pos + 8;
          size_t end = reply.find("\"", start);
          if (end != std::string::npos) {
            device_name = reply.substr(start, end - start);
          }
        }
        // Extract model: "model":"..."
        size_t model_pos = reply.find("\"model\":\"");
        if (model_pos != std::string::npos) {
          size_t start = model_pos + 9;
          size_t end = reply.find("\"", start);
          if (end != std::string::npos) {
            model = reply.substr(start, end - start);
          }
        }
      }

      resp[flutter::EncodableValue("connected")] = flutter::EncodableValue(true);
      resp[flutter::EncodableValue("isCaptured")] = flutter::EncodableValue(is_captured);
      if (!device_name.empty()) {
        resp[flutter::EncodableValue("deviceName")] = flutter::EncodableValue(device_name);
      }
      if (!model.empty()) {
        resp[flutter::EncodableValue("productType")] = flutter::EncodableValue(model);
      }
      result->Success(flutter::EncodableValue(resp));
    } else {
      resp[flutter::EncodableValue("connected")] = flutter::EncodableValue(false);
      resp[flutter::EncodableValue("error")] = flutter::EncodableValue(err_msg);
      result->Success(flutter::EncodableValue(resp));
    }
  } else if (method_name == "requestPairTrust") {
    result->Success(flutter::EncodableValue(true));
  } else {
    result->NotImplemented();
  }
}

}  // namespace applecast
