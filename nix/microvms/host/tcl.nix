# nix/microvms/host/tcl.nix
#
# Packages the Tcl/Expect drivers in ../tcl (see ../tcl/README.md):
#
#   mkTclApp { name, driver, config? }  bin/<name>: runs ../tcl/bin/<driver> with config, an
#                                       attribute set written out as JSON, if it is given
#   test                                homa-tcl-test: the tcltest suite, or part of it
#   lint                                homa-tcl-lint: nagelfar, tclint, the oops regex
#   tests                               the check: lint, the suite under Tcl 8.6 (with
#                                       Expect) and the pure tables under Tcl 9.0
#
# Expect is built for Tcl 8.6 in nixpkgs, so the drivers run on 8.6; the pure code
# (parse.tcl, protocol.tcl, report.tcl) is kept Tcl 9 clean by running its tests there too.

{ pkgs, lib, oopsRegex }:

let
  tcl = pkgs.tcl;
  tcllib = pkgs.tclPackages.tcllib;

  # The package and drivers only: editing the tests or README does not change the apps.
  src = lib.fileset.toSource {
    root = ../tcl;
    fileset = lib.fileset.unions [
      ../tcl/pkgIndex.tcl
      ../tcl/parse.tcl
      ../tcl/protocol.tcl
      ../tcl/report.tcl
      ../tcl/console.tcl
      ../tcl/lc.tcl
      ../tcl/bin
    ];
  };

  testSrc = lib.fileset.toSource {
    root = ../tcl;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "tcl" || f.hasExt "test") ../tcl)
      ../tcl/tclint.toml
    ];
  };

  # Where the drivers find their packages: ours, Expect and tcllib (json).
  autoPath = [ "${src}" "${pkgs.expect}/lib" "${tcllib}/lib" ];

  # nixpkgs' nagelfar has no syntax database; its source tarball does.
  nagelfarDb = pkgs.runCommand "nagelfar-db" { } ''
    mkdir -p $out
    tar -xzf ${pkgs.nagelfar.src} --strip-components=1 -C $out \
      --wildcards '*/syntaxdb86.tcl' '*/packagedb/tcltestdb.tcl'
  '';
  # The test files that need neither Expect nor a guest, which also run on Tcl 9.0.
  pureTests = "parse.test protocol.test report.test style.test";

  # Both apps work in a writable copy of testSrc (the linters and tests write files), which
  # the shell's EXIT trap removes.
  inCopy = ''
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cp -r ${testSrc}/. "$work"
    chmod -R u+w "$work"
    cd "$work"
    export LANG=C.UTF-8
  '';

  # nix run .#homa-tcl-lint: nagelfar, tclint, and the oops regex against constants.nix.
  lint = pkgs.writeShellApplication {
    name = "homa-tcl-lint";
    runtimeInputs = [ tcl pkgs.coreutils pkgs.gnugrep pkgs.nagelfar pkgs.tclint ];
    text = ''
      ${inCopy}
      echo "== nagelfar"
      # homa.db describes our own commands and classes, generated from the loaded code.
      TCLLIBPATH="${pkgs.expect}/lib" tclsh tests/lintdb.tcl > homa.db
      nagelfar -H -s ${nagelfarDb}/syntaxdb86.tcl -s ${nagelfarDb}/packagedb/tcltestdb.tcl -s homa.db \
        pkgIndex.tcl parse.tcl protocol.tcl report.tcl console.tcl lc.tcl bin/*.tcl tests/*.tcl tests/*.test | tee nagelfar.out
      if grep -E '^[^:]+: (Line +)?[0-9]+: [EW] ' nagelfar.out; then exit 1; fi

      echo "== tclint"
      tclint .

      echo "== parse.tcl's oops regex is constants.oopsRegex"
      tclsh <<'EOF'
      source parse.tcl
      if {$homa::lc::parse::oopsRe ne {${oopsRegex}}} {
          puts "parse.tcl: oopsRe is $homa::lc::parse::oopsRe, constants.nix has {${oopsRegex}}"
          exit 1
      }
      EOF
    '';
  };

  # nix run .#homa-tcl-test -- [--tcl9] [tcltest options]: the suite on Tcl 8.6 with Expect,
  # or with --tcl9 on Tcl 9.0, where only the pure files can run (they are the default
  # there). The options go to tests/all.tcl, e.g. -file wait.test, -match 'waitFor-*'.
  test = pkgs.writeShellApplication {
    name = "homa-tcl-test";
    runtimeInputs = [ pkgs.bash pkgs.coreutils ];
    text = ''
      tclsh=${tcl}/bin/tclsh
      export TCLLIBPATH=${pkgs.expect}/lib
      if [[ ''${1-} == --tcl9 ]]; then
        shift
        tclsh=${pkgs.tcl-9_0}/bin/tclsh
        unset TCLLIBPATH
        if [[ " $* " != *" -file "* ]]; then
          set -- -file "${pureTests}" "$@"
        fi
      fi
      ${inCopy}
      rc=0
      "$tclsh" tests/all.tcl "$@" || rc=$?
      exit "$rc"
    '';
  };
in
{
  inherit src lint test;

  # Without a config, the driver gets only the command line's arguments.
  mkTclApp = { name, driver, config ? null }:
    let
      configFile = pkgs.writeText "${name}.json" (builtins.toJSON config);
      configArg = lib.optionalString (config != null) configFile;
    in
    pkgs.writeTextFile {
      inherit name;
      executable = true;
      destination = "/bin/${name}";
      text = ''
        #!${tcl}/bin/tclsh
        # ${name}: runs ${driver} (nix/microvms/tcl/bin)${lib.optionalString (config != null) " with ${configFile}"}.
        set env(PATH) ${lib.makeBinPath [ pkgs.coreutils ]}:$env(PATH)
        set auto_path [list ${lib.concatStringsSep " " autoPath} {*}$auto_path]
        package require homa::lc
        set argv [list ${configArg} {*}$argv]
        homa::lc::utf8 stdout
        source ${src}/bin/${driver}
      '';
      checkPhase = ''
        ${tcl}/bin/tclsh <<'EOF'
        set auto_path [list ${lib.concatStringsSep " " autoPath} {*}$auto_path]
        package require homa::lc
        package require json
        if {![info complete [read [open ${src}/bin/${driver}]]]} {
            error "${driver}: incomplete script"
        }
        EOF
      '';
      meta.mainProgram = name;
    };

  # The check: everything the two apps do, with their defaults.
  tests = pkgs.runCommand "homa-tcl-tests" { nativeBuildInputs = [ lint test ]; } ''
    homa-tcl-lint
    echo "== tests, Tcl 8.6 with Expect"
    homa-tcl-test
    echo "== pure tests, Tcl 9.0"
    homa-tcl-test --tcl9
    touch $out
  '';
}
