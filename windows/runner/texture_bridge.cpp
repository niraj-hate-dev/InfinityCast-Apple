#include "texture_bridge.h"

#include <iostream>

namespace applecast {

TextureBridge::TextureBridge(flutter::TextureRegistrar* texture_registrar)
    : texture_registrar_(texture_registrar) {
  gpu_surface_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  gpu_surface_descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
}

TextureBridge::~TextureBridge() {
  Unregister();
}

int64_t TextureBridge::Register() {
  if (texture_id_ >= 0) {
    return texture_id_;
  }

  if (!texture_registrar_) {
    return -1;
  }

  // Register zero-copy GPU Surface texture backed by DirectX 11 DXGI shared handle
  active_texture_variant_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [this](size_t width, size_t height) -> const FlutterDesktopGpuSurfaceDescriptor* {
            return this->ObtainDescriptor(width, height);
          }));

  texture_id_ = texture_registrar_->RegisterTexture(active_texture_variant_.get());

  // Fallback to PixelBufferTexture if GPU surface registration fails on older platforms
  if (texture_id_ < 0) {
    active_texture_variant_ = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture(
            [this](size_t width, size_t height) -> const FlutterDesktopPixelBuffer* {
              return this->CopyPixelBuffer(width, height);
            }));
    texture_id_ = texture_registrar_->RegisterTexture(active_texture_variant_.get());
  }

  return texture_id_;
}

void TextureBridge::Unregister() {
  if (texture_id_ >= 0 && texture_registrar_) {
    texture_registrar_->UnregisterTexture(texture_id_);
    texture_id_ = -1;
  }
  active_texture_variant_.reset();
}

void TextureBridge::PushD3D11Texture(ID3D11Texture2D* texture, HANDLE shared_handle, size_t width, size_t height) {
  {
    std::lock_guard<std::mutex> lock(surface_mutex_);
    d3d11_texture_ = texture;
    d3d11_shared_handle_ = shared_handle;
    current_width_ = width;
    current_height_ = height;
  }

  if (texture_id_ >= 0 && texture_registrar_) {
    texture_registrar_->MarkTextureFrameAvailable(texture_id_);
  }
}

void TextureBridge::PushPixelBuffer(const uint8_t* buffer, size_t width, size_t height) {
  {
    std::lock_guard<std::mutex> lock(surface_mutex_);
    current_width_ = width;
    current_height_ = height;
    const size_t total_bytes = width * height * 4;

    if (pixel_buffer_.size() != total_bytes) {
      pixel_buffer_.resize(total_bytes);
    }
    std::memcpy(pixel_buffer_.data(), buffer, total_bytes);
  }

  if (texture_id_ >= 0 && texture_registrar_) {
    texture_registrar_->MarkTextureFrameAvailable(texture_id_);
  }
}

const FlutterDesktopGpuSurfaceDescriptor* TextureBridge::ObtainDescriptor(size_t width, size_t height) {
  std::lock_guard<std::mutex> lock(surface_mutex_);

  if (!d3d11_shared_handle_) {
    return nullptr;
  }

  gpu_surface_descriptor_.handle = d3d11_shared_handle_;
  gpu_surface_descriptor_.width = current_width_;
  gpu_surface_descriptor_.height = current_height_;
  gpu_surface_descriptor_.visible_width = current_width_;
  gpu_surface_descriptor_.visible_height = current_height_;
  gpu_surface_descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
  gpu_surface_descriptor_.release_callback = nullptr;
  gpu_surface_descriptor_.release_context = nullptr;

  return &gpu_surface_descriptor_;
}

const FlutterDesktopPixelBuffer* TextureBridge::CopyPixelBuffer(size_t width, size_t height) {
  std::lock_guard<std::mutex> lock(surface_mutex_);

  if (pixel_buffer_.empty() || current_width_ == 0 || current_height_ == 0) {
    return nullptr;
  }

  flutter_pixel_buffer_.buffer = pixel_buffer_.data();
  flutter_pixel_buffer_.width = current_width_;
  flutter_pixel_buffer_.height = current_height_;

  return &flutter_pixel_buffer_;
}

}  // namespace applecast
