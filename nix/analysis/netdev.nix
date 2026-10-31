# nix/analysis/netdev.nix
#
# The checks a Homa patch series meets on netdev, run on the code as it is submitted: the
# upstream-shaped source that `make net-next` writes (util/strip.py), inside a real kernel
# tree (the default kernel's), with net/Kconfig and net/Makefile wired as an upstream patch
# would. Each check is one mkAnalysisTool report:
#
#   checkpatch   scripts/checkpatch.pl --file --strict --codespell, the flags of Homa's own
#                `make checkpatch-net-next`
#   kdoc         scripts/kernel-doc -none -Wall
#   gcc-w1       an in-tree x86_64 build of net/homa with W=1, and sparse (C=1)
#   clang-w1     the same with LLVM=1
#   i386-w1      a 32-bit build (ARCH=i386) with W=1: 64-bit divisions, pointer casts, ...
#
# A build check fails (rather than reporting zero findings) if kbuild never compiled a
# net/homa file.

{ pkgs
, lib
, homaLib
, kernelConfig
, mkAnalysisTool
}:

let
  kernel = kernelConfig.kernelPackages.kernel;

  # The kernel source with Homa's stripped files in net/homa and include/uapi/linux/homa.h.
  tree = pkgs.runCommand "homa-netdev-tree-${kernel.version}"
    { nativeBuildInputs = with pkgs; [ gnumake perl python3 ]; } ''
    mkdir "$out"
    tar xf ${kernel.src} -C "$out" --strip-components=1
    patchShebangs "$out/scripts"
    cp -r ${homaLib.src.util} homa && chmod -R +w homa
    patchShebangs homa/util/strip.py
    make -C homa net-next LINUX_SRC_DIR="$out"
    sed -i '/^source "net\/sctp\/Kconfig"/a source "net/homa/Kconfig"' "$out/net/Kconfig"
    echo 'obj-$(CONFIG_HOMA) += homa/' >> "$out/net/Makefile"
    grep -q 'net/homa/Kconfig' "$out/net/Kconfig"
  '';

  # Relative to the tree, where each check runs, so its report shows short paths.
  homaFiles = "net/homa/*.[ch] include/uapi/linux/homa.h";

  checkpatch = mkAnalysisTool {
    name = "netdev-checkpatch";
    tools = [ pkgs.perl pkgs.codespell ];
    script = ''
      dict=$(find ${pkgs.codespell} -name dictionary.txt -path '*codespell_lib/data/*' | head -n 1)
      {
        echo "# checkpatch.pl --file --strict --codespell (net/homa as submitted)"
        cd ${tree}
        scripts/checkpatch.pl --file --strict --codespell \
          --codespellfile "$dict" --color=never ${homaFiles} 2>&1 || true
      } > "$out/report.txt"
    '';
    count = "^(ERROR|WARNING|CHECK):";
  };

  kdoc = mkAnalysisTool {
    name = "netdev-kdoc";
    tools = [ pkgs.perl pkgs.python3 ];
    script = ''
      cd ${tree}
      # -none prints nothing for clean files, so first check that it parses Homa's at all.
      python3 scripts/kernel-doc -rst net/homa/homa_rpc.c | grep -q homa_rpc_alloc_server \
        || { echo "kernel-doc found no documentation in net/homa/homa_rpc.c"; exit 1; }
      {
        echo "# kernel-doc -none -Wall (net/homa as submitted)"
        # It prints some warnings twice (once per pass); keep the first.
        python3 scripts/kernel-doc -none -Wall ${homaFiles} 2>&1 | awk '!seen[$0]++' || true
      } > "$out/report.txt"
    '';
    count = "^(Warning|warning|error)";
  };

  # An in-tree build of net/homa: defconfig, HOMA=m, then the directory alone.
  inTreeBuild = { name, makeFlags ? "", defconfig ? "defconfig", tools ? [ ] }: mkAnalysisTool {
    inherit name;
    kbuild = true;
    tools = with pkgs; [ bc bison flex perl python3 openssl elfutils ] ++ tools;
    script = ''
      mk() { make -C ${tree} O="$PWD/build" ${makeFlags} "$@"; }
      mk ${defconfig} > config.log 2>&1
      ${tree}/scripts/config --file build/.config -e IPV6 -m HOMA
      mk olddefconfig >> config.log 2>&1
      grep -q '^CONFIG_HOMA=m' build/.config || { cat config.log; echo "HOMA not enabled"; exit 1; }
      # -k: a file that fails to compile must not hide the other files' warnings.
      mk -k -j"$NIX_BUILD_CORES" W=1 net/homa/ > build.log 2>&1 || echo "make failed" >> build.log
      {
        echo "# make W=1 ${makeFlags} net/homa/ (${defconfig})"
        grep -E 'net/homa/|include/uapi/linux/homa\.h|make failed' build.log \
          | grep -vE '^ +(CC|CHECK) |\*\*\*|not remade' | sed "s|${tree}/||g" || true
      } > "$out/report.txt"
      if ! grep -qE '^ +CC +\[?M?\]? *net/homa/' build.log; then
        tail -n 40 build.log
        echo "${name}: kbuild never compiled net/homa"
        exit 1
      fi
    '';
    count = "(warning|error):|make failed";
  };

  gcc-w1 = inTreeBuild {
    name = "netdev-gcc-w1";
    makeFlags = "C=1 CHECK=${pkgs.sparse}/bin/sparse";
    tools = [ pkgs.sparse ];
  };
  clang-w1 = inTreeBuild {
    name = "netdev-clang-w1";
    # The kernel passes its own --target, which nixpkgs' clang wrapper does not allow; host
    # tools still use the wrapped clang (LLVM=1 sets HOSTCC=clang).
    makeFlags = "LLVM=1 CC=${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
    tools = with pkgs; [ clang lld llvm ];
  };
  i386-w1 = inTreeBuild {
    name = "netdev-i386-w1";
    makeFlags = "ARCH=i386";
    defconfig = "i386_defconfig";
  };
in
{
  inherit tree checkpatch kdoc gcc-w1 clang-w1 i386-w1;
}
