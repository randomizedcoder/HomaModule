/* deser/fuzz_rpc_unknown_pkt.cc — Focus A: pinned to RPC_UNKNOWN so a crash names this parser.
 * Kernel-mock harness (needs the test build environment). */
#include "mock_harness.h"
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    homa_fuzz::dispatch_bytes((uint8_t)RPC_UNKNOWN, data, size);
    return 0;
}
