#ifndef RUNNER_TEXTURE_BRIDGE_H_
#define RUNNER_TEXTURE_BRIDGE_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <flutter/texture_registrar.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <mutex>
#include <memory>
#include <vector>
#include <functional>

namespace applecast {

/// Architecture Blueprint: Module 3 - Hardware Video Decoder & Rendering Canvas
/// Bridges Direct3D 11 / FFmpeg decoded video frames to Flutter's Texture widget.
/// Implements:
/// 1. Zero-Copy GPU Texture (flutter::GpuSurfaceTexture via DXGI Shared Handle)
/// 2. Low-latency Pixel Buffer Texture (flutter::PixelBufferTexture fallback)
class TextureBridge {
 public:
  explicit TextureBridge(flutter::TextureRegistrar* texture_registrar);
  ~TextureBridge();

  // Registers the hardware texture with Flutter's TextureRegistrar and returns texture_id.
  int64_t Register();

  // Unregisters the active texture.
  void Unregister();

  int64_t texture_id() const { return texture_id_; }

  // Called by FFmpeg/D3D11VA hardware video pipeline when a new decoded frame is ready.
  // Direct3D 11 Zero-Copy Path:
  void PushD3D11Texture(ID3D11Texture2D* texture, HANDLE shared_handle, size_t width, size_t height);

  // PixelBuffer CPU Fallback Path:
  void PushPixelBuffer(const uint8_t* buffer, size_t width, size_t height);

 private:
  // Callbacks executed by Flutter engine during compositor rasterization:
  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(size_t width, size_t height);
  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t width, size_t height);

  flutter::TextureRegistrar* texture_registrar_ = nullptr;
  int64_t texture_id_ = -1;

  std::mutex surface_mutex_;
  size_t current_width_ = 1920;
  size_t current_height_ = 1080;

  // GPU Surface Descriptor for Zero-Copy Direct3D 11 / DXGI Shared Handle
  FlutterDesktopGpuSurfaceDescriptor gpu_surface_descriptor_{};
  HANDLE d3d11_shared_handle_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> d3d11_texture_;

  // CPU fallback buffer
  std::vector<uint8_t> pixel_buffer_;
  FlutterDesktopPixelBuffer flutter_pixel_buffer_{};

  // Retain variant pointer while registered
  std::unique_ptr<flutter::TextureVariant> active_texture_variant_;
};

}  // namespace applecast

#endif  // RUNNER_TEXTURE_BRIDGE_H_
