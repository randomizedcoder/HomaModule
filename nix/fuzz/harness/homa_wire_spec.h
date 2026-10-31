/* nix/fuzz/harness/homa_wire_spec.h
 *
 * A dependency-free (no kernel, no Wireshark) mirror of Homa's on-wire header layout, taken
 * verbatim from homa_wire.h (non-__STRIP__ variant). It lets the dissector/spec harness and
 * the differential reference side decode raw bytes and reason about per-type header lengths
 * exactly as homa_plumbing.c's header_lengths[] does. All multi-byte fields are big-endian
 * on the wire; this decoder only needs the type byte and struct sizes, so it does not byte-swap.
 *
 * Kept in lock-step with homa_wire.h by construction (same field order/sizes + a static_assert
 * on the type-byte offset).
 */
#ifndef HOMA_WIRE_SPEC_H
#define HOMA_WIRE_SPEC_H

#include <cstddef>
#include <cstdint>

namespace homa_spec {

/* enum homa_packet_type (homa_wire.h) */
enum PacketType : uint8_t {
    DATA        = 0x10,
    GRANT       = 0x11,
    RESEND      = 0x12,
    RPC_UNKNOWN = 0x13,
    BUSY        = 0x14,
    CUTOFFS     = 0x15,
    FREEZE      = 0x16,
    NEED_ACK    = 0x17,
    ACK         = 0x18,
    MIN_TYPE    = 0x10,
    MAX_TYPE    = 0x18,
};

#define HOMA_MAX_PRIORITIES 8
#define HOMA_MAX_ACKS_PER_PKT 5

#pragma pack(push, 1)

struct common_hdr {
    uint16_t sport;
    uint16_t dport;
    uint32_t sequence;
    char     ack[3];
    uint8_t  type;      /* offset 11 */
    uint8_t  doff;
    uint8_t  flags;
    uint16_t window;
    uint16_t checksum;
    uint16_t urgent;
    uint64_t sender_id;
};

struct ack_t {
    uint64_t client_id;
    uint16_t server_port;
};

struct seg_hdr { uint32_t offset; };

struct data_hdr {
    common_hdr common;
    uint32_t   message_length;
    uint32_t   incoming;
    ack_t      ack;
    uint16_t   cutoff_version;
    uint8_t    retransmit;
    char       pad[3];
    seg_hdr    seg;
};

struct grant_hdr { common_hdr common; uint32_t offset; uint8_t priority; };
struct resend_hdr { common_hdr common; uint32_t offset; uint32_t length; uint8_t priority; };
struct rpc_unknown_hdr { common_hdr common; };
struct busy_hdr { common_hdr common; };
struct cutoffs_hdr { common_hdr common; uint32_t unsched_cutoffs[HOMA_MAX_PRIORITIES]; uint16_t cutoff_version; };
struct freeze_hdr { common_hdr common; };
struct need_ack_hdr { common_hdr common; };
struct ack_hdr { common_hdr common; uint16_t num_acks; ack_t acks[HOMA_MAX_ACKS_PER_PKT]; };

#pragma pack(pop)

static_assert(offsetof(common_hdr, type) == 11, "type byte must be at offset 11");

/* Minimum header length required for each type (mirrors header_lengths[] indexed by
 * type - DATA in homa_plumbing.c). */
inline size_t header_length(uint8_t type) {
    switch (type) {
        case DATA:        return sizeof(data_hdr);
        case GRANT:       return sizeof(grant_hdr);
        case RESEND:      return sizeof(resend_hdr);
        case RPC_UNKNOWN: return sizeof(rpc_unknown_hdr);
        case BUSY:        return sizeof(busy_hdr);
        case CUTOFFS:     return sizeof(cutoffs_hdr);
        case FREEZE:      return sizeof(freeze_hdr);
        case NEED_ACK:    return sizeof(need_ack_hdr);
        case ACK:         return sizeof(ack_hdr);
        default:          return 0;
    }
}

struct Decoded {
    bool     valid_type;   /* type byte is a known Homa packet type */
    uint8_t  type;
    bool     long_enough;  /* buffer >= header_length(type) */
    size_t   need;         /* required header length for this type */
};

/* Classify a raw packet the way the kernel's early parse does: read the type byte, look up
 * the required header length, and check the buffer is long enough. */
inline Decoded classify(const uint8_t *data, size_t size) {
    Decoded d{};
    if (size <= offsetof(common_hdr, type)) {
        d.valid_type = false;
        d.type = 0;
        d.long_enough = false;
        d.need = 0;
        return d;
    }
    d.type = data[offsetof(common_hdr, type)];
    d.valid_type = (d.type >= MIN_TYPE && d.type <= MAX_TYPE);
    d.need = header_length(d.type);
    d.long_enough = d.valid_type && size >= d.need;
    return d;
}

} // namespace homa_spec

#endif /* HOMA_WIRE_SPEC_H */
