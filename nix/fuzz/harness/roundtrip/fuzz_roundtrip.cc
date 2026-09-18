/* roundtrip/fuzz_roundtrip.cc — Focus B: ingest + (de)serialization invariants.
 *
 * Drives fuzz bytes through the real ingest path (homa_dispatch_pkts) AND checks the wire
 * byte-order round-trip invariants that the parse/emit code relies on, using the kernel's
 * own helpers (be64_to_cpu / cpu_to_be64 / ntohs). A violation here is an endianness bug in
 * the header handling.
 *
 * Scope note: the full emit path (homa_message_out_init / homa_xmit_*) requires a complete
 * RPC+message fixture; this harness covers the ingest direction plus the byte-order helper
 * invariants that both directions depend on. Kernel-mock harness (test build env).
 */
#include "mock_harness.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* 1. Ingest: exercise the real parser. */
    homa_fuzz::dispatch_bytes(0, data, size);

    /* 2. Byte-order round-trip invariants on a sender_id drawn from the fuzz input. */
    if (size >= sizeof(struct homa_common_hdr)) {
        struct homa_common_hdr common;
        memcpy(&common, data, sizeof(common));

        /* homa_local_id(x) == be64_to_cpu(x) ^ 1, so re-encoding must reproduce x. */
        __u64 local = homa_local_id(common.sender_id);
        __be64 reencoded = cpu_to_be64(local ^ 1);
        if (reencoded != common.sender_id)
            __builtin_trap(); /* endianness/local-id round-trip violated */

        /* dport survives ntohs/htons. */
        __u16 dport = ntohs(common.dport);
        if (htons(dport) != common.dport)
            __builtin_trap();
    }
    return 0;
}
