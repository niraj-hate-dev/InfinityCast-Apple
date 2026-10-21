#ifndef RUNNER_VIDEO_DECODER_H_
#define RUNNER_VIDEO_DECODER_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>

#include "texture_bridge.h"
#include "rtp_demuxer.h"

namespace applecast {

/// Architecture Blueprint: Module 3 - Hardware Video Decoder & Rendering Canvas
/// Initializes Direct3D 11 device, sets up low-latency libavcodec H.264 / D3D11VA pipeline,
/// and binds the decoded hardware surface to TextureBridge via flutter::GpuSurfaceTexture.
class VideoDecoder {
 public:
  explicit VideoDecoder(TextureBridge* texture_bridge);
  ~VideoDecoder();

  // Initializes Direct3D 11 device, context, and shared DXGI texture.
  bool InitializeD3D11(size_t initial_width = 1920, size_t initial_height = 1080);

  // Initializes FFmpeg libavcodec with low-delay flags and D3D11VA hardware acceleration.
  bool InitializeCodec();

  // Decodes raw Annex-B stream chunks directly from the TCP socket.
  bool DecodeStream(const uint8_t* in_data, size_t in_size);

  // Decodes an Annex B formatted NAL unit video packet received from RtpDemuxer.
  bool DecodePacket(const DemuxedVideoPacket& packet);

  // Generates/updates a hardware test pattern frame on the Direct3D 11 surface (for pipeline validation).
  void RenderTestPatternFrame(uint32_t frame_index);

  // Releases all Direct3D 11 and FFmpeg resources cleanly.
  void Teardown();

  size_t width() const { return width_; }
  size_t height() const { return height_; }
  bool is_hw_accelerated() const { return is_hw_accelerated_; }

 private:
  bool CreateSharedTexture(size_t width, size_t height);
  bool LoadFfmpegSymbols();
  void RenderDecodedFrame(void* av_frame);
  void DrainAndRenderLatestFrame();

  TextureBridge* texture_bridge_ = nullptr;
  size_t width_ = 1920;
  size_t height_ = 1080;
  int current_pix_fmt_ = -1;
  bool is_hw_accelerated_ = false;

  // Direct3D 11 Core Components
  Microsoft::WRL::ComPtr<ID3D11Device> d3d11_device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> d3d11_context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> shared_texture_;
  Microsoft::WRL::ComPtr<IDXGIResource> dxgi_resource_;
  HANDLE shared_handle_ = nullptr;

  // Dynamic FFmpeg Module Handles & Function Pointers
  HMODULE avcodec_module_ = nullptr;
  HMODULE avutil_module_ = nullptr;
  HMODULE swscale_module_ = nullptr;

  void* av_codec_ = nullptr;
  void* av_codec_ctx_ = nullptr;
  void* av_hw_device_ctx_ = nullptr;
  void* av_packet_ = nullptr;
  void* av_frame_ = nullptr;
  void* av_frame_secondary_ = nullptr;
  void* av_parser_ctx_ = nullptr;
  void* sws_ctx_ = nullptr;

  // Zero-allocation reusable RGBA frame buffer for Flutter texture upload
  std::vector<uint8_t> rgba_buffer_;

  std::mutex decode_mutex_;
  std::atomic<bool> is_initialized_{false};
};

}  // namespace applecast

#endif  // RUNNER_VIDEO_DECODER_H_
