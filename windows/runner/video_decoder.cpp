#include "video_decoder.h"

#include <iostream>
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

typedef void* (*FnAvcodecFindDecoder)(int id);
typedef void* (*FnAvcodecAllocContext3)(const void* codec);
typedef void  (*FnAvcodecFreeContext)(void** s);
typedef int   (*FnAvcodecOpen2)(void* avctx, const void* codec, void** options);
typedef void* (*FnAvPacketAlloc)();
typedef void  (*FnAvPacketFree)(void** pkt);
typedef void  (*FnAvPacketUnref)(void* pkt);
typedef void* (*FnAvFrameAlloc)();
typedef void  (*FnAvFrameFree)(void** frame);
typedef int   (*FnAvcodecSendPacket)(void* avctx, const void* pkt);
typedef int   (*FnAvcodecReceiveFrame)(void* avctx, void* frame);
typedef int   (*FnAvHwdeviceCtxCreate)(void** device_ctx, int type, const char* device, void* opts, int flags);
typedef int   (*FnAvOptSetInt)(void* obj, const char* name, int64_t val, int search_flags);
typedef int   (*FnAvNewPacket)(void* pkt, int size);
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
  FnAvNewPacket new_packet = nullptr;
  FnAvParserInit parser_init = nullptr;
  FnAvParserParse2 parser_parse2 = nullptr;
  FnAvParserClose parser_close = nullptr;

  // avutil
  FnAvFrameAlloc frame_alloc = nullptr;
  FnAvFrameFree frame_free = nullptr;
  FnAvHwdeviceCtxCreate hwdevice_ctx_create = nullptr;
  FnAvOptSetInt opt_set_int = nullptr;

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
    }
  }

  // 1. Load avutil first (core dependency for avcodec and swscale)
  const char* kAvutilNames[] = {
      "avutil-59.dll", "avutil-60.dll", "avutil-58.dll", "avutil-57.dll",
      "avutil-56.dll", "avutil.dll"
  };
  for (const char* dll_name : kAvutilNames) {
    avutil_module_ = LoadLibraryA(dll_name);
    if (avutil_module_) break;
  }

  if (!avutil_module_) {
    std::cerr << "[DECODER] avutil dynamic library not found" << std::endl;
    return false;
  }

  g_ffmpeg.frame_alloc = (FnAvFrameAlloc)GetProcAddress(avutil_module_, "av_frame_alloc");
  g_ffmpeg.frame_free = (FnAvFrameFree)GetProcAddress(avutil_module_, "av_frame_free");
  g_ffmpeg.hwdevice_ctx_create = (FnAvHwdeviceCtxCreate)GetProcAddress(avutil_module_, "av_hwdevice_ctx_create");
  g_ffmpeg.opt_set_int = (FnAvOptSetInt)GetProcAddress(avutil_module_, "av_opt_set_int");

  // 2. Load avcodec
  const char* kAvcodecNames[] = {
      "avcodec-61.dll", "avcodec-62.dll", "avcodec-60.dll",
      "avcodec-59.dll", "avcodec-58.dll", "avcodec.dll"
  };
  for (const char* dll_name : kAvcodecNames) {
    avcodec_module_ = LoadLibraryA(dll_name);
    if (avcodec_module_) break;
  }

  if (!avcodec_module_) {
    std::cerr << "[DECODER] avcodec dynamic library not found" << std::endl;
    return false;
  }

  g_ffmpeg.find_decoder = (FnAvcodecFindDecoder)GetProcAddress(avcodec_module_, "avcodec_find_decoder");
  g_ffmpeg.alloc_context3 = (FnAvcodecAllocContext3)GetProcAddress(avcodec_module_, "avcodec_alloc_context3");
  g_ffmpeg.free_context = (FnAvcodecFreeContext)GetProcAddress(avcodec_module_, "avcodec_free_context");
  g_ffmpeg.open2 = (FnAvcodecOpen2)GetProcAddress(avcodec_module_, "avcodec_open2");
  g_ffmpeg.packet_alloc = (FnAvPacketAlloc)GetProcAddress(avcodec_module_, "av_packet_alloc");
  g_ffmpeg.packet_free = (FnAvPacketFree)GetProcAddress(avcodec_module_, "av_packet_free");
  g_ffmpeg.packet_unref = (FnAvPacketUnref)GetProcAddress(avcodec_module_, "av_packet_unref");
  g_ffmpeg.new_packet = (FnAvNewPacket)GetProcAddress(avcodec_module_, "av_new_packet");
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
    if (swscale_module_) break;
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
    std::cerr << "[DECODER] Required FFmpeg functions missing from loaded DLLs" << std::endl;
  }
  return ok;
}

bool VideoDecoder::InitializeCodec() {
  if (!LoadFfmpegSymbols()) {
    is_hw_accelerated_ = false;
    return false;
  }

  av_codec_ = g_ffmpeg.find_decoder(kAvCodecIdH264);
  if (!av_codec_) {
    std::cerr << "[DECODER] H.264 decoder not found" << std::endl;
    return false;
  }

  av_codec_ctx_ = g_ffmpeg.alloc_context3(av_codec_);
  if (!av_codec_ctx_) {
    std::cerr << "[DECODER] avcodec_alloc_context3 failed" << std::endl;
    return false;
  }

  // Set low-delay flags and single-thread decode via standard av_opt_set_int
  if (g_ffmpeg.opt_set_int) {
    g_ffmpeg.opt_set_int(av_codec_ctx_, "flags", kAvCodecFlagLowDelay, 0);
    g_ffmpeg.opt_set_int(av_codec_ctx_, "threads", 1, 0);
  }

  // Configure D3D11VA Hardware Acceleration Device Context if available
  if (g_ffmpeg.hwdevice_ctx_create) {
    const int ret = g_ffmpeg.hwdevice_ctx_create(&av_hw_device_ctx_, kAvHwDeviceTypeD3d11va, nullptr, nullptr, 0);
    if (ret >= 0) {
      is_hw_accelerated_ = true;
    }
  }

  if (g_ffmpeg.open2(av_codec_ctx_, av_codec_, nullptr) < 0) {
    std::cerr << "[DECODER] avcodec_open2 failed" << std::endl;
    return false;
  }

  if (g_ffmpeg.parser_init) {
    av_parser_ctx_ = g_ffmpeg.parser_init(kAvCodecIdH264);
  }

  av_packet_ = g_ffmpeg.packet_alloc();
  av_frame_ = g_ffmpeg.frame_alloc();

  is_initialized_ = true;
  std::cout << "[DECODER] Real-time H.264 CPU/GPU decoder successfully ready!" << std::endl;
  return true;
}

bool VideoDecoder::DecodeStream(const uint8_t* in_data, size_t in_size) {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  if (!in_data || in_size == 0) return false;

  if (!is_initialized_) {
    InitializeCodec();
  }

  if (!av_codec_ctx_ || !av_packet_ || !av_frame_ || !av_parser_ctx_) {
    return false;
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
      g_ffmpeg.packet_unref(av_packet_);
      if (g_ffmpeg.new_packet(av_packet_, parsed_size) == 0) {
        uint8_t** pkt_data = reinterpret_cast<uint8_t**>(reinterpret_cast<uint8_t*>(av_packet_) + 24);
        if (pkt_data && *pkt_data) {
          std::memcpy(*pkt_data, parsed_buf, parsed_size);
        }

        const int send_res = g_ffmpeg.send_packet(av_codec_ctx_, av_packet_);
        if (send_res >= 0 || send_res == -11 /* EAGAIN */) {
          while (g_ffmpeg.receive_frame(av_codec_ctx_, av_frame_) >= 0) {
            RenderDecodedFrame(av_frame_);
          }
        }
      }
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

void VideoDecoder::RenderDecodedFrame(void* av_frame) {
  if (!av_frame) return;

  uint8_t** src_data = reinterpret_cast<uint8_t**>(reinterpret_cast<uint8_t*>(av_frame) + 0);
  int* src_linesize = reinterpret_cast<int*>(reinterpret_cast<uint8_t*>(av_frame) + 64);

  const int frame_w = *(reinterpret_cast<int*>(reinterpret_cast<uint8_t*>(av_frame) + 104));
  const int frame_h = *(reinterpret_cast<int*>(reinterpret_cast<uint8_t*>(av_frame) + 108));
  const int frame_fmt = *(reinterpret_cast<int*>(reinterpret_cast<uint8_t*>(av_frame) + 116));

  if (!src_data[0] || frame_w <= 0 || frame_h <= 0) {
    return;
  }

  const size_t target_w = static_cast<size_t>(frame_w);
  const size_t target_h = static_cast<size_t>(frame_h);

  static uint64_t s_rendered_count = 0;
  s_rendered_count++;
  if (s_rendered_count == 1 || s_rendered_count % 180 == 0) {
    std::cout << "[DECODER] Successfully rendered active screen frame #" << s_rendered_count
              << " (" << frame_w << "x" << frame_h << ")" << std::endl;
  }

  // Resize buffers if resolution changed
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

  // Convert to RGBA using SIMD swscale if available
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
      g_ffmpeg.sws_scale(sws_ctx_, src_data, src_linesize, 0, static_cast<int>(height_), dst_planes, dst_strides);
    }
  } else {
    // High-performance CPU fallback for YUV420P -> RGBA
    const uint8_t* y_plane = src_data[0];
    const uint8_t* u_plane = src_data[1];
    const uint8_t* v_plane = src_data[2];
    const int y_stride = src_linesize[0];
    const int u_stride = src_linesize[1];
    const int v_stride = src_linesize[2];

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
