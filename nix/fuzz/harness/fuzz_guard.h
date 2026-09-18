/* nix/fuzz/harness/fuzz_guard.h
 *
 * Sanitizer-independent overflow canary (adapted from the rocm-systems fuzzing design).
 * A GuardedBuffer<N> places known canary words immediately before and after an N-byte
 * buffer; Check() aborts (so libFuzzer records the input) if either canary was smashed.
 * Used by fuzz_selftest to prove the harness framework is not vacuous.
 */
#ifndef HOMA_FUZZ_GUARD_H
#define HOMA_FUZZ_GUARD_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace homa_fuzz {

static constexpr uint32_t kCanaryLo = 0xDEADBEEFu;
static constexpr uint32_t kCanaryHi = 0xCAFEBABEu;

[[noreturn]] inline void Fail(const char *why) {
    fprintf(stderr, "canary smashed: %s\n", why);
    std::abort();
}

template <size_t N>
struct GuardedBuffer {
    uint32_t lo = kCanaryLo;
    uint8_t  data[N] = {0};
    uint32_t hi = kCanaryHi;

    void Check() const {
        if (lo != kCanaryLo) Fail("underflow (lo canary)");
        if (hi != kCanaryHi) Fail("overflow (hi canary)");
    }
};

} // namespace homa_fuzz

#endif /* HOMA_FUZZ_GUARD_H */
