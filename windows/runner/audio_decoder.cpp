#include "audio_decoder.h"
#include "logger.h"

#include <iostream>
#include <algorithm>
#include <cstring>
#include <thread>
#include <chrono>

namespace applecast {

namespace {

constexpr int kAvCodecIdAac = 86018; // 0x15002
constexpr int64_t kAvNoPtsValue = static_cast<int64_t>(0x8000000000000000ULL);

struct FF_AVPacket {
  void* buf;                // offset 0
  int64_t pts;              // offset 8
  int64_t dts;              // offset 16
  uint8_t* data;            // offset 24
  int size;                 // offset 32
  int stream_index;         // offset 36
  int flags;                // offset 40
  void* side_data;          // offset 48
  int side_data_elems;      // offset 56
  int64_t duration;         // offset 64
  int64_t pos;              // offset 72
  void* opaque;             // offset 80
  void* opaque_ref;         // offset 88
  int time_base_num;        // offset 96
  int time_base_den;        // offset 100
};

struct FF_AVFrame {
  uint8_t* data[8];         // offset 0..63
  int linesize[8];          // offset 64..95
  uint8_t** extended_data;  // offset 96..103
  int width;                // offset 104
  int height;               // offset 108
  int nb_samples;           // offset 112
  int format;               // offset 116
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
typedef int   (*FnAvcodecSendPacket)(void* avctx, const void* pkt);
typedef int   (*FnAvcodecReceiveFrame)(void* avctx, void* frame);
typedef void  (*FnAvcodecFlushBuffers)(void* avctx);
typedef int   (*FnAvOptGetInt)(void* obj, const char* name, int search_flags, int64_t* out_val);

struct FfmpegAudioFunctions {
  FnAvcodecFindDecoder find_decoder = nullptr;
  FnAvcodecAllocContext3 alloc_context3 = nullptr;
  FnAvcodecFreeContext free_context = nullptr;
  FnAvcodecOpen2 open2 = nullptr;
  FnAvPacketAlloc packet_alloc = nullptr;
  FnAvPacketFree packet_free = nullptr;
  FnAvPacketUnref packet_unref = nullptr;
  FnAvcodecSendPacket send_packet = nullptr;
  FnAvcodecReceiveFrame receive_frame = nullptr;
  FnAvcodecFlushBuffers flush_buffers = nullptr;
  FnAvFrameAlloc frame_alloc = nullptr;
  FnAvFrameFree frame_free = nullptr;
  FnAvOptGetInt opt_get_int = nullptr;
} g_audio_ffmpeg;

// Thread-safe ADTS accumulator buffer across TCP reads
std::vector<uint8_t> g_adts_stream_buffer;

int GetSampleRateFromAdtsHeader(const uint8_t* hdr) {
  const uint8_t freq_idx = (hdr[2] >> 2) & 0x0F;
  switch (freq_idx) {
    case 0: return 96000;
    case 1: return 88200;
    case 2: return 64000;
    case 3: return 48000;
    case 4: return 44100;
    case 5: return 32000;
    case 6: return 24000;
    case 7: return 22050;
    case 8: return 16000;
    case 9: return 12000;
    case 10: return 11025;
    case 11: return 8000;
    default: return 44100;
  }
}

}  // namespace

AudioDecoder::AudioDecoder() = default;

AudioDecoder::~AudioDecoder() {
  Teardown();
}

bool AudioDecoder::LoadFfmpegSymbols() {
  if (g_audio_ffmpeg.find_decoder != nullptr) {
    return true;
  }

  const char* kAvutilNames[] = {
      "avutil-59.dll", "avutil-60.dll", "avutil-58.dll", "avutil-57.dll", "avutil.dll"
  };
  for (const char* dll_name : kAvutilNames) {
    avutil_module_ = LoadLibraryA(dll_name);
    if (avutil_module_) break;
  }

  if (!avutil_module_) {
    Log("AUDIO", "avutil library not found for audio decoding", "error");
    return false;
  }

  g_audio_ffmpeg.frame_alloc = (FnAvFrameAlloc)GetProcAddress(avutil_module_, "av_frame_alloc");
  g_audio_ffmpeg.frame_free = (FnAvFrameFree)GetProcAddress(avutil_module_, "av_frame_free");
  g_audio_ffmpeg.opt_get_int = (FnAvOptGetInt)GetProcAddress(avutil_module_, "av_opt_get_int");

  const char* kAvcodecNames[] = {
      "avcodec-61.dll", "avcodec-62.dll", "avcodec-60.dll", "avcodec-59.dll", "avcodec.dll"
  };
  for (const char* dll_name : kAvcodecNames) {
    avcodec_module_ = LoadLibraryA(dll_name);
    if (avcodec_module_) break;
  }

  if (!avcodec_module_) {
    Log("AUDIO", "avcodec library not found for audio decoding", "error");
    return false;
  }

  g_audio_ffmpeg.find_decoder = (FnAvcodecFindDecoder)GetProcAddress(avcodec_module_, "avcodec_find_decoder");
  g_audio_ffmpeg.alloc_context3 = (FnAvcodecAllocContext3)GetProcAddress(avcodec_module_, "avcodec_alloc_context3");
  g_audio_ffmpeg.free_context = (FnAvcodecFreeContext)GetProcAddress(avcodec_module_, "avcodec_free_context");
  g_audio_ffmpeg.open2 = (FnAvcodecOpen2)GetProcAddress(avcodec_module_, "avcodec_open2");
  g_audio_ffmpeg.packet_alloc = (FnAvPacketAlloc)GetProcAddress(avcodec_module_, "av_packet_alloc");
  g_audio_ffmpeg.packet_free = (FnAvPacketFree)GetProcAddress(avcodec_module_, "av_packet_free");
  g_audio_ffmpeg.packet_unref = (FnAvPacketUnref)GetProcAddress(avcodec_module_, "av_packet_unref");
  g_audio_ffmpeg.send_packet = (FnAvcodecSendPacket)GetProcAddress(avcodec_module_, "avcodec_send_packet");
  g_audio_ffmpeg.receive_frame = (FnAvcodecReceiveFrame)GetProcAddress(avcodec_module_, "avcodec_receive_frame");
  g_audio_ffmpeg.flush_buffers = (FnAvcodecFlushBuffers)GetProcAddress(avcodec_module_, "avcodec_flush_buffers");

  return g_audio_ffmpeg.find_decoder != nullptr && g_audio_ffmpeg.open2 != nullptr;
}

bool AudioDecoder::Initialize() {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  if (is_initialized_) return true;

  if (!LoadFfmpegSymbols()) {
    Log("AUDIO", "Failed to resolve FFmpeg symbols for AAC audio", "error");
    return false;
  }

  codec_ = g_audio_ffmpeg.find_decoder(kAvCodecIdAac);
  if (!codec_) {
    Log("AUDIO", "FFmpeg AAC decoder not found (AV_CODEC_ID_AAC)", "error");
    return false;
  }

  codec_ctx_ = g_audio_ffmpeg.alloc_context3(codec_);
  if (!codec_ctx_) {
    Log("AUDIO", "Failed to allocate AVCodecContext for AAC", "error");
    return false;
  }

  int ret = g_audio_ffmpeg.open2(codec_ctx_, codec_, nullptr);
  if (ret < 0) {
    Log("AUDIO", "avcodec_open2 failed for AAC decoder: " + std::to_string(ret), "error");
    g_audio_ffmpeg.free_context(&codec_ctx_);
    codec_ctx_ = nullptr;
    return false;
  }

  packet_ = g_audio_ffmpeg.packet_alloc();
  frame_ = g_audio_ffmpeg.frame_alloc();
  g_adts_stream_buffer.clear();

  is_initialized_ = true;
  Log("AUDIO", "FFmpeg AAC Audio Decoder initialized successfully", "success");
  return true;
}

bool AudioDecoder::InitWaveOut(uint32_t sample_rate, uint32_t /*channels*/) {
  std::lock_guard<std::mutex> lock(wave_mutex_);
  CloseWaveOut();

  current_sample_rate_ = sample_rate;
  current_channels_ = 2;

  WAVEFORMATEX wfx{};
  wfx.wFormatTag = WAVE_FORMAT_PCM;
  wfx.nChannels = 2;
  wfx.nSamplesPerSec = static_cast<DWORD>(sample_rate);
  wfx.wBitsPerSample = 16;
  wfx.nBlockAlign = wfx.nChannels * (wfx.wBitsPerSample / 8);
  wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
  wfx.cbSize = 0;

  MMRESULT res = waveOutOpen(&h_wave_out_, WAVE_MAPPER, &wfx,
                             reinterpret_cast<DWORD_PTR>(&AudioDecoder::WaveOutProc),
                             reinterpret_cast<DWORD_PTR>(this), CALLBACK_FUNCTION);
  if (res != MMSYSERR_NOERROR) {
    Log("AUDIO", "waveOutOpen failed with error: " + std::to_string(res), "error");
    h_wave_out_ = nullptr;
    return false;
  }

  for (size_t i = 0; i < kNumWaveBuffers; ++i) {
    wave_buffer_data_[i].resize(4096);
    std::memset(&wave_headers_[i], 0, sizeof(WAVEHDR));
  }
  current_wave_buffer_idx_ = 0;

  Log("AUDIO", "Windows WaveOut audio device initialized: " + std::to_string(sample_rate) + " Hz, 2 channels", "success");
  return true;
}

void AudioDecoder::CloseWaveOut() {
  if (h_wave_out_) {
    waveOutReset(h_wave_out_);
    for (size_t i = 0; i < kNumWaveBuffers; ++i) {
      if (wave_headers_[i].dwFlags & WHDR_PREPARED) {
        waveOutUnprepareHeader(h_wave_out_, &wave_headers_[i], sizeof(WAVEHDR));
      }
      wave_headers_[i].dwFlags = 0;
    }
    waveOutClose(h_wave_out_);
    h_wave_out_ = nullptr;
  }
}

void CALLBACK AudioDecoder::WaveOutProc(HWAVEOUT, UINT, DWORD_PTR, DWORD_PTR, DWORD_PTR) {}

void AudioDecoder::PlayPcm(const int16_t* pcm_data, size_t num_samples) {
  if (!h_wave_out_ || !pcm_data || num_samples == 0) return;

  std::unique_lock<std::mutex> lock(wave_mutex_);
  if (!h_wave_out_) return;

  const size_t bytes_to_write = num_samples * sizeof(int16_t);

  size_t idx = current_wave_buffer_idx_;
  bool found = false;

  for (size_t attempt = 0; attempt < kNumWaveBuffers; ++attempt) {
    WAVEHDR& candidate = wave_headers_[idx];
    if (!(candidate.dwFlags & WHDR_PREPARED) || (candidate.dwFlags & WHDR_DONE)) {
      found = true;
      break;
    }
    idx = (idx + 1) % kNumWaveBuffers;
  }

  if (!found) {
    for (int wait = 0; wait < 12; ++wait) {
      lock.unlock();
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
      lock.lock();
      if (!h_wave_out_) return;
      for (size_t attempt = 0; attempt < kNumWaveBuffers; ++attempt) {
        WAVEHDR& candidate = wave_headers_[attempt];
        if (!(candidate.dwFlags & WHDR_PREPARED) || (candidate.dwFlags & WHDR_DONE)) {
          found = true;
          idx = attempt;
          break;
        }
      }
      if (found) break;
    }
  }

  if (!found) return;

  WAVEHDR& hdr = wave_headers_[idx];
  if (hdr.dwFlags & WHDR_PREPARED) {
    waveOutUnprepareHeader(h_wave_out_, &hdr, sizeof(WAVEHDR));
    hdr.dwFlags = 0;
  }

  auto& buf = wave_buffer_data_[idx];
  if (buf.size() < bytes_to_write) {
    buf.resize(bytes_to_write);
  }
  std::memcpy(buf.data(), pcm_data, bytes_to_write);

  std::memset(&hdr, 0, sizeof(WAVEHDR));
  hdr.lpData = reinterpret_cast<LPSTR>(buf.data());
  hdr.dwBufferLength = static_cast<DWORD>(bytes_to_write);

  if (waveOutPrepareHeader(h_wave_out_, &hdr, sizeof(WAVEHDR)) == MMSYSERR_NOERROR) {
    waveOutWrite(h_wave_out_, &hdr, sizeof(WAVEHDR));
  }

  current_wave_buffer_idx_ = (idx + 1) % kNumWaveBuffers;
}

bool AudioDecoder::DecodeStream(const uint8_t* in_data, size_t in_size) {
  if (!in_data || in_size == 0) return false;
  if (!is_initialized_) {
    if (!Initialize()) return false;
  }

  std::lock_guard<std::mutex> lock(decode_mutex_);
  if (!codec_ctx_ || !packet_ || !frame_) return false;

  // Append incoming bytes into persistent ADTS framer buffer
  g_adts_stream_buffer.insert(g_adts_stream_buffer.end(), in_data, in_data + in_size);

  size_t offset = 0;
  const size_t total = g_adts_stream_buffer.size();

  while (offset + 7 <= total) {
    const uint8_t* ptr = g_adts_stream_buffer.data() + offset;

    // 1. Strip optional 4-byte [00 00 00 02] tag if present before ADTS syncword
    if (ptr[0] == 0x00 && ptr[1] == 0x00 && ptr[2] == 0x00 && ptr[3] == 0x02) {
      offset += 4;
      continue;
    }

    // 2. Scan for valid 12-bit ADTS syncword (0xFFF)
    if (ptr[0] != 0xFF || (ptr[1] & 0xF0) != 0xF0) {
      offset += 1;
      continue;
    }

    // 3. Parse exact 13-bit ADTS frame length from bytes 3, 4, 5
    const int frame_length = ((static_cast<int>(ptr[3] & 0x03)) << 11) |
                             ((static_cast<int>(ptr[4])) << 3) |
                             ((static_cast<int>(ptr[5] >> 5)) & 0x07);

    if (frame_length < 7 || frame_length > 4096) {
      // False syncword; step forward 1 byte
      offset += 1;
      continue;
    }

    // Wait for more TCP bytes if full ADTS frame has not arrived yet
    if (offset + static_cast<size_t>(frame_length) > total) {
      break;
    }

    const int adts_sample_rate = GetSampleRateFromAdtsHeader(ptr);

    auto* pkt = reinterpret_cast<FF_AVPacket*>(packet_);
    g_audio_ffmpeg.packet_unref(pkt);
    pkt->data = const_cast<uint8_t*>(ptr);
    pkt->size = frame_length;

    offset += static_cast<size_t>(frame_length);

    int ret = g_audio_ffmpeg.send_packet(codec_ctx_, pkt);
    if (ret < 0) continue;

    while (ret >= 0) {
      ret = g_audio_ffmpeg.receive_frame(codec_ctx_, frame_);
      if (ret < 0) break;

      auto* f = reinterpret_cast<FF_AVFrame*>(frame_);
      if (f->nb_samples <= 0 || !f->data[0]) continue;

      int sample_rate = adts_sample_rate;
      if (g_audio_ffmpeg.opt_get_int) {
        int64_t sr_val = 0;
        if (g_audio_ffmpeg.opt_get_int(codec_ctx_, "ar", 0, &sr_val) == 0 && sr_val > 0) {
          sample_rate = static_cast<int>(sr_val);
        }
      }

      if (!h_wave_out_ || sample_rate != static_cast<int>(current_sample_rate_)) {
        InitWaveOut(static_cast<uint32_t>(sample_rate), 2);
      }

      std::vector<int16_t> pcm;

      // AAC decodes to AV_SAMPLE_FMT_FLTP (format == 8): data[0] = Left, data[1] = Right
      if (f->format == 8 /* AV_SAMPLE_FMT_FLTP */) {
        const float* left = reinterpret_cast<const float*>(f->data[0]);
        const float* right = (f->data[1] != nullptr) ? reinterpret_cast<const float*>(f->data[1]) : left;
        pcm.resize(static_cast<size_t>(f->nb_samples) * 2);
        for (int i = 0; i < f->nb_samples; ++i) {
          const float l = std::isfinite(left[i]) ? std::clamp(left[i], -1.0f, 1.0f) : 0.0f;
          const float r = std::isfinite(right[i]) ? std::clamp(right[i], -1.0f, 1.0f) : 0.0f;
          pcm[i * 2]     = static_cast<int16_t>(l * 32767.0f);
          pcm[i * 2 + 1] = static_cast<int16_t>(r * 32767.0f);
        }
      } else if (f->format == 6 /* AV_SAMPLE_FMT_S16P */) {
        const int16_t* left = reinterpret_cast<const int16_t*>(f->data[0]);
        const int16_t* right = (f->data[1] != nullptr) ? reinterpret_cast<const int16_t*>(f->data[1]) : left;
        pcm.resize(static_cast<size_t>(f->nb_samples) * 2);
        for (int i = 0; i < f->nb_samples; ++i) {
          pcm[i * 2]     = left[i];
          pcm[i * 2 + 1] = right[i];
        }
      } else if (f->format == 1 /* AV_SAMPLE_FMT_S16 */) {
        const int16_t* samples = reinterpret_cast<const int16_t*>(f->data[0]);
        pcm.assign(samples, samples + static_cast<size_t>(f->nb_samples) * 2);
      }

      if (!pcm.empty()) {
        PlayPcm(pcm.data(), pcm.size());

        // Live Audio Detector - Calculate Peak Amplitude & RMS Energy
        float peak = 0.0f;
        double sum_sq = 0.0;
        const size_t total_samples = pcm.size();
        for (size_t i = 0; i < total_samples; ++i) {
          const float abs_val = std::abs(pcm[i]) / 32767.0f;
          if (abs_val > peak) peak = abs_val;
          sum_sq += abs_val * abs_val;
        }
        const double rms = (total_samples > 0) ? std::sqrt(sum_sq / total_samples) : 0.0;
        const double dbfs = (rms > 1e-5) ? 20.0 * std::log10(rms) : -100.0;

        current_peak_amplitude_ = peak;
        current_rms_dbfs_ = static_cast<float>(dbfs);
        total_frames_decoded_++;

        const bool sound_detected = (peak > 0.005f); // > -46 dBFS indicates audible speech/music
        is_sound_detected_ = sound_detected;

        static auto s_last_detector_log = std::chrono::steady_clock::now();
        static bool s_last_state = false;
        auto now = std::chrono::steady_clock::now();
        auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - s_last_detector_log).count();

        // Log on sound transition OR periodically every 1500ms
        if (sound_detected != s_last_state || elapsed_ms >= 1500 || total_frames_decoded_ == 1) {
          s_last_detector_log = now;
          s_last_state = sound_detected;

          char db_buf[16];
          snprintf(db_buf, sizeof(db_buf), "%.1f", dbfs);
          const int peak_pct = static_cast<int>(peak * 100.0f);

          if (sound_detected) {
            Log("AUDIO_DETECTOR", "🔊 SOUND DETECTED! Level: " + std::string(db_buf) +
                " dBFS (Peak: " + std::to_string(peak_pct) + "%) | Frame #" +
                std::to_string(total_frames_decoded_.load()) + " (" +
                std::to_string(f->nb_samples) + " samples @ " +
                std::to_string(sample_rate) + " Hz Stereo) -> Playing on Speakers", "success");
          } else {
            Log("AUDIO_DETECTOR", "🔇 SILENCE / ZERO PCM (iPhone is streaming audio, but volume is silent/muted) | Frame #" +
                std::to_string(total_frames_decoded_.load()) + " @ " + std::to_string(sample_rate) + " Hz", "info");
          }
        }
      }
    }
  }

  if (offset > 0) {
    g_adts_stream_buffer.erase(g_adts_stream_buffer.begin(),
                               g_adts_stream_buffer.begin() + static_cast<ptrdiff_t>(offset));
  }
  if (g_adts_stream_buffer.size() > 65536) {
    g_adts_stream_buffer.clear();
  }

  return true;
}

void AudioDecoder::Flush() {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  g_adts_stream_buffer.clear();
  if (codec_ctx_ && g_audio_ffmpeg.flush_buffers) {
    g_audio_ffmpeg.flush_buffers(codec_ctx_);
  }
}

void AudioDecoder::Teardown() {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  CloseWaveOut();
  g_adts_stream_buffer.clear();

  if (packet_ && g_audio_ffmpeg.packet_free) {
    g_audio_ffmpeg.packet_free(&packet_);
    packet_ = nullptr;
  }
  if (frame_ && g_audio_ffmpeg.frame_free) {
    g_audio_ffmpeg.frame_free(&frame_);
    frame_ = nullptr;
  }
  if (codec_ctx_ && g_audio_ffmpeg.free_context) {
    g_audio_ffmpeg.free_context(&codec_ctx_);
    codec_ctx_ = nullptr;
  }

  is_initialized_ = false;
  Log("AUDIO", "Audio Decoder teardown complete", "info");
}

}  // namespace applecast
