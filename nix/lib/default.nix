# nix/lib/default.nix
#
# homaLib: what the module, userspace, analysis and fuzz builds share (see README.md).
#
#   version, meta    for every Homa derivation. The version leaves out the git revision
#                    (rev, kept here too): with it, every commit would rebuild everything,
#                    even one that only edits a README.
#   src.<subset>     Homa's source cut down to what one kind of build reads, with the
#                    patches in ../patches applied:
#                      module   the top-level C sources, Makefiles and Kconfig
#                      util     + util/
#                      test     + util/ and test/
#                      fuzz     + util/, test/ and nix/fuzz/
#                      all      the whole tree (the linters scan everything)
#                    So editing a README, or anything under nix/, does not rebuild homa.ko.
#   mkKbuild         a derivation that runs Homa's Makefile (kbuild) against a kernel tree
#   perKernel        { "<prefix>-<series>" = f series value; } for a set keyed by series

{ pkgs, lib, rev }:

let
  root = ../..;

  # Top-level files only: Homa's sources sit at the root next to its subdirectories.
  topLevel = lib.fileset.unions (map (name: root + "/${name}") (lib.attrNames
    (lib.filterAttrs
      (name: type: type == "regular"
        && (lib.any (ext: lib.hasSuffix ext name) [ ".c" ".h" ".cc" ]
        || lib.elem name [ "Makefile" "Makefile.upstream" "Kconfig" ]))
      (builtins.readDir root))));

  # A patch touches Homa's C sources: the top level, test/ and util/. Each subset gets the
  # parts of each patch that are inside it (filterdiff), so a fix that also adds a unit test
  # still applies to the module's source.
  patches = import ../patches;
  patchDirs = [ "test" "util" ];
  patchFor = dirs: patch: pkgs.runCommand "${baseNameOf patch}"
    { nativeBuildInputs = [ pkgs.patchutils ]; } ''
    filterdiff -p1 ${lib.concatMapStringsSep " " (d: "-x '${d}/*'")
      (lib.subtractLists dirs patchDirs)} ${patch} > $out
  '';

  subset = name: dirs: fileset: pkgs.applyPatches {
    name = "homa-src-${name}";
    src = lib.fileset.toSource { inherit root fileset; };
    patches = map (patchFor dirs) patches;
  };
  # A directory without its Markdown files: no build reads them.
  dirNoDocs = d: lib.fileset.difference (root + "/${d}")
    (lib.fileset.fileFilter (f: f.hasExt "md") (root + "/${d}"));
  withDirs = name: dirs: subset name dirs
    (lib.fileset.unions ([ topLevel ] ++ map dirNoDocs dirs));

  version = "0-unstable";
  src = {
    module = withDirs "module" [ ];
    util = withDirs "util" [ "util" ];
    test = withDirs "test" [ "test" "util" ];
    fuzz = withDirs "fuzz" [ "test" "util" "nix/fuzz" ];
    all = subset "all" patchDirs root;
  };
in
{
  inherit version src rev;

  meta = {
    homepage = "https://github.com/PlatformLab/HomaModule";
    license = lib.licenses.bsd2;
    platforms = lib.platforms.linux;
  };

  # mkKbuild { pname, kdir, ... }: runs `make` in Homa's module source with KDIR=kdir
  # (when given) and MY_CFLAGS=-O2. Any other attribute goes to mkDerivation; makeFlags and
  # nativeBuildInputs are appended to, the rest replace these defaults.
  mkKbuild = { kdir ? null, makeFlags ? [ ], nativeBuildInputs ? [ ], ... }@args:
    pkgs.stdenv.mkDerivation ({
      inherit version;
      src = src.module;
      dontConfigure = true;
      # The cc-wrapper's hardening flags clash with kbuild's own.
      hardeningDisable = [ "all" ];
      # Through the environment, not makeFlags: stdenv word-splits makeFlags, which would
      # turn a debug build's "-g -O1" into make's own -O option.
      env.MY_CFLAGS = "-O2";
    } // removeAttrs args [ "kdir" ] // {
      nativeBuildInputs = [ pkgs.gnumake ] ++ nativeBuildInputs;
      makeFlags = lib.optional (kdir != null) "KDIR=${kdir}" ++ makeFlags;
    });

  perKernel = prefix: f: lib.mapAttrs' (series: value:
    lib.nameValuePair "${prefix}-${series}" (f series value));
}
