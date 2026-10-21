#include "video_decoder.h"
#include "logger.h"

#include <iostream>
#include <sstream>
#include <iomanip>
#include <cmath>

namespace applecast {

namespace {

// FFmpeg C API Constants & Typedefs for Dynamic Binding
constexpr int kAvCodecIdH264 = 27;
constexpr int kAvCodecFlagLowDelay = (1 << 19);
constexpr int kAvHwDeviceTypeD3d11va = 4;
constexpr int kAvPixFmtD3d11 = 174;
constexpr int kAvPixFmtYuv420p = 0;
constexpr int kAvPixFmtRgba = 26;
constexpr int kAvPixFmtBgra = 28;
constexpr int kSwsFastBilinear = 1;
constexpr int64_t kAvNoPtsValue = static_cast<int64_t>(0x8000000000000000ULL);

// Exact 64-bit struct layouts for AVPacket and AVFrame across FFmpeg 6.x and 7.x
struct FF_AVPacket {
  void* buf;                // offset 0
  int64_t pts;             // offset 8
  int64_t dts;             // offset 16
  uint8_t* data;           // offset 24
  int size;                // offset 32
  int stream_index;        // offset 36
  int flags;               // offset 40
  void* side_data;         // offset 48
  int side_data_elems;     // offset 56
  int64_t duration;        // offset 64
  int64_t pos;             // offset 72
  void* opaque;            // offset 80
  void* opaque_ref;        // offset 88
  int time_base_num;       // offset 96
  int time_base_den;       // offset 100
};

struct FF_AVFrame {
  uint8_t* data[8];        // offset 0..63
  int linesize[8];         // offset 64..95
  uint8_t** extended_data; // offset 96..103
  int width;               // offset 104
  int height;              // offset 108
  int nb_samples;          // offset 112
  int format;              // offset 116
};

typedef void* (*FnAvcodecFindDecoder)(int id);
typedef void* (*FnAvcodecAllocContext3)(const void* codec);
typedef void  (*FnAvcodecFreeContext)(void** s);
typedef int   (*FnAvcodecOpen2)(void* avctx, const void* codec, void** options);
typedef void* (*FnAvPacketAlloc)();
typedef void  (*FnAvPacketFree)(void** pkt);
typedef void  (*FnAvPacketUnref)(void* pkt);
typedef void* (*FnAvFrameAlloc)();
typedef void  (*FnAvFrameFree)(void** frame);
typedef void  (*FnAvFrameUnref)(void* frame);
typedef int   (*FnAvcodecSendPacket)(void* avctx, const void* pkt);
typedef int   (*FnAvcodecReceiveFrame)(void* avctx, void* frame);
typedef int   (*FnAvHwdeviceCtxCreate)(void** device_ctx, int type, const char* device, void* opts, int flags);
typedef int   (*FnAvOptSetInt)(void* obj, const char* name, int64_t val, int search_flags);
typedef int   (*FnAvOptSet)(void* obj, const char* name, const char* val, int search_flags);
typedef void* (*FnAvBufferRef)(const void* buf);
typedef void  (*FnAvBufferUnref)(void** buf);
typedef void* (*FnAvParserInit)(int codec_id);
typedef int   (*FnAvParserParse2)(void* s, void* avctx,
                                  uint8_t** poutbuf, int* poutbuf_size,
                                  const uint8_t* buf, int buf_size,
                                  int64_t pts, int64_t dts, int64_t pos);
typedef void  (*FnAvParserClose)(void* s);

typedef void* (*FnSwsGetContext)(int srcW, int srcH, int srcFormat,
                                 int dstW, int dstH, int dstFormat,
                                 int flags, void* srcFilter, void* dstFilter, const double* param);
typedef int   (*FnSwsScale)(void* c, const uint8_t* const srcSlice[],
                            const int srcStride[], int srcSliceY, int srcSliceH,
                            uint8_t* const dst[], const int dstStride[]);
typedef void  (*FnSwsFreeContext)(void* swsContext);

struct FfmpegFunctions {
  // avcodec
  FnAvcodecFindDecoder find_decoder = nullptr;
  FnAvcodecAllocContext3 alloc_context3 = nullptr;
  FnAvcodecFreeContext free_context = nullptr;
  FnAvcodecOpen2 open2 = nullptr;
  FnAvPacketAlloc packet_alloc = nullptr;
  FnAvPacketFree packet_free = nullptr;
  FnAvPacketUnref packet_unref = nullptr;
  FnAvcodecSendPacket send_packet = nullptr;
  FnAvcodecReceiveFrame receive_frame = nullptr;
  FnAvParserInit parser_init = nullptr;
  FnAvParserParse2 parser_parse2 = nullptr;
  FnAvParserClose parser_close = nullptr;

  // avutil
  FnAvFrameAlloc frame_alloc = nullptr;
  FnAvFrameFree frame_free = nullptr;
  FnAvFrameUnref frame_unref = nullptr;
  FnAvHwdeviceCtxCreate hwdevice_ctx_create = nullptr;
  FnAvOptSetInt opt_set_int = nullptr;
  FnAvOptSet opt_set = nullptr;
  FnAvBufferRef buffer_ref = nullptr;
  FnAvBufferUnref buffer_unref = nullptr;

  // swscale
  FnSwsGetContext sws_getContext = nullptr;
  FnSwsScale sws_scale = nullptr;
  FnSwsFreeContext sws_freeContext = nullptr;
} g_ffmpeg;

}  // namespace

VideoDecoder::VideoDecoder(TextureBridge* texture_bridge)
    : texture_bridge_(texture_bridge) {}

VideoDecoder::~VideoDecoder() {
  Teardown();
}

bool VideoDecoder::InitializeD3D11(size_t initial_width, size_t initial_height) {
  std::lock_guard<std::mutex> lock(decode_mutex_);

  width_ = initial_width;
  height_ = initial_height;

  // Direct3D 11 Device Creation Flags: Enable BGRA and Video Acceleration
  UINT create_device_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;

  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
  };
  D3D_FEATURE_LEVEL feature_level;

  HRESULT hr = D3D11CreateDevice(
      nullptr,
      D3D_DRIVER_TYPE_HARDWARE,
      nullptr,
      create_device_flags,
      feature_levels,
      ARRAYSIZE(feature_levels),
      D3D11_SDK_VERSION,
      &d3d11_device_,
      &feature_level,
      &d3d11_context_);

  if (FAILED(hr)) {
    // Fallback to WARP software rasterizer if hardware adapter lacks required flags
    hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_WARP,
        nullptr,
        create_device_flags,
        feature_levels,
        ARRAYSIZE(feature_levels),
        D3D11_SDK_VERSION,
        &d3d11_device_,
        &feature_level,
        &d3d11_context_);
    if (FAILED(hr)) {
      return false;
    }
  }

  // Create zero-copy shared texture surface
  if (!CreateSharedTexture(width_, height_)) {
    return false;
  }

  // Attempt FFmpeg dynamic symbols loading
  InitializeCodec();

  // Render initial active frame so canvas is never black
  RenderTestPatternFrame(0);

  is_initialized_ = true;
  return true;
}

bool VideoDecoder::CreateSharedTexture(size_t width, size_t height) {
  if (!d3d11_device_) return false;

  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = static_cast<UINT>(width);
  desc.Height = static_cast<UINT>(height);
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  // D3D11_RESOURCE_MISC_SHARED: Enables zero-copy cross-device handle sharing with Flutter
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  HRESULT hr = d3d11_device_->CreateTexture2D(&desc, nullptr, &shared_texture_);
  if (FAILED(hr)) {
    return false;
  }

  // Obtain DXGI Shared Handle
  hr = shared_texture_.As(&dxgi_resource_);
  if (FAILED(hr)) {
    return false;
  }

  hr = dxgi_resource_->GetSharedHandle(&shared_handle_);
  if (FAILED(hr) || !shared_handle_) {
    return false;
  }

  // Bind to TextureBridge
  if (texture_bridge_) {
    texture_bridge_->PushD3D11Texture(shared_texture_.Get(), shared_handle_, width, height);
  }

  return true;
}

bool VideoDecoder::LoadFfmpegSymbols() {
  char exe_path[MAX_PATH] = {0};
  if (GetModuleFileNameA(nullptr, exe_path, MAX_PATH) > 0) {
    char* last_slash = strrchr(exe_path, '\\');
    if (last_slash) {
      *last_slash = '\0';
      SetDllDirectoryA(exe_path);
      Log("FFMPEG", std::string("Application directory set for DLL search: ") + exe_path, "info");
    }
  }

  // 0. Preload MinGW runtime and support libraries to guarantee dependencies resolve seamlessly
  const char* kPreloadLibs[] = {
      "libwinpthread-1.dll",
      "libgcc_s_seh-1.dll",
      "libstdc++-6.dll",
      "swresample-5.dll"
  };
  for (const char* lib_name : kPreloadLibs) {
    HMODULE mod = LoadLibraryA(lib_name);
    if (mod) {
      Log("FFMPEG", std::string("Preloaded dependency: ") + lib_name, "info");
    }
  }

  // 1. Load avutil (core dependency for avcodec and swscale)
  const char* kAvutilNames[] = {
      "avutil-59.dll", "avutil-60.dll", "avutil-58.dll", "avutil-57.dll",
      "avutil-56.dll", "avutil.dll"
  };
  for (const char* dll_name : kAvutilNames) {
    avutil_module_ = LoadLibraryA(dll_name);
    if (avutil_module_) {
      Log("FFMPEG", std::string("Loaded core library: ") + dll_name, "success");
      break;
    }
  }

  if (!avutil_module_) {
    Log("FFMPEG", "avutil dynamic library not found in application path!", "error");
    return false;
  }

  g_ffmpeg.frame_alloc = (FnAvFrameAlloc)GetProcAddress(avutil_module_, "av_frame_alloc");
  g_ffmpeg.frame_free = (FnAvFrameFree)GetProcAddress(avutil_module_, "av_frame_free");
  g_ffmpeg.frame_unref = (FnAvFrameUnref)GetProcAddress(avutil_module_, "av_frame_unref");
  g_ffmpeg.hwdevice_ctx_create = (FnAvHwdeviceCtxCreate)GetProcAddress(avutil_module_, "av_hwdevice_ctx_create");
  g_ffmpeg.opt_set_int = (FnAvOptSetInt)GetProcAddress(avutil_module_, "av_opt_set_int");
  g_ffmpeg.opt_set = (FnAvOptSet)GetProcAddress(avutil_module_, "av_opt_set");
  g_ffmpeg.buffer_ref = (FnAvBufferRef)GetProcAddress(avutil_module_, "av_buffer_ref");
  g_ffmpeg.buffer_unref = (FnAvBufferUnref)GetProcAddress(avutil_module_, "av_buffer_unref");

  // 2. Load avcodec
  const char* kAvcodecNames[] = {
      "avcodec-61.dll", "avcodec-62.dll", "avcodec-60.dll",
      "avcodec-59.dll", "avcodec-58.dll", "avcodec.dll"
  };
  for (const char* dll_name : kAvcodecNames) {
    avcodec_module_ = LoadLibraryA(dll_name);
    if (avcodec_module_) {
      Log("FFMPEG", std::string("Loaded codec library: ") + dll_name, "success");
      break;
    }
  }

  if (!avcodec_module_) {
    Log("FFMPEG", "avcodec dynamic library not found in application path!", "error");
    return false;
  }

  g_ffmpeg.find_decoder = (FnAvcodecFindDecoder)GetProcAddress(avcodec_module_, "avcodec_find_decoder");
  g_ffmpeg.alloc_context3 = (FnAvcodecAllocContext3)GetProcAddress(avcodec_module_, "avcodec_alloc_context3");
  g_ffmpeg.free_context = (FnAvcodecFreeContext)GetProcAddress(avcodec_module_, "avcodec_free_context");
  g_ffmpeg.open2 = (FnAvcodecOpen2)GetProcAddress(avcodec_module_, "avcodec_open2");
  g_ffmpeg.packet_alloc = (FnAvPacketAlloc)GetProcAddress(avcodec_module_, "av_packet_alloc");
  g_ffmpeg.packet_free = (FnAvPacketFree)GetProcAddress(avcodec_module_, "av_packet_free");
  g_ffmpeg.packet_unref = (FnAvPacketUnref)GetProcAddress(avcodec_module_, "av_packet_unref");
  g_ffmpeg.parser_init = (FnAvParserInit)GetProcAddress(avcodec_module_, "av_parser_init");
  g_ffmpeg.parser_parse2 = (FnAvParserParse2)GetProcAddress(avcodec_module_, "av_parser_parse2");
  g_ffmpeg.parser_close = (FnAvParserClose)GetProcAddress(avcodec_module_, "av_parser_close");
  g_ffmpeg.send_packet = (FnAvcodecSendPacket)GetProcAddress(avcodec_module_, "avcodec_send_packet");
  g_ffmpeg.receive_frame = (FnAvcodecReceiveFrame)GetProcAddress(avcodec_module_, "avcodec_receive_frame");

  // 3. Load swscale (for zero-latency SIMD color conversion)
  const char* kSwscaleNames[] = {
      "swscale-8.dll", "swscale-9.dll", "swscale-7.dll", "swscale-6.dll", "swscale.dll"
  };
  for (const char* dll_name : kSwscaleNames) {
    swscale_module_ = LoadLibraryA(dll_name);
    if (swscale_module_) {
      Log("FFMPEG", std::string("Loaded swscale library: ") + dll_name, "success");
      break;
    }
  }

  if (swscale_module_) {
    g_ffmpeg.sws_getContext = (FnSwsGetContext)GetProcAddress(swscale_module_, "sws_getContext");
    g_ffmpeg.sws_scale = (FnSwsScale)GetProcAddress(swscale_module_, "sws_scale");
    g_ffmpeg.sws_freeContext = (FnSwsFreeContext)GetProcAddress(swscale_module_, "sws_freeContext");
  }

  const bool ok = (g_ffmpeg.find_decoder && g_ffmpeg.alloc_context3 &&
                   g_ffmpeg.send_packet && g_ffmpeg.receive_frame &&
                   g_ffmpeg.frame_alloc && g_ffmpeg.packet_alloc);
  if (!ok) {
    Log("FFMPEG", "Required FFmpeg functions missing from loaded DLLs!", "error");
  } else {
    Log("FFMPEG", "All required FFmpeg functions resolved successfully.", "success");
  }
  return ok;
}

bool VideoDecoder::InitializeCodec() {
  if (!LoadFfmpegSymbols()) {
    is_hw_accelerated_ = false;
    Log("DECODER", "InitializeCodec failed: FFmpeg symbols not loaded", "error");
    return false;
  }

  av_codec_ = g_ffmpeg.find_decoder(kAvCodecIdH264);
  if (!av_codec_) {
    Log("DECODER", "H.264 decoder (id=27) not found in avcodec!", "error");
    return false;
  }

  av_codec_ctx_ = g_ffmpeg.alloc_context3(av_codec_);
  if (!av_codec_ctx_) {
    Log("DECODER", "avcodec_alloc_context3 failed", "error");
    return false;
  }

  // 1. Configure ultra-low-latency and multi-threaded CPU decoding
  // threads = 0: automatically detects CPU cores
  // thread_type = 2: FF_THREAD_SLICE (0 frame delay, parallel macroblock decoding, eliminates lag completely)
  // Note: Avoid FF_THREAD_FRAME (1) because it delays output by buffering multiple frames internally.
  if (g_ffmpeg.opt_set_int) {
    g_ffmpeg.opt_set_int(av_codec_ctx_, "threads", 0, 0);
    g_ffmpeg.opt_set_int(av_codec_ctx_, "thread_type", 2 /* FF_THREAD_SLICE */, 0);
    g_ffmpeg.opt_set_int(av_codec_ctx_, "flags", kAvCodecFlagLowDelay, 0);
    g_ffmpeg.opt_set_int(av_codec_ctx_, "flags2", 1 /* FAST */, 0);
  }

  // 2. Hardware Acceleration Initialization (D3D11VA GPU with seamless CPU fallback)
  if (g_ffmpeg.hwdevice_ctx_create) {
    const int ret = g_ffmpeg.hwdevice_ctx_create(&av_hw_device_ctx_, kAvHwDeviceTypeD3d11va, nullptr, nullptr, 0);
    if (ret >= 0) {
      is_hw_accelerated_ = true;
      Log("DECODER", "D3D11VA GPU hardware acceleration enabled.", "info");
    } else {
      is_hw_accelerated_ = false;
      Log("DECODER", "D3D11VA not active, using ultra-fast multi-core CPU decoding.", "info");
    }
  }

  const int open_res = g_ffmpeg.open2(av_codec_ctx_, av_codec_, nullptr);
  if (open_res < 0) {
    Log("DECODER", "avcodec_open2 failed with code: " + std::to_string(open_res), "error");
    return false;
  }

  if (g_ffmpeg.parser_init) {
    av_parser_ctx_ = g_ffmpeg.parser_init(kAvCodecIdH264);
  }

  av_packet_ = g_ffmpeg.packet_alloc();
  av_frame_ = g_ffmpeg.frame_alloc();
  av_frame_secondary_ = g_ffmpeg.frame_alloc();

  is_initialized_ = true;
  Log("DECODER", "Real-time H.264 CPU/GPU decoder successfully initialized!", "success");
  return true;
}

bool VideoDecoder::DecodeStream(const uint8_t* in_data, size_t in_size) {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  if (!in_data || in_size == 0) return false;

  if (!is_initialized_ || !av_codec_ctx_ || !av_packet_ || !av_frame_ || !av_parser_ctx_) {
    InitializeCodec();
  }

  if (!av_codec_ctx_ || !av_packet_ || !av_frame_ || !av_parser_ctx_) {
    return false;
  }

  // Hex dump of first incoming packet to verify bitstream integrity
  static bool s_first_packet_logged = false;
  if (!s_first_packet_logged && in_size >= 4) {
    s_first_packet_logged = true;
    std::stringstream hex_ss;
    const size_t dump_len = std::min<size_t>(in_size, 32);
    for (size_t i = 0; i < dump_len; ++i) {
      hex_ss << std::hex << std::uppercase << std::setw(2) << std::setfill('0') << static_cast<int>(in_data[i]) << " ";
    }
    Log("STREAM", "First video stream chunk (" + std::to_string(in_size) + " bytes): " + hex_ss.str(), "info");
  }

  while (in_size > 0) {
    uint8_t* parsed_buf = nullptr;
    int parsed_size = 0;
    const int consumed = g_ffmpeg.parser_parse2(
        av_parser_ctx_, av_codec_ctx_,
        &parsed_buf, &parsed_size,
        in_data, static_cast<int>(in_size),
        kAvNoPtsValue, kAvNoPtsValue, 0);

    if (consumed > 0) {
      in_data += consumed;
      in_size -= consumed;
    }

    if (parsed_size > 0 && parsed_buf) {
      static int s_logged_nals = 0;
      if (s_logged_nals < 10 && parsed_size >= 5) {
        s_logged_nals++;
        uint8_t nal_type = parsed_buf[4] & 0x1F;
        if (parsed_buf[0] == 0 && parsed_buf[1] == 0 && parsed_buf[2] == 1) {
          nal_type = parsed_buf[3] & 0x1F;
        }
        Log("DECODER", "Parsed NAL #" + std::to_string(s_logged_nals) + " size=" + std::to_string(parsed_size) + " type=" + std::to_string(nal_type), "info");
      }

      g_ffmpeg.packet_unref(av_packet_);
      auto* pkt = reinterpret_cast<FF_AVPacket*>(av_packet_);
      pkt->data = parsed_buf;
      pkt->size = parsed_size;
      pkt->pts = kAvNoPtsValue;
      pkt->dts = kAvNoPtsValue;

      int send_res = g_ffmpeg.send_packet(av_codec_ctx_, av_packet_);
      if (send_res == -11 /* EAGAIN */) {
        // Drain frames if decoder queue is full, then retry sending packet
        DrainAndRenderLatestFrame();
        send_res = g_ffmpeg.send_packet(av_codec_ctx_, av_packet_);
      }

      if (send_res >= 0) {
        DrainAndRenderLatestFrame();
      } else {
        static int s_send_err_count = 0;
        if (s_send_err_count++ < 5) {
          Log("DECODER", "avcodec_send_packet code: " + std::to_string(send_res), "warning");
        }
      }

      pkt->data = nullptr;
      pkt->size = 0;
    }

    if (consumed <= 0 && parsed_size <= 0) {
      break;
    }
  }

  return true;
}

bool VideoDecoder::DecodePacket(const DemuxedVideoPacket& packet) {
  if (packet.data.empty()) return false;
  return DecodeStream(packet.data.data(), packet.data.size());
}

void VideoDecoder::DrainAndRenderLatestFrame() {
  if (!av_codec_ctx_ || !av_frame_) return;

  void* active_frame = av_frame_;
  void* next_frame = av_frame_secondary_ ? av_frame_secondary_ : av_frame_;
  void* latest_valid_frame = nullptr;

  while (g_ffmpeg.receive_frame(av_codec_ctx_, active_frame) >= 0) {
    if (latest_valid_frame && g_ffmpeg.frame_unref) {
      g_ffmpeg.frame_unref(latest_valid_frame);
    }
    latest_valid_frame = active_frame;
    if (av_frame_secondary_) {
      std::swap(active_frame, next_frame);
    }
  }

  if (latest_valid_frame) {
    RenderDecodedFrame(latest_valid_frame);
    if (g_ffmpeg.frame_unref) {
      g_ffmpeg.frame_unref(latest_valid_frame);
    }
  }
}

void VideoDecoder::RenderDecodedFrame(void* av_frame) {
  if (!av_frame) return;

  auto* frame = reinterpret_cast<FF_AVFrame*>(av_frame);
  const int frame_w = frame->width;
  const int frame_h = frame->height;
  const int frame_fmt = frame->format;

  if (!frame->data[0] || frame_w <= 0 || frame_h <= 0) {
    return;
  }

  const size_t target_w = static_cast<size_t>(frame_w);
  const size_t target_h = static_cast<size_t>(frame_h);

  static uint64_t s_rendered_count = 0;
  s_rendered_count++;
  if (s_rendered_count == 1 || s_rendered_count % 60 == 0) {
    Log("RENDERER", "Decoded frame #" + std::to_string(s_rendered_count) + " (" +
        std::to_string(frame_w) + "x" + std::to_string(frame_h) + ", fmt=" +
        std::to_string(frame_fmt) + ") displayed!", "success");
  }

  // Resize buffers if resolution changed (e.g. portrait <-> landscape rotation)
  if (target_w != width_ || target_h != height_) {
    width_ = target_w;
    height_ = target_h;
    if (d3d11_device_) {
      CreateSharedTexture(width_, height_);
    }
    if (sws_ctx_ && g_ffmpeg.sws_freeContext) {
      g_ffmpeg.sws_freeContext(sws_ctx_);
      sws_ctx_ = nullptr;
    }
  }

  // Pre-allocate / resize RGBA buffer once (zero reallocation on steady-state frames)
  const size_t required_bytes = width_ * height_ * 4;
  if (rgba_buffer_.size() != required_bytes) {
    rgba_buffer_.resize(required_bytes);
  }

  // 1. Convert to RGBA using SIMD swscale if available
  bool converted = false;
  if (g_ffmpeg.sws_scale && g_ffmpeg.sws_getContext) {
    if (!sws_ctx_ || current_pix_fmt_ != frame_fmt) {
      if (sws_ctx_ && g_ffmpeg.sws_freeContext) {
        g_ffmpeg.sws_freeContext(sws_ctx_);
      }
      current_pix_fmt_ = frame_fmt;
      sws_ctx_ = g_ffmpeg.sws_getContext(
          static_cast<int>(width_), static_cast<int>(height_), frame_fmt,
          static_cast<int>(width_), static_cast<int>(height_), kAvPixFmtRgba,
          kSwsFastBilinear, nullptr, nullptr, nullptr);
    }

    if (sws_ctx_) {
      uint8_t* dst_planes[4] = { rgba_buffer_.data(), nullptr, nullptr, nullptr };
      const int dst_strides[4] = { static_cast<int>(width_ * 4), 0, 0, 0 };
      g_ffmpeg.sws_scale(sws_ctx_, frame->data, frame->linesize, 0, static_cast<int>(height_), dst_planes, dst_strides);
      converted = true;
    }
  }

  // 2. High-performance multi-format CPU fallback for NV12 & YUV420P
  if (!converted) {
    const uint8_t* y_plane = frame->data[0];
    const int y_stride = frame->linesize[0];

    if (frame_fmt == 23 /* AV_PIX_FMT_NV12 */) {
      const uint8_t* uv_plane = frame->data[1];
      const int uv_stride = frame->linesize[1];
      if (y_plane && uv_plane) {
        uint32_t* dst = reinterpret_cast<uint32_t*>(rgba_buffer_.data());
        for (size_t y = 0; y < height_; ++y) {
          const uint8_t* y_row = y_plane + y * y_stride;
          const uint8_t* uv_row = uv_plane + (y / 2) * uv_stride;
          uint32_t* dst_row = dst + y * width_;
          for (size_t x = 0; x < width_; ++x) {
            const int c = static_cast<int>(y_row[x]) - 16;
            const int d = static_cast<int>(uv_row[(x & ~1)]) - 128;
            const int e = static_cast<int>(uv_row[(x & ~1) + 1]) - 128;
            int r = (298 * c + 409 * e + 128) >> 8;
            int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
            int b = (298 * c + 516 * d + 128) >> 8;
            r = (r < 0) ? 0 : ((r > 255) ? 255 : r);
            g = (g < 0) ? 0 : ((g > 255) ? 255 : g);
            b = (b < 0) ? 0 : ((b > 255) ? 255 : b);
            dst_row[x] = (0xFF << 24) | (b << 16) | (g << 8) | r;
          }
        }
      }
    } else {
      // YUV420P
      const uint8_t* u_plane = frame->data[1];
      const uint8_t* v_plane = frame->data[2];
      const int u_stride = frame->linesize[1];
      const int v_stride = frame->linesize[2];

      if (y_plane && u_plane && v_plane) {
        uint32_t* dst = reinterpret_cast<uint32_t*>(rgba_buffer_.data());
        for (size_t y = 0; y < height_; ++y) {
          const uint8_t* y_row = y_plane + y * y_stride;
          const uint8_t* u_row = u_plane + (y / 2) * u_stride;
          const uint8_t* v_row = v_plane + (y / 2) * v_stride;
          uint32_t* dst_row = dst + y * width_;

          for (size_t x = 0; x < width_; ++x) {
            const int c = static_cast<int>(y_row[x]) - 16;
            const int d = static_cast<int>(u_row[x / 2]) - 128;
            const int e = static_cast<int>(v_row[x / 2]) - 128;

            int r = (298 * c + 409 * e + 128) >> 8;
            int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
            int b = (298 * c + 516 * d + 128) >> 8;

            r = (r < 0) ? 0 : ((r > 255) ? 255 : r);
            g = (g < 0) ? 0 : ((g > 255) ? 255 : g);
            b = (b < 0) ? 0 : ((b > 255) ? 255 : b);

            dst_row[x] = (0xFF << 24) | (b << 16) | (g << 8) | r;
          }
        }
      }
    }
  }

  // Push directly to Flutter PixelBufferTexture (100% universal rock-solid display, zero GPU overhead)
  if (texture_bridge_) {
    texture_bridge_->PushPixelBuffer(rgba_buffer_.data(), width_, height_);
  }
}

void VideoDecoder::RenderTestPatternFrame(uint32_t frame_index) {
  const size_t required_bytes = width_ * height_ * 4;
  if (rgba_buffer_.size() != required_bytes) {
    rgba_buffer_.resize(required_bytes);
  }

  // Elegant dark background (#0D1117) matching the AppleCast dark theme
  const uint32_t bg_color = 0xFF0D1117;
  uint32_t* dst = reinterpret_cast<uint32_t*>(rgba_buffer_.data());
  std::fill(dst, dst + (width_ * height_), bg_color);

  if (texture_bridge_) {
    texture_bridge_->PushPixelBuffer(reinterpret_cast<const uint8_t*>(rgba_buffer_.data()), width_, height_);
  }
}

void VideoDecoder::Teardown() {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  is_initialized_ = false;

  if (av_parser_ctx_ && g_ffmpeg.parser_close) {
    g_ffmpeg.parser_close(av_parser_ctx_);
    av_parser_ctx_ = nullptr;
  }

  if (sws_ctx_ && g_ffmpeg.sws_freeContext) {
    g_ffmpeg.sws_freeContext(sws_ctx_);
    sws_ctx_ = nullptr;
  }

  if (g_ffmpeg.packet_free && av_packet_) {
    g_ffmpeg.packet_free(&av_packet_);
    av_packet_ = nullptr;
  }
  if (g_ffmpeg.frame_free && av_frame_) {
    g_ffmpeg.frame_free(&av_frame_);
    av_frame_ = nullptr;
  }
  if (g_ffmpeg.frame_free && av_frame_secondary_) {
    g_ffmpeg.frame_free(&av_frame_secondary_);
    av_frame_secondary_ = nullptr;
  }
  if (g_ffmpeg.free_context && av_codec_ctx_) {
    g_ffmpeg.free_context(&av_codec_ctx_);
    av_codec_ctx_ = nullptr;
  }

  if (swscale_module_) {
    FreeLibrary(swscale_module_);
    swscale_module_ = nullptr;
  }
  if (avcodec_module_) {
    FreeLibrary(avcodec_module_);
    avcodec_module_ = nullptr;
  }
  if (avutil_module_) {
    FreeLibrary(avutil_module_);
    avutil_module_ = nullptr;
  }

  shared_texture_.Reset();
  dxgi_resource_.Reset();
  d3d11_context_.Reset();
  d3d11_device_.Reset();
  shared_handle_ = nullptr;
  rgba_buffer_.clear();
}

}  // namespace applecast
