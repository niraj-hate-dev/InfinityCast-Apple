#ifndef RUNNER_AUDIO_DECODER_H_
#define RUNNER_AUDIO_DECODER_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <mmsystem.h>
#include <cstdint>
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>

namespace applecast {

/// Architecture Blueprint: Module 4 - Hardware/Software Audio Decoder & Playback Engine
/// Decodes low-latency AAC audio frames (ADTS-wrapped) streamed from iOS ReplayKit extension
/// and outputs high-fidelity 16-bit stereo PCM audio via Windows Multimedia (WaveOut).
class AudioDecoder {
 public:
  AudioDecoder();
  ~AudioDecoder();

  // Initializes FFmpeg AAC decoder context and dynamic bindings
  bool Initialize();

  // Decodes incoming ADTS AAC byte chunks from socket stream
  bool DecodeStream(const uint8_t* in_data, size_t in_size);

  // Flushes internal FFmpeg codec buffers on pause/reconnect without tearing down WaveOut
  void Flush();

  // Releases all decoder and WaveOut resources
  void Teardown();

  bool is_initialized() const { return is_initialized_; }
  uint32_t sample_rate() const { return current_sample_rate_; }
  uint32_t channels() const { return current_channels_; }

 private:
  bool LoadFfmpegSymbols();
  bool InitWaveOut(uint32_t sample_rate, uint32_t channels);
  void CloseWaveOut();
  void PlayPcm(const int16_t* pcm_data, size_t num_samples);
  static void CALLBACK WaveOutProc(HWAVEOUT hwo, UINT uMsg, DWORD_PTR dwInstance, DWORD_PTR dwParam1, DWORD_PTR dwParam2);

  // FFmpeg DLL handles
  HMODULE avcodec_module_ = nullptr;
  HMODULE avutil_module_ = nullptr;

  // FFmpeg decoder state
  void* codec_ = nullptr;
  void* codec_ctx_ = nullptr;
  void* parser_ = nullptr;
  void* packet_ = nullptr;
  void* frame_ = nullptr;

  std::mutex decode_mutex_;
  std::atomic<bool> is_initialized_{false};

  // WaveOut audio playback state
  HWAVEOUT h_wave_out_ = nullptr;
  uint32_t current_sample_rate_ = 0;
  uint32_t current_channels_ = 0;

  static constexpr size_t kNumWaveBuffers = 8;
  WAVEHDR wave_headers_[kNumWaveBuffers]{};
  std::vector<uint8_t> wave_buffer_data_[kNumWaveBuffers];
  size_t current_wave_buffer_idx_ = 0;
  std::mutex wave_mutex_;
};

}  // namespace applecast

#endif  // RUNNER_AUDIO_DECODER_H_
