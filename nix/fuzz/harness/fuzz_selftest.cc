/* nix/fuzz/harness/fuzz_selftest.cc
 *
 * A deliberately fixed-size copy loop guarded by fuzz_guard.h. This harness is
 * self-contained (no kernel/mock/Wireshark deps) so it ALWAYS builds — it exists to prove
 * the libFuzzer + sanitizer toolchain and the canary net actually catch an overflow.
 *
 * The `nix build .#fuzz-selftest` gate injects a regression (widening the copy past the
 * buffer) and asserts this harness aborts. In its shipped form the bound is correct, so a
 * normal fuzz run finds nothing.
 */
#include "fuzz_guard.h"
#include <cstddef>
#include <cstdint>

/* SELFTEST_COPY_LEN is the number of bytes copied into an 8-byte buffer. Shipped value (8)
 * is safe; the selftest gate rewrites it larger to confirm the canary fires. */
#ifndef SELFTEST_COPY_LEN
#define SELFTEST_COPY_LEN 8
#endif

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    homa_fuzz::GuardedBuffer<8> buf;
    size_t n = size < (size_t)SELFTEST_COPY_LEN ? size : (size_t)SELFTEST_COPY_LEN;
    /* Intentionally copy up to SELFTEST_COPY_LEN bytes; if the gate widens that past 8 it
     * overruns buf.data and smashes buf.hi. */
    for (size_t i = 0; i < n; i++)
        buf.data[i] = data[i];
    buf.Check();
    return 0;
}
