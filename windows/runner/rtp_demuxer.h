#ifndef RUNNER_RTP_DEMUXER_H_
#define RUNNER_RTP_DEMUXER_H_

#include <cstdint>
#include <vector>
#include <functional>
#include <memory>
#include <map>

namespace applecast {

constexpr uint8_t kRtpInterleavedMagic = 0x24; // '$'
constexpr uint8_t kRtpChannelVideo     = 0x00;
constexpr uint8_t kRtpChannelControl   = 0x01;
constexpr size_t  kRtpHeaderSize       = 12;

/// Standard Demuxed Video Packet ready for FFmpeg / D3D11VA hardware decode.
struct DemuxedVideoPacket {
  std::vector<uint8_t> data;   // Annex B formatted stream with 0x00000001 start codes
  uint32_t pts = 0;            // 90 kHz RTP Presentation Timestamp
  uint16_t seq = 0;            // RTP Sequence number for loss detection
  bool is_keyframe = false;    // IDR frame (Type 5 in H.264)
  bool is_marker = false;      // RTP marker bit (indicates end of frame access unit)
};

using VideoPacketCallback = std::function<void(const DemuxedVideoPacket& packet)>;

/// Architecture Blueprint: Module 2 - Protocol Parser & Packet Demuxer
/// Implements RFC 2326 Interleaved Stream state machine & RTP H.264/HEVC NAL demuxing.
class RtpDemuxer {
 public:
  explicit RtpDemuxer(VideoPacketCallback on_video_packet);
  ~RtpDemuxer();

  // Feeds raw incoming bytes received from the usbmuxd tunnel TCP socket into the demuxer.
  void ConsumeData(const uint8_t* buffer, size_t length);

  // Resets internal state machine, ring buffers, and sequence trackers.
  void Reset();

  // Returns total packets processed and dropped.
  uint64_t total_packets() const { return total_packets_; }
  uint64_t dropped_packets() const { return dropped_packets_; }

 private:
  enum State {
    STATE_FIND_MAGIC,
    STATE_READ_HEADER,
    STATE_READ_PAYLOAD,
  };

  void ProcessInterleavedPayload(uint8_t channel, const uint8_t* payload, size_t length);
  void ProcessRtpVideoPayload(const uint8_t* payload, size_t length);
  void ProcessH264Payload(const uint8_t* rtp_payload, size_t payload_len, uint32_t pts, uint16_t seq, bool marker);

  // NAL Unit formatting utilities
  void AppendAnnexBStartCode(std::vector<uint8_t>& out);
  void CacheParameterSets(uint8_t nal_type, const uint8_t* nal_data, size_t nal_len);

  VideoPacketCallback on_video_packet_;

  State state_ = STATE_FIND_MAGIC;
  std::vector<uint8_t> accumulator_;
  uint8_t current_channel_ = 0;
  uint16_t current_payload_length_ = 0;

  // RTP Sequence tracking
  bool has_initial_seq_ = false;
  uint16_t last_seq_ = 0;
  uint64_t total_packets_ = 0;
  uint64_t dropped_packets_ = 0;

  // Parameter Sets Cache (SPS / PPS / VPS)
  std::vector<uint8_t> cached_sps_;
  std::vector<uint8_t> cached_pps_;
  std::vector<uint8_t> cached_vps_;

  // FU-A Fragment Assembly Buffer
  std::vector<uint8_t> fu_assembly_buffer_;
  bool fu_in_progress_ = false;
};

}  // namespace applecast

#endif  // RUNNER_RTP_DEMUXER_H_
