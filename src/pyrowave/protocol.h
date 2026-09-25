/**
 * @file src/pyrowave/protocol.h
 * @brief Versioned Prism/Iris PyroWave framing, independent of graphics APIs.
 */
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace prism_pyrowave {
  constexpr int version = 1;  ///< Prism/Iris protocol version (independent of the upstream API).
  constexpr int video_format = 3;  ///< RTSP bitStreamFormat reserved for this negotiated extension.
  constexpr uint32_t format_sdr420 = 0x10000;  ///< Native client format for SDR 4:2:0.
  constexpr uint32_t format_hdr420 = 0x20000;  ///< Native client format for HDR 4:2:0.
  constexpr uint32_t format_sdr444 = 0x40000;  ///< Native client format for SDR 4:4:4.
  constexpr uint32_t format_hdr444 = 0x80000;  ///< Native client format for HDR 4:4:4.
  constexpr uint32_t format_mask = 0xf0000;  ///< All native PyroWave formats.
  constexpr uint32_t server_mask = 0x0f000000;  ///< Corresponding server capability bits, native format shifted by eight.
  constexpr size_t maximum_frame_size = 4 * 1024 * 1024;  ///< Absolute allocation bound for untrusted frame envelopes.
  constexpr size_t packet_boundary = 65536;  ///< Maximum upstream packet size within an envelope.
  constexpr size_t header_size = 12;  ///< Magic, version, mode flags, reserved bytes, and packet count.
  constexpr size_t maximum_block_size = 0xfff * 4;  ///< Largest upstream block; its length is a 12-bit word count.

  /**
   * @brief A borrowed upstream packet inside a validated frame envelope.
   */
  struct packet_view {
    const uint8_t *data;  ///< First packet byte.
    size_t size;  ///< Packet length.
  };

  /**
   * @brief Read an unaligned little-endian integer.
   * @param p Four readable bytes.
   * @return Decoded unsigned integer.
   */
  inline uint32_t read_u32(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
  }

  /**
   * @brief Append a little-endian integer without alignment assumptions.
   * @param bytes Destination byte vector.
   * @param value Integer to append.
   */
  inline void append_u32(std::vector<uint8_t> &bytes, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) {
      bytes.push_back(uint8_t(value >> (i * 8)));
    }
  }

  /**
   * @brief Validate a complete envelope before submitting any packets to the GPU decoder.
   * @param data Untrusted frame bytes.
   * @param size Number of readable bytes.
   * @param mode Negotiated flags: bit zero HDR, bit one 4:4:4.
   * @return Borrowed packets, or an empty vector for an invalid envelope.
   */
  inline std::vector<packet_view> unpack(const uint8_t *data, size_t size, uint8_t mode) {
    if (!data || size < header_size || size > maximum_frame_size || mode > 3 ||
        read_u32(data) != 0x31575250 || data[4] != version || data[5] != mode || data[6] || data[7]) {
      return {};
    }
    const auto count = read_u32(data + 8);
    if (!count || count > (size - header_size) / 12) {
      return {};
    }
    std::vector<packet_view> result;
    result.reserve(count);
    size_t offset = header_size;
    for (uint32_t i = 0; i < count; ++i) {
      if (size - offset < 4) {
        return {};
      }
      auto length = read_u32(data + offset);
      offset += 4;
      if (length < 8 || length > packet_boundary || length % 4 || length > size - offset) {
        return {};
      }
      result.push_back({data + offset, length});
      offset += length;
    }
    return offset == size ? result : std::vector<packet_view> {};
  }

  /**
   * @brief Frame upstream packets for the existing encrypted, complete-frame transport.
   * @param packets Valid upstream packets in transmission order.
   * @param mode Negotiated HDR and chroma flags.
   * @return Encoded envelope.
   * @throws std::invalid_argument If packets violate protocol limits.
   */
  inline std::vector<uint8_t> pack(const std::vector<packet_view> &packets, uint8_t mode) {
    if (packets.empty() || packets.size() > maximum_frame_size / 12 || mode > 3) {
      throw std::invalid_argument("Invalid PyroWave packet count or mode");
    }
    std::vector<uint8_t> result {'P', 'R', 'W', '1', version, mode, 0, 0};
    append_u32(result, uint32_t(packets.size()));
    for (const auto &packet : packets) {
      if (!packet.data || packet.size < 8 || packet.size > packet_boundary || packet.size % 4 ||
          result.size() + 4 + packet.size > maximum_frame_size) {
        throw std::invalid_argument("Invalid PyroWave packet length");
      }
      append_u32(result, uint32_t(packet.size));
      result.insert(result.end(), packet.data, packet.data + packet.size);
    }
    return result;
  }

  /**
   * @brief Validate a requested color/chroma mode and representable dimensions.
   * @param width Luma width.
   * @param height Luma height.
   * @param hdr HDR flag, zero or one.
   * @param chroma Chroma flag, zero or one.
   * @return True for a supported stream description.
   */
  inline bool valid_mode(int width, int height, int hdr, int chroma) {
    return width > 0 && height > 0 && width <= 16384 && height <= 16384 &&
           hdr >= 0 && hdr <= 1 && chroma >= 0 && chroma <= 1 &&
           (chroma || !((width | height) & 1));
  }

  /**
   * @brief Resolve actual frame rate without overflowing an untrusted integer.
   * @param fps Integer frame rate.
   * @param fractional Optional frame rate multiplied by 100.
   * @return Effective rate multiplied by 100, or zero for invalid values.
   */
  inline int effective_fps(int fps, int fractional) {
    if (fractional > 0) {
      return fractional;
    }
    return fps > 0 && fps <= std::numeric_limits<int>::max() / 100 ? fps * 100 : 0;
  }

  /**
   * @brief Validate upstream block framing before entering the codec parser.
   * @param packets Validated envelope packet spans.
   * @param width Negotiated luma width.
   * @param height Negotiated luma height.
   * @param mode Negotiated HDR/chroma flags; color interpretation comes from the envelope.
   * @return True for one frame with consistent sequence, dimensions, and forward-progressing blocks.
   */
  inline bool validate_bitstream(const std::vector<packet_view> &packets, int width, int height, uint8_t mode) {
    if (mode > 3 || !valid_mode(width, height, mode & 1, mode >> 1)) {
      return false;
    }
    int sequence = -1;
    bool header_seen = false;
    for (const auto &packet : packets) {
      if (!packet.data || packet.size < 8 || packet.size > packet_boundary) {
        return false;
      }
      size_t offset = 0;
      while (packet.size - offset >= 8) {
        uint32_t first = read_u32(packet.data + offset);
        uint32_t second = read_u32(packet.data + offset + 4);
        int current_sequence = (first >> 28) & 7;
        if (sequence != -1 && sequence != current_sequence) {
          return false;
        }
        sequence = current_sequence;
        size_t bytes = 8;
        if (first & 0x80000000u) {
          if (int((first & 0x3fff) + 1) != width || int(((first >> 14) & 0x3fff) + 1) != height ||
              ((second >> 24) & 3) || ((second >> 26) & 1) != (mode >> 1)) {
            return false;
          }
          header_seen = true;
        } else {
          bytes = ((first >> 16) & 0xfff) * 4;
          if (bytes < 8 || bytes > packet.size - offset) {
            return false;
          }
        }
        offset += bytes;
      }
      if (offset != packet.size) {
        return false;
      }
    }
    return header_seen;
  }

  /**
   * @brief Bound the envelope carrying an upstream bitstream of a given size.
   *
   * Upstream packetization starts a new packet only when the next block would cross the packet
   * boundary, so every packet except the last holds more than `packet_boundary - maximum_block_size`
   * bytes. Each packet adds one length word to the envelope.
   *
   * @param bitstream Upstream bitstream bytes, including its sequence header.
   * @return Largest possible envelope size in bytes.
   */
  constexpr uint64_t envelope_bound(uint64_t bitstream) {
    return header_size + bitstream + 4 * (bitstream / (packet_boundary - maximum_block_size + 1) + 1);
  }

  /**
   * @brief Bound an adaptive frame budget by the negotiated transport and envelope capacity.
   * @param packet_size GameStream packet size including its 16-byte video header.
   * @param fec_percent Negotiated parity percentage.
   * @return Conservative four-byte-aligned bitstream capacity, or zero for invalid settings.
   */
  inline size_t transport_frame_budget(int packet_size, int fec_percent) {
    if (packet_size < 256 || packet_size > 65500 || fec_percent < 0 || fec_percent > 100) {
      return 0;
    }
    const uint64_t shards = 4 * (255 * 100 / (100 + fec_percent));
    // The eight bytes reserved here are the video frame header prepended by the transport.
    const uint64_t capacity = std::min<uint64_t>(shards * uint64_t(packet_size - 16) - 8, maximum_frame_size);
    // Envelope overhead grows with the bitstream, so the overhead of the whole capacity bounds it.
    return size_t(capacity - (envelope_bound(capacity) - capacity)) & ~size_t(3);
  }

  /**
   * @brief Compute the initial encoder budget, limited to what four existing FEC blocks carry.
   * @param bitrate_kbps Codec bitrate after transport overhead adjustments.
   * @param fps_x100 Actual stream frame rate multiplied by 100.
   * @param packet_size Negotiated GameStream packet size, including its 16-byte video header.
   * @param fec_percent Requested Reed-Solomon parity percentage.
   * @return Upstream bitstream bytes per frame, clamped to the transport ceiling, or zero for unsupported settings.
   */
  inline size_t frame_budget(int bitrate_kbps, int fps_x100, int packet_size, int fec_percent) {
    if (bitrate_kbps <= 0 || fps_x100 <= 0) {
      return 0;
    }
    const uint64_t budget = uint64_t(bitrate_kbps) * 12500 / uint64_t(fps_x100);
    const size_t limit = transport_frame_budget(packet_size, fec_percent);
    if (budget < 4096 || !limit) {
      return 0;
    }
    return size_t(std::min<uint64_t>(budget, limit));
  }
}  // namespace prism_pyrowave
