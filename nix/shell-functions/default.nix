# nix/shell-functions/default.nix
#
# Bash helper functions spliced into the dev shell's shellHook (xdp2 pattern). Returns one
# concatenated string of function definitions.
#
# Usage in flake.nix:
#   shellFunctions = import ./nix/shell-functions { inherit pkgs lib; };

{ pkgs, lib }:

''
  # Build homa.ko against $KDIR (env-vars.nix defaults KDIR to the pinned kernel; override
  # it to retarget, e.g. KDIR=/lib/modules/$(uname -r)/build homa-build).
  homa-build() {
    make KDIR="''${KDIR}" "$@"
  }

  # Build and run the unit tests (AddressSanitizer) against $KDIR.
  homa-test() {
    make -C test KDIR="''${KDIR}" LINUX_VERSION="''${LINUX_VERSION}" ARCH="''${ARCH:-x86}" "$@" \
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

  # Quick static analysis: ruff (python), shellcheck (shebang scripts), clang-format check.
  homa-lint() {
    echo "== ruff =="
    ruff check . 2>&1 | tail -n 40 || true
    echo "== clang-format (dry-run) =="
    clang-format --dry-run --Werror homa_*.c homa_*.h 2>&1 | tail -n 40 || true
    echo "(shellcheck runs in: nix build .#analysis-quick)"
  }
''
