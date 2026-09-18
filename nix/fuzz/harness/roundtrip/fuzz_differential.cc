/* roundtrip/fuzz_differential.cc — Focus B: spec-vs-kernel differential oracle.
 *
 * The same bytes are classified by the dependency-free spec decoder (homa_wire_spec.h) and
 * driven through the real kernel ingest path (homa_dispatch_pkts). The oracle: the kernel
 * must handle every input safely (no ASan/UBSan violation), including packets the spec marks
 * malformed / too-short for their type — those are exactly the boundary cases that expose
 * missing length checks. A divergence surfaces as a sanitizer crash on a spec-flagged input.
 *
 * Kernel-mock harness (test build env).
 */
#include "homa_wire_spec.h"
#include "mock_harness.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    homa_spec::Decoded d = homa_spec::classify(data, size);

    /* Cross-check: the spec's type-byte read must match the kernel struct's type offset. */
    if (size > offsetof(struct homa_common_hdr, type)) {
        uint8_t kernel_type = data[offsetof(struct homa_common_hdr, type)];
        if (d.type != kernel_type)
            __builtin_trap(); /* spec and kernel disagree on where the type byte is */
    }

    /* Drive the real parser on the same bytes; ASan/UBSan is the crash detector. The
     * interesting inputs are those the spec marks not-long-enough for their type. */
    homa_fuzz::dispatch_bytes(0, data, size);
    return 0;
}
