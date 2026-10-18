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
  if (nal_type == kNalTypeSps) {
    cached_sps_.assign(nal_data, nal_data + nal_len);
  } else if (nal_type == kNalTypePps) {
    cached_pps_.assign(nal_data, nal_data + nal_len);
  }
}

void RtpDemuxer::ConsumeData(const uint8_t* buffer, size_t length) {
  if (!buffer || length == 0) return;

  accumulator_.insert(accumulator_.end(), buffer, buffer + length);

  size_t read_idx = 0;

  while (read_idx < accumulator_.size()) {
    // Mode C: RFC 2326 Interleaved RTP framing ($ = 0x24) - PRIMARY STREAMING PROTOCOL
    if (accumulator_[read_idx] == kRtpInterleavedMagic) {
      if (accumulator_.size() - read_idx < 4) break;
      uint8_t channel = accumulator_[read_idx + 1];
      uint16_t interleaved_len = (static_cast<uint16_t>(accumulator_[read_idx + 2]) << 8) |
                                 static_cast<uint16_t>(accumulator_[read_idx + 3]);
      if (accumulator_.size() - read_idx < 4 + interleaved_len) break;

      ProcessInterleavedPayload(channel, accumulator_.data() + read_idx + 4, interleaved_len);
      read_idx += 4 + interleaved_len;
      continue;
    }

    // Mode B: Direct Annex-B start code [00 00 00 01]
    if (accumulator_.size() - read_idx >= 4 &&
        accumulator_[read_idx] == 0x00 && accumulator_[read_idx + 1] == 0x00 &&
        accumulator_[read_idx + 2] == 0x00 && accumulator_[read_idx + 3] == 0x01) {

      size_t nalu_start = read_idx;
      size_t next_idx = nalu_start + 4;

      while (next_idx + 4 <= accumulator_.size()) {
        if (accumulator_[next_idx] == 0x00 && accumulator_[next_idx + 1] == 0x00 &&
            accumulator_[next_idx + 2] == 0x00 && accumulator_[next_idx + 3] == 0x01) {
          break;
        }
        next_idx++;
      }

      if (next_idx + 4 > accumulator_.size()) {
        // Wait for remaining NAL unit
        break;
      }

      DemuxedVideoPacket packet;
      packet.data.assign(accumulator_.data() + nalu_start, accumulator_.data() + next_idx);
      packet.pts = 0;
      uint8_t nal_type = packet.data[4] & 0x1F;
      packet.is_keyframe = (nal_type == kNalTypeIdr || nal_type == kNalTypeSps);

      total_packets_++;
      if (on_video_packet_) {
        on_video_packet_(packet);
      }

      read_idx = next_idx;
      continue;
    }

    // Mode A: ApowerMirror 8-byte Tag [00 00 00 00/02] followed by Annex-B [00 00 00 01]
    if (accumulator_.size() - read_idx >= 8 &&
        accumulator_[read_idx] == 0x00 && accumulator_[read_idx + 1] == 0x00 &&
        accumulator_[read_idx + 2] == 0x00 &&
        (accumulator_[read_idx + 3] == 0x00 || accumulator_[read_idx + 3] == 0x02) &&
        accumulator_[read_idx + 4] == 0x00 && accumulator_[read_idx + 5] == 0x00 &&
        accumulator_[read_idx + 6] == 0x00 && accumulator_[read_idx + 7] == 0x01) {

      read_idx += 4; // Skip 4-byte ApowerMirror slice tag
      size_t nalu_start = read_idx;
      size_t next_idx = nalu_start + 4;

      while (next_idx + 8 <= accumulator_.size()) {
        if (accumulator_[next_idx] == 0x00 && accumulator_[next_idx + 1] == 0x00 &&
            accumulator_[next_idx + 2] == 0x00 &&
            (accumulator_[next_idx + 3] == 0x00 || accumulator_[next_idx + 3] == 0x02) &&
            accumulator_[next_idx + 4] == 0x00 && accumulator_[next_idx + 5] == 0x00 &&
            accumulator_[next_idx + 6] == 0x00 && accumulator_[next_idx + 7] == 0x01) {
          break;
        }
        next_idx++;
      }

      if (next_idx + 8 > accumulator_.size()) {
        read_idx -= 4; // Revert tag skip and wait
        break;
      }

      DemuxedVideoPacket packet;
      packet.data.assign(accumulator_.data() + nalu_start, accumulator_.data() + next_idx);
      packet.pts = 0;
      uint8_t nal_type = packet.data[4] & 0x1F;
      packet.is_keyframe = (nal_type == kNalTypeIdr || nal_type == kNalTypeSps);

      total_packets_++;
      if (on_video_packet_) {
        on_video_packet_(packet);
      }

      read_idx = next_idx;
      continue;
    }

    // Unrecognized leading byte, scan forward
    read_idx++;
  }

  // Prevent runaway buffer allocation if stream desynchronizes
  if (accumulator_.size() > 4 * 1024 * 1024) {
    accumulator_.clear();
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
      packet.data = std::move(fu_assembly_buffer_);
      fu_assembly_buffer_.clear();

      if (on_video_packet_) {
        on_video_packet_(packet);
      }
    }
  }
}

}  // namespace applecast
