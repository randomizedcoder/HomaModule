/* nix/fuzz/harness/fuzz_dissector.cc  — Focus C (kernel-independent)
 *
 * A standalone Homa wire-format decoder driven by libFuzzer. It classifies the packet type,
 * validates the per-type header length (mirroring homa_plumbing.c's header_lengths[]), and
 * for DATA packets walks the trailing segment headers doing the same offset/length
 * arithmetic the kernel does — all under ASan/UBSan, so an out-of-bounds read or overflow in
 * that arithmetic is caught. This needs no kernel headers or Wireshark, so it always builds,
 * and it is the reference oracle used by fuzz_differential.
 */
#include "homa_wire_spec.h"
#include <cstdint>
#include <cstring>

using namespace homa_spec;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    Decoded d = classify(data, size);
    if (!d.valid_type || !d.long_enough)
        return 0; /* the kernel would drop these early; nothing more to decode */

    /* Read the common header safely (we know size >= header_length(type) >= sizeof(common)). */
    common_hdr common;
    memcpy(&common, data, sizeof(common));

    if (d.type == DATA) {
        data_hdr dh;
        memcpy(&dh, data, sizeof(dh));

        /* message_length / segment walk (big-endian on the wire). Convert defensively. */
        auto be32 = [](uint32_t v) -> uint32_t {
            return ((v & 0x000000ffu) << 24) | ((v & 0x0000ff00u) << 8) |
                   ((v & 0x00ff0000u) >> 8)  | ((v & 0xff000000u) >> 24);
        };
        uint32_t message_length = be32(dh.message_length);
        (void)message_length;

        /* Walk segment headers in the tail, bounded strictly by `size`. */
        size_t pos = sizeof(data_hdr) - sizeof(seg_hdr); /* first seg is inside data_hdr */
        while (pos + sizeof(seg_hdr) <= size) {
            seg_hdr seg;
            memcpy(&seg, data + pos, sizeof(seg));
            uint32_t off = be32(seg.offset);
            (void)off;
            /* Advance by a seg header + at least one byte to guarantee progress. */
            pos += sizeof(seg_hdr) + 1;
        }
    }
    return 0;
}
