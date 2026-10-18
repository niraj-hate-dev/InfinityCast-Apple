#include "audio_decoder.h"
#include "logger.h"

#include <iostream>
#include <algorithm>
#include <cstring>

namespace applecast {

namespace {

// FFmpeg C API Constants & Layouts for Dynamic Binding
constexpr int kAvCodecIdAac = 86018; // 0x15002
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
typedef int   (*FnAvcodecSendPacket)(void* avctx, const void* pkt);
typedef int   (*FnAvcodecReceiveFrame)(void* avctx, void* frame);
typedef void* (*FnAvParserInit)(int codec_id);
typedef int   (*FnAvParserParse2)(void* s, void* avctx,
                                  uint8_t** poutbuf, int* poutbuf_size,
                                  const uint8_t* buf, int buf_size,
                                  int64_t pts, int64_t dts, int64_t pos);
typedef void  (*FnAvParserClose)(void* s);
typedef int   (*FnAvOptGetInt)(void* obj, const char* name, int search_flags, int64_t* out_val);

struct FfmpegAudioFunctions {
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
  FnAvOptGetInt opt_get_int = nullptr;
} g_audio_ffmpeg;

}  // namespace

AudioDecoder::AudioDecoder() = default;

AudioDecoder::~AudioDecoder() {
  Teardown();
}

bool AudioDecoder::LoadFfmpegSymbols() {
  if (g_audio_ffmpeg.find_decoder != nullptr) {
    return true; // Already loaded
  }

  // 1. Load avutil
  const char* kAvutilNames[] = {
      "avutil-59.dll", "avutil-60.dll", "avutil-58.dll", "avutil-57.dll", "avutil.dll"
  };
  for (const char* dll_name : kAvutilNames) {
    avutil_module_ = LoadLibraryA(dll_name);
    if (avutil_module_) {
      break;
    }
  }

  if (!avutil_module_) {
    Log("AUDIO", "avutil library not found for audio decoding", "error");
    return false;
  }

  g_audio_ffmpeg.frame_alloc = (FnAvFrameAlloc)GetProcAddress(avutil_module_, "av_frame_alloc");
  g_audio_ffmpeg.frame_free = (FnAvFrameFree)GetProcAddress(avutil_module_, "av_frame_free");
  g_audio_ffmpeg.opt_get_int = (FnAvOptGetInt)GetProcAddress(avutil_module_, "av_opt_get_int");

  // 2. Load avcodec
  const char* kAvcodecNames[] = {
      "avcodec-61.dll", "avcodec-62.dll", "avcodec-60.dll", "avcodec-59.dll", "avcodec.dll"
  };
  for (const char* dll_name : kAvcodecNames) {
    avcodec_module_ = LoadLibraryA(dll_name);
    if (avcodec_module_) {
      break;
    }
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
  g_audio_ffmpeg.parser_init = (FnAvParserInit)GetProcAddress(avcodec_module_, "av_parser_init");
  g_audio_ffmpeg.parser_parse2 = (FnAvParserParse2)GetProcAddress(avcodec_module_, "av_parser_parse2");
  g_audio_ffmpeg.parser_close = (FnAvParserClose)GetProcAddress(avcodec_module_, "av_parser_close");

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

  parser_ = g_audio_ffmpeg.parser_init(kAvCodecIdAac);
  packet_ = g_audio_ffmpeg.packet_alloc();
  frame_ = g_audio_ffmpeg.frame_alloc();

  is_initialized_ = true;
  Log("AUDIO", "FFmpeg AAC Audio Decoder initialized successfully", "success");
  return true;
}

bool AudioDecoder::InitWaveOut(uint32_t sample_rate, uint32_t channels) {
  std::lock_guard<std::mutex> lock(wave_mutex_);
  CloseWaveOut();

  current_sample_rate_ = sample_rate;
  current_channels_ = channels;

  WAVEFORMATEX wfx{};
  wfx.wFormatTag = WAVE_FORMAT_PCM;
  wfx.nChannels = static_cast<WORD>(channels);
  wfx.nSamplesPerSec = static_cast<DWORD>(sample_rate);
  wfx.wBitsPerSample = 16;
  wfx.nBlockAlign = wfx.nChannels * (wfx.wBitsPerSample / 8);
  wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
  wfx.cbSize = 0;

  MMRESULT res = waveOutOpen(&h_wave_out_, WAVE_MAPPER, &wfx, (DWORD_PTR)&WaveOutProc, (DWORD_PTR)this, CALLBACK_FUNCTION);
  if (res != MMSYSERR_NOERROR) {
    Log("AUDIO", "waveOutOpen failed with error: " + std::to_string(res), "error");
    h_wave_out_ = nullptr;
    return false;
  }

  for (size_t i = 0; i < kNumWaveBuffers; ++i) {
    wave_buffer_data_[i].resize(16384);
    std::memset(&wave_headers_[i], 0, sizeof(WAVEHDR));
  }
  current_wave_buffer_idx_ = 0;

  Log("AUDIO", "Windows WaveOut audio device initialized: " + std::to_string(sample_rate) + " Hz, " + std::to_string(channels) + " channels", "success");
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

void CALLBACK AudioDecoder::WaveOutProc(HWAVEOUT hwo, UINT uMsg, DWORD_PTR dwInstance, DWORD_PTR dwParam1, DWORD_PTR dwParam2) {
  if (uMsg == WOM_DONE) {
    auto* hdr = reinterpret_cast<WAVEHDR*>(dwParam1);
    if (hdr && hwo) {
      waveOutUnprepareHeader(hwo, hdr, sizeof(WAVEHDR));
    }
  }
}

void AudioDecoder::PlayPcm(const int16_t* pcm_data, size_t num_samples) {
  if (!h_wave_out_ || !pcm_data || num_samples == 0) return;

  std::lock_guard<std::mutex> lock(wave_mutex_);
  if (!h_wave_out_) return;

  const size_t bytes_to_write = num_samples * sizeof(int16_t);

  size_t idx = current_wave_buffer_idx_;
  WAVEHDR& hdr = wave_headers_[idx];

  if (hdr.dwFlags & WHDR_PREPARED) {
    if (hdr.dwFlags & WHDR_DONE) {
      waveOutUnprepareHeader(h_wave_out_, &hdr, sizeof(WAVEHDR));
    } else {
      // Buffer still in playback queue, advance to next
      idx = (idx + 1) % kNumWaveBuffers;
    }
  }

  auto& buf = wave_buffer_data_[idx];
  if (buf.size() < bytes_to_write) {
    buf.resize(bytes_to_write);
  }
  std::memcpy(buf.data(), pcm_data, bytes_to_write);

  std::memset(&hdr, 0, sizeof(WAVEHDR));
  hdr.lpData = reinterpret_cast<LPSTR>(buf.data());
  hdr.dwBufferLength = static_cast<DWORD>(bytes_to_write);

  MMRESULT prep_res = waveOutPrepareHeader(h_wave_out_, &hdr, sizeof(WAVEHDR));
  if (prep_res == MMSYSERR_NOERROR) {
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
  if (!codec_ctx_ || !parser_) return false;

  const uint8_t* cur_ptr = in_data;
  // If packet starts with HTTP response (e.g. from /mirrorVoice.do handshake), skip HTTP header
  if (cur_size >= 4 && cur_ptr[0] == 'H' && cur_ptr[1] == 'T' && cur_ptr[2] == 'T' && cur_ptr[3] == 'P') {
    for (int i = 0; i <= cur_size - 4; ++i) {
      if (cur_ptr[i] == '\r' && cur_ptr[i + 1] == '\n' && cur_ptr[i + 2] == '\r' && cur_ptr[i + 3] == '\n') {
        cur_ptr += (i + 4);
        cur_size -= (i + 4);
        break;
      }
    }
  }

  // If packet starts with ApowerMirror 4-byte audio tag [00 00 00 02] followed by ADTS syncword [FF Fx], skip 4 bytes
  if (cur_size >= 6 && cur_ptr[0] == 0x00 && cur_ptr[1] == 0x00 && cur_ptr[2] == 0x00 && cur_ptr[3] == 0x02 &&
      cur_ptr[4] == 0xFF && (cur_ptr[5] & 0xF0) == 0xF0) {
    cur_ptr += 4;
    cur_size -= 4;
  }

  while (cur_size > 0) {
    uint8_t* poutbuf = nullptr;
    int poutbuf_size = 0;

    int bytes_consumed = g_audio_ffmpeg.parser_parse2(
        parser_, codec_ctx_, &poutbuf, &poutbuf_size,
        cur_ptr, cur_size,
        kAvNoPtsValue, kAvNoPtsValue, 0);

    if (bytes_consumed < 0) {
      break;
    }

    cur_ptr += bytes_consumed;
    cur_size -= bytes_consumed;

    if (poutbuf_size > 0 && poutbuf) {
      auto* pkt = reinterpret_cast<FF_AVPacket*>(packet_);
      g_audio_ffmpeg.packet_unref(pkt);
      pkt->data = poutbuf;
      pkt->size = poutbuf_size;

      int ret = g_audio_ffmpeg.send_packet(codec_ctx_, pkt);
      if (ret < 0) continue;

      while (ret >= 0) {
        ret = g_audio_ffmpeg.receive_frame(codec_ctx_, frame_);
        if (ret == -11 /* EAGAIN */ || ret == -541478725 /* AVERROR_EOF */) {
          break;
        } else if (ret < 0) {
          break;
        }

        auto* f = reinterpret_cast<FF_AVFrame*>(frame_);
        if (f->nb_samples <= 0) continue;

        // Query sample rate and channel count
        int sample_rate = 0;
        int channels = 0;

        if (g_audio_ffmpeg.opt_get_int) {
          int64_t sr_val = 0;
          if (g_audio_ffmpeg.opt_get_int(codec_ctx_, "ar", 0, &sr_val) == 0) {
            sample_rate = static_cast<int>(sr_val);
          }
        }

        if (sample_rate <= 0) {
          sample_rate = *reinterpret_cast<const int*>(reinterpret_cast<const uint8_t*>(codec_ctx_) + 344);
        }
        channels = *reinterpret_cast<const int*>(reinterpret_cast<const uint8_t*>(codec_ctx_) + 356);

        if (sample_rate <= 0) sample_rate = 44100;
        if (channels <= 0) channels = 2;

        if (!h_wave_out_ || sample_rate != static_cast<int>(current_sample_rate_) || channels != static_cast<int>(current_channels_)) {
          InitWaveOut(static_cast<uint32_t>(sample_rate), static_cast<uint32_t>(channels));
        }

        // Convert PCM samples to 16-bit interleaved stereo format
        // Format 8 = AV_SAMPLE_FMT_FLTP (Planar 32-bit Float - default for AAC)
        // Format 3 = AV_SAMPLE_FMT_FLT (Interleaved 32-bit Float)
        // Format 1 = AV_SAMPLE_FMT_S16 (Interleaved 16-bit Integer)
        // Format 6 = AV_SAMPLE_FMT_S16P (Planar 16-bit Integer)
        if (f->format == 8 /* AV_SAMPLE_FMT_FLTP */) {
          const float* left = reinterpret_cast<const float*>(f->data[0]);
          const float* right = (channels > 1 && f->data[1]) ? reinterpret_cast<const float*>(f->data[1]) : left;
          std::vector<int16_t> pcm(f->nb_samples * channels);
          for (int i = 0; i < f->nb_samples; ++i) {
            float l = left[i];
            float r = right[i];
            pcm[i * 2] = static_cast<int16_t>(std::clamp(l, -1.0f, 1.0f) * 32767.0f);
            pcm[i * 2 + 1] = static_cast<int16_t>(std::clamp(r, -1.0f, 1.0f) * 32767.0f);
          }
          PlayPcm(pcm.data(), pcm.size());
        } else if (f->format == 3 /* AV_SAMPLE_FMT_FLT */) {
          const float* samples = reinterpret_cast<const float*>(f->data[0]);
          std::vector<int16_t> pcm(f->nb_samples * channels);
          for (size_t i = 0; i < pcm.size(); ++i) {
            pcm[i] = static_cast<int16_t>(std::clamp(samples[i], -1.0f, 1.0f) * 32767.0f);
          }
          PlayPcm(pcm.data(), pcm.size());
        } else if (f->format == 1 /* AV_SAMPLE_FMT_S16 */) {
          const int16_t* samples = reinterpret_cast<const int16_t*>(f->data[0]);
          PlayPcm(samples, f->nb_samples * channels);
        } else if (f->format == 6 /* AV_SAMPLE_FMT_S16P */) {
          const int16_t* left = reinterpret_cast<const int16_t*>(f->data[0]);
          const int16_t* right = (channels > 1 && f->data[1]) ? reinterpret_cast<const int16_t*>(f->data[1]) : left;
          std::vector<int16_t> pcm(f->nb_samples * channels);
          for (int i = 0; i < f->nb_samples; ++i) {
            pcm[i * 2] = left[i];
            pcm[i * 2 + 1] = right[i];
          }
          PlayPcm(pcm.data(), pcm.size());
        }
      }
    }
  }

  return true;
}

void AudioDecoder::Teardown() {
  std::lock_guard<std::mutex> lock(decode_mutex_);
  CloseWaveOut();

  if (parser_ && g_audio_ffmpeg.parser_close) {
    g_audio_ffmpeg.parser_close(parser_);
    parser_ = nullptr;
  }
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
