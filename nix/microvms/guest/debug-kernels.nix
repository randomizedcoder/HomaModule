# nix/microvms/guest/debug-kernels.nix
#
# The guest kernels of the sanitizer VMs: a VM kernel rebuilt with debug options on (heavy:
# each is a full kernel build).
#
#   kasan  memory errors (KASAN, KFENCE, KMEMLEAK), locking (lockdep, sleeping in atomic
#          context), undefined behaviour (UBSAN) and list corruption
#   kcsan  data races (KCSAN). It boots with KCSAN off; once homa.ko is loaded, kcsan.nix
#          limits reports to Homa's own functions and turns it on, so races elsewhere in the
#          kernel cannot fail a Homa test.
#
# Every report starts with a line that constants.oopsRegex matches ("BUG: KASAN:",
# "BUG: KCSAN:", "WARNING: possible circular locking dependency", "UBSAN:", ...), so the
# tests need no sanitizer-specific checks.
#
#   debugKernel "kasan" kernelPackages   # a kernelPackages set, as linuxPackagesFor returns

{ pkgs, lib }:

let
  configs = with lib.kernel; {
    kasan = {
      KASAN = yes;
      KASAN_GENERIC = yes;
      KASAN_INLINE = yes;
      KFENCE = yes;
      DEBUG_KMEMLEAK = yes;
      KCOV = yes;
      PROVE_LOCKING = yes;
      DEBUG_ATOMIC_SLEEP = yes;
      UBSAN = yes;
      UBSAN_BOUNDS = yes;
      UBSAN_SHIFT = yes;
      DEBUG_LIST = yes;
    };
    kcsan = {
      KCSAN = yes;
      KCSAN_EARLY_ENABLE = no;
      # KCSAN and KFENCE both watch memory accesses; nixpkgs turns KFENCE on.
      KFENCE = lib.mkForce no;
    };
  };

  # Rust is unavailable with these sanitizers, so nixpkgs' RUST = yes and the drivers that
  # need it would fail the config check ("unused option").
  noRust = with lib.kernel; {
    RUST = lib.mkForce unset;
    NOVA_CORE = lib.mkForce unset;
    DRM_NOVA = lib.mkForce unset;
    DRM_PANIC_SCREEN_QR_CODE = lib.mkForce unset;
  };
in
name: kernelPackages:
pkgs.linuxPackagesFor (kernelPackages.kernel.override {
  structuredExtraConfig = configs.${name} // noRust;
})
