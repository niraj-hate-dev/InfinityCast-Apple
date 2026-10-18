#include "rtp_demuxer.h"

#include <cstring>
#include <iostream>

namespace applecast {

namespace {

// Annex B 4-byte NAL delimiter: 0x00 0x00 0x00 0x01
const uint8_t kAnnexBStartCode[4] = {0x00, 0x00, 0x00, 0x01};

// H.264 NAL Unit Types
constexpr uint8_t kNalTypeNonIdr = 1;
constexpr uint8_t kNalTypeIdr    = 5;
constexpr uint8_t kNalTypeSps    = 7;
constexpr uint8_t kNalTypePps    = 8;
constexpr uint8_t kNalTypeStapA  = 24;
constexpr uint8_t kNalTypeFuA    = 28;

}  // namespace

RtpDemuxer::RtpDemuxer(VideoPacketCallback on_video_packet)
    : on_video_packet_(std::move(on_video_packet)) {
  accumulator_.reserve(65536);
  fu_assembly_buffer_.reserve(131072);
}

RtpDemuxer::~RtpDemuxer() = default;

void RtpDemuxer::Reset() {
  state_ = STATE_FIND_MAGIC;
  accumulator_.clear();
  apower_assembly_buffer_.clear();
  fu_assembly_buffer_.clear();
  fu_in_progress_ = false;
  has_initial_seq_ = false;
  last_seq_ = 0;
  total_packets_ = 0;
  dropped_packets_ = 0;
}

void RtpDemuxer::AppendAnnexBStartCode(std::vector<uint8_t>& out) {
  out.insert(out.end(), kAnnexBStartCode, kAnnexBStartCode + 4);
}

void RtpDemuxer::CacheParameterSets(uint8_t nal_type, const uint8_t* nal_data, size_t nal_len) {
  if (!nal_data || nal_len == 0) return;

  if (nal_type == kNalTypeSps) {
    // Check if PPS start code is embedded inside (standard in ApowerMirror gotSpsPps)
    size_t sps_len = nal_len;
    for (size_t i = 0; i + 4 <= nal_len; ++i) {
      if (nal_data[i] == 0x00 && nal_data[i + 1] == 0x00 &&
          nal_data[i + 2] == 0x00 && nal_data[i + 3] == 0x01) {
        sps_len = i;
        const uint8_t pps_type = nal_data[i + 4] & 0x1F;
        if (pps_type == kNalTypePps) {
          cached_pps_.assign(nal_data + i + 4, nal_data + nal_len);
        }
        break;
      }
    }
    cached_sps_.assign(nal_data, nal_data + sps_len);
  } else if (nal_type == kNalTypePps) {
    cached_pps_.assign(nal_data, nal_data + nal_len);
  }
}

void RtpDemuxer::ConsumeData(const uint8_t* buffer, size_t length) {
  if (!buffer || length == 0) return;

  accumulator_.insert(accumulator_.end(), buffer, buffer + length);

  size_t read_idx = 0;

  while (read_idx < accumulator_.size()) {
    const size_t rem = accumulator_.size() - read_idx;

    // 1. Skip HTTP Handshake / Headers if present (e.g. "HTTP/1.1 200 OK\r\n..." or "GET /...")
    if (rem >= 4 && (std::memcmp(accumulator_.data() + read_idx, "HTTP", 4) == 0 ||
                     std::memcmp(accumulator_.data() + read_idx, "GET ", 4) == 0)) {
      bool found_crlf = false;
      for (size_t i = read_idx; i + 3 < accumulator_.size(); ++i) {
        if (accumulator_[i] == '\r' && accumulator_[i + 1] == '\n' &&
            accumulator_[i + 2] == '\r' && accumulator_[i + 3] == '\n') {
          read_idx = i + 4;
          found_crlf = true;
          break;
        }
      }
      if (found_crlf) continue;
      if (rem < 4096) break;
      read_idx += 4;
      continue;
    }

    // 2. Skip text control commands (e.g. "cmd-Rotation-Resp:...\n" or "cmd-Resolution-Resp:...\n")
    if (rem >= 4 && std::memcmp(accumulator_.data() + read_idx, "cmd-", 4) == 0) {
      bool found_nl = false;
      for (size_t i = read_idx; i < accumulator_.size(); ++i) {
        if (accumulator_[i] == '\n') {
          read_idx = i + 1;
          found_nl = true;
          break;
        }
      }
      if (found_nl) continue;
      break;
    }

    // 3. Mode C: RFC 2326 Interleaved RTP framing ($ = 0x24)
    if (accumulator_[read_idx] == kRtpInterleavedMagic) {
      if (rem < 4) break;
      const uint8_t channel = accumulator_[read_idx + 1];
      const uint16_t interleaved_len = (static_cast<uint16_t>(accumulator_[read_idx + 2]) << 8) |
                                       static_cast<uint16_t>(accumulator_[read_idx + 3]);
      if (rem < 4 + interleaved_len) break;

      ProcessInterleavedPayload(channel, accumulator_.data() + read_idx + 4, interleaved_len);
      read_idx += 4 + interleaved_len;
      continue;
    }

    // 4. Mode A: ApowerMirror Sliced Framing (4-byte tag [00 00 00 00] or [00 00 00 02])
    if (rem >= 4 && accumulator_[read_idx] == 0x00 && accumulator_[read_idx + 1] == 0x00 &&
        accumulator_[read_idx + 2] == 0x00 &&
        (accumulator_[read_idx + 3] == 0x00 || accumulator_[read_idx + 3] == 0x02)) {

      const uint8_t tag = accumulator_[read_idx + 3];

      if (tag == 0x00) {
        // Tag 0x00 = Intermediate slice chunk of 10,240 bytes
        constexpr size_t kApowerChunkLen = 10240;
        constexpr size_t kApowerTotalChunk = 4 + kApowerChunkLen;

        if (rem < kApowerTotalChunk) {
          break; // wait for remaining bytes
        }

        apower_assembly_buffer_.insert(
            apower_assembly_buffer_.end(),
            accumulator_.data() + read_idx + 4,
            accumulator_.data() + read_idx + kApowerTotalChunk);

        read_idx += kApowerTotalChunk;
        continue;
      } else {
        // Tag 0x02 = End frame chunk.
        // Locate end of this chunk (next tag or end of accumulator)
        size_t next_boundary = std::string::npos;
        for (size_t i = read_idx + 4; i + 4 <= accumulator_.size(); ++i) {
          if (accumulator_[i] == 0x00 && accumulator_[i + 1] == 0x00 && accumulator_[i + 2] == 0x00 &&
              (accumulator_[i + 3] == 0x00 || accumulator_[i + 3] == 0x02 || accumulator_[i + 3] == 0x01)) {
            next_boundary = i;
            break;
          }
          if (accumulator_[i] == kRtpInterleavedMagic) {
            next_boundary = i;
            break;
          }
        }

        const size_t final_chunk_len = (next_boundary != std::string::npos)
                                           ? (next_boundary - (read_idx + 4))
                                           : (rem - 4);

        if (final_chunk_len > 0) {
          apower_assembly_buffer_.insert(
              apower_assembly_buffer_.end(),
              accumulator_.data() + read_idx + 4,
              accumulator_.data() + read_idx + 4 + final_chunk_len);
        }

        if (!apower_assembly_buffer_.empty()) {
          DemuxedVideoPacket packet;
          packet.data = std::move(apower_assembly_buffer_);
          packet.pts = 0;
          total_packets_++;
          if (on_video_packet_) {
            on_video_packet_(packet);
          }
          apower_assembly_buffer_.clear();
        }

        read_idx += (4 + final_chunk_len);
        continue;
      }
    }

    // 5. Mode B: Direct Raw Annex-B stream [00 00 00 01]
    if (rem >= 4 && accumulator_[read_idx] == 0x00 && accumulator_[read_idx + 1] == 0x00 &&
        accumulator_[read_idx + 2] == 0x00 && accumulator_[read_idx + 3] == 0x01) {

      // Feed complete Annex-B slice chunk directly to video decoder stream parser
      DemuxedVideoPacket packet;
      packet.data.assign(accumulator_.data() + read_idx, accumulator_.data() + accumulator_.size());
      packet.pts = 0;
      total_packets_++;

      if (on_video_packet_) {
        on_video_packet_(packet);
      }

      read_idx = accumulator_.size();
      break;
    }

    // 6. Unrecognized leading byte, scan forward
    read_idx++;
  }

  // Prevent runaway buffer allocation if stream desynchronizes
  if (accumulator_.size() > 4 * 1024 * 1024) {
    accumulator_.clear();
    apower_assembly_buffer_.clear();
    read_idx = 0;
  }

  // Erase consumed bytes from accumulator
  if (read_idx > 0) {
    accumulator_.erase(accumulator_.begin(), accumulator_.begin() + read_idx);
  }
}

void RtpDemuxer::ProcessInterleavedPayload(uint8_t channel, const uint8_t* payload, size_t length) {
  if (channel == kRtpChannelVideo) {
    ProcessRtpVideoPayload(payload, length);
  } else if (channel == kRtpChannelControl) {
    // Channel 0x01: Timing / Heartbeat / Control Packet
  }
}

void RtpDemuxer::ProcessRtpVideoPayload(const uint8_t* payload, size_t length) {
  if (length < kRtpHeaderSize) {
    return;
  }

  // Parse 12-byte RTP Header
  const uint8_t version = (payload[0] >> 6) & 0x03;
  if (version != 2) {
    return; // Ignore non-RTP v2 packets
  }

  const bool marker = (payload[1] & 0x80) != 0;
  const uint16_t seq = (static_cast<uint16_t>(payload[2]) << 8) |
                        static_cast<uint16_t>(payload[3]);
  const uint32_t pts = (static_cast<uint32_t>(payload[4]) << 24) |
                       (static_cast<uint32_t>(payload[5]) << 16) |
                       (static_cast<uint32_t>(payload[6]) << 8)  |
                       static_cast<uint32_t>(payload[7]);

  // Track sequence drops
  if (has_initial_seq_) {
    const uint16_t expected_seq = last_seq_ + 1;
    if (seq != expected_seq) {
      const uint16_t lost = seq - expected_seq;
      dropped_packets_ += lost;
    }
  } else {
    has_initial_seq_ = true;
  }
  last_seq_ = seq;
  total_packets_++;

  const uint8_t* rtp_payload = payload + kRtpHeaderSize;
  const size_t payload_len = length - kRtpHeaderSize;

  ProcessH264Payload(rtp_payload, payload_len, pts, seq, marker);
}

void RtpDemuxer::ProcessH264Payload(const uint8_t* rtp_payload,
                                    size_t payload_len,
                                    uint32_t pts,
                                    uint16_t seq,
                                    bool marker) {
  if (payload_len == 0) return;

  const uint8_t nal_type = rtp_payload[0] & 0x1F;

  // Case 1: Single NAL Unit Packet (Type 1 to 23)
  if (nal_type >= kNalTypeNonIdr && nal_type <= 23) {
    CacheParameterSets(nal_type, rtp_payload, payload_len);

    DemuxedVideoPacket packet;
    packet.pts = pts;
    packet.seq = seq;
    packet.is_keyframe = (nal_type == kNalTypeIdr);
    packet.is_marker = marker;

    // If IDR keyframe, prepend cached SPS and PPS to ensure decoder synchronization
    if (packet.is_keyframe && !cached_sps_.empty() && !cached_pps_.empty()) {
      AppendAnnexBStartCode(packet.data);
      packet.data.insert(packet.data.end(), cached_sps_.begin(), cached_sps_.end());
      AppendAnnexBStartCode(packet.data);
      packet.data.insert(packet.data.end(), cached_pps_.begin(), cached_pps_.end());
    }

    AppendAnnexBStartCode(packet.data);
    packet.data.insert(packet.data.end(), rtp_payload, rtp_payload + payload_len);

    if (on_video_packet_) {
      on_video_packet_(packet);
    }
  }
  // Case 2: STAP-A Aggregation Packet (Type 24 - commonly packs SPS + PPS + IDR slice)
  else if (nal_type == kNalTypeStapA) {
    DemuxedVideoPacket packet;
    packet.pts = pts;
    packet.seq = seq;
    packet.is_marker = marker;

    size_t offset = 1; // Skip STAP-A indicator byte
    while (offset + 2 <= payload_len) {
      const uint16_t nalu_size = (static_cast<uint16_t>(rtp_payload[offset]) << 8) |
                                  static_cast<uint16_t>(rtp_payload[offset + 1]);
      offset += 2;

      if (offset + nalu_size > payload_len) break;

      const uint8_t* nalu_ptr = rtp_payload + offset;
      const uint8_t sub_nal_type = nalu_ptr[0] & 0x1F;

      CacheParameterSets(sub_nal_type, nalu_ptr, nalu_size);
      if (sub_nal_type == kNalTypeIdr) {
        packet.is_keyframe = true;
      }

      AppendAnnexBStartCode(packet.data);
      packet.data.insert(packet.data.end(), nalu_ptr, nalu_ptr + nalu_size);

      offset += nalu_size;
    }

    if (on_video_packet_ && !packet.data.empty()) {
      on_video_packet_(packet);
    }
  }
  // Case 3: FU-A Fragmentation Unit (Type 28 - splits single large frames across MTU packets)
  else if (nal_type == kNalTypeFuA) {
    if (payload_len < 2) return;

    const uint8_t fu_indicator = rtp_payload[0];
    const uint8_t fu_header = rtp_payload[1];

    const bool is_start = (fu_header & 0x80) != 0;
    const bool is_end   = (fu_header & 0x40) != 0;
    const uint8_t original_nal_type = fu_header & 0x1F;
    const uint8_t reconstructed_nal_header = (fu_indicator & 0xE0) | original_nal_type;

    if (is_start) {
      fu_assembly_buffer_.clear();
      AppendAnnexBStartCode(fu_assembly_buffer_);
      fu_assembly_buffer_.push_back(reconstructed_nal_header);
      fu_assembly_buffer_.insert(fu_assembly_buffer_.end(), rtp_payload + 2, rtp_payload + payload_len);
      fu_in_progress_ = true;
    } else if (fu_in_progress_) {
      fu_assembly_buffer_.insert(fu_assembly_buffer_.end(), rtp_payload + 2, rtp_payload + payload_len);
    }

    if (is_end && fu_in_progress_) {
      fu_in_progress_ = false;

      DemuxedVideoPacket packet;
      packet.pts = pts;
      packet.seq = seq;
      packet.is_keyframe = (original_nal_type == kNalTypeIdr);
      packet.is_marker = marker;

      // If IDR keyframe, prepend cached SPS and PPS to ensure decoder synchronization
      if (packet.is_keyframe && !cached_sps_.empty() && !cached_pps_.empty()) {
        std::vector<uint8_t> full_idr_data;
        full_idr_data.reserve(cached_sps_.size() + cached_pps_.size() + fu_assembly_buffer_.size() + 16);
        AppendAnnexBStartCode(full_idr_data);
        full_idr_data.insert(full_idr_data.end(), cached_sps_.begin(), cached_sps_.end());
        AppendAnnexBStartCode(full_idr_data);
        full_idr_data.insert(full_idr_data.end(), cached_pps_.begin(), cached_pps_.end());
        full_idr_data.insert(full_idr_data.end(), fu_assembly_buffer_.begin(), fu_assembly_buffer_.end());
        packet.data = std::move(full_idr_data);
      } else {
        packet.data = std::move(fu_assembly_buffer_);
      }
      fu_assembly_buffer_.clear();

      if (on_video_packet_) {
        on_video_packet_(packet);
      }
    }
  }
}

}  // namespace applecast
