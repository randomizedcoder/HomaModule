# nix/dev/shell-functions/default.nix
#
# Bash helper functions spliced into the dev shell's shellHook (xdp2 pattern). Returns one
# concatenated string of function definitions.
#
# In the scope (nix/scope.nix) as shellFunctions; dev/shell.nix puts it in the shellHook.

{}:

''
  # Build homa.ko against $KDIR (env-vars.nix defaults KDIR to the pinned kernel; override
  # it to retarget, e.g. KDIR=/lib/modules/$(uname -r)/build homa-build).
  homa-build() {
    make KDIR="''${KDIR}" "$@"
  }

  # Build and run the unit tests (AddressSanitizer) against $KDIR.
  homa-test() {
    make -C test KDIR="''${KDIR}" LINUX_VERSION="''${LINUX_VERSION}" ARCH="''${ARCH}" "$@" \
      && ./test/unit
  }

  homa-clean() {
    make clean 2>/dev/null || true
    make -C test clean 2>/dev/null || true
    make -C util clean 2>/dev/null || true
  }

  # Kernel checkpatch (needs a Linux source tree; set LINUX_SRC_DIR).
  homa-checkpatch() {
    make checkpatch "$@"
  }
''
