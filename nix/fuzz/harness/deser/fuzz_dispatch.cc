/* deser/fuzz_dispatch.cc — Focus A: whole-packet entry.
 * Feeds fuzz bytes (including the type byte) through homa_dispatch_pkts(), the top-level
 * deserialization dispatcher in homa_incoming.c. Kernel-mock harness (needs the test build
 * environment). */
#include "mock_harness.h"
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    homa_fuzz::dispatch_bytes(0 /* type from input */, data, size);
    return 0;
}
