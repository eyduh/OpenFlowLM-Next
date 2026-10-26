# Shared toolchain environment for open NPU kernel builds.
# Used by both the package derivation (open-kernels.nix) and the dev shell.
{
  lib,
  stdenv,
  fetchurl,
  python312,
  python312Packages,
  pkgs ? null,
  xrt ? pkgs.xrt,
  xrt-combined ? pkgs.xrt-combined,
  git,
  makeWrapper,
  unzip,
  zlib,
  patchelf,
}:

let
  pyVersion = "3.12";
  pySite = "lib/python${pyVersion}/site-packages";

  mlirAieWheel = fetchurl {
    url = "https://github.com/Xilinx/mlir-aie/releases/download/v1.4.3/mlir_aie-1.4.3-cp312-cp312-manylinux_2_35_x86_64.whl";
    sha256 = "sha256-TYwjpbYXHdEWLHjFYPCkjK1llpC1vlMNUWZrf/9ScoE=";
  };

  llvmAieWheel = fetchurl {
    url = "https://github.com/Xilinx/llvm-aie/releases/download/nightly/llvm_aie-22.0.0.2026092301%2B02be6fd8-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
    sha256 = "sha256-bi0uvoa/Z12aGcIhzUMCMtMUw5EEiUTeP8QVB5JANK4=";
  };

  pyDeps = with python312Packages; [
    aiofiles
    cloudpickle
    mdurl
    ml-dtypes
    numpy
    pygments
    rich
  ];

  # Runtime / native tools needed by both the package build and the dev shell.
  nativeTools = [ git makeWrapper python312 unzip patchelf ];
  # Dense kernel builds only call xclbinutil, so they only need plain xrt.
  # The BERT embedding sets need pyxrt and NPU access; xrt-combined (XRT +
  # amdxdna plugin) is provided for those cases via the env below.
  runtimeLibs = [ stdenv.cc.cc.lib zlib xrt ];

  ironvenv = stdenv.mkDerivation {
    pname = "openflowlm-ironvenv";
    version = "1.4.3-20260923";

    nativeBuildInputs = [ python312 unzip patchelf ];
    src = ./.;
    dontUnpack = true;
    # We patchelf the wheel binaries ourselves (executables + shared libs) to
    # keep the manylinux RUNPATH entries (e.g. $ORIGIN/../lib) and add the
    # C++ runtime / zlib.  Nix's default patchELF would run
    # patchelf --shrink-rpath afterwards and strip the zlib path because the
    # binaries do not directly declare libz.so.1 as NEEDED.  Stripping the
    # ELF files can also corrupt the GNU version sections these manylinux
    # wheels rely on, producing "no version information available" at load
    # time.
    dontPatchELF = true;
    dontStrip = true;

    installPhase = ''
      ${python312}/bin/python -m venv $out
      export SITE="$out/${pySite}"

      ${unzip}/bin/unzip -q -d "$SITE" ${mlirAieWheel}
      ${unzip}/bin/unzip -q -d "$SITE" ${llvmAieWheel}

      # Link nixpkgs Python deps into the venv so imports resolve without
      # re-installing them or relying on .pth files.
      ${lib.concatStringsSep "\n" (map (pkg: "ln -s ${pkg}/${pySite}/* \"$SITE/\"") pyDeps)}

      # The wheel drops the aie package under mlir_aie/python; make it
      # importable without relying on aie.pth.
      ln -s "$SITE/mlir_aie/python/aie" "$SITE/aie"

      # The manylinux llvm-aie/mlir-aie wheels ship x86_64 executables that
      # hard-code /lib64/ld-linux-x86-64.so.2.  In the Nix sandbox /lib64 is
      # unavailable, so patch the interpreter and add the C++ runtime + zlib
      # to their RUNPATH without destroying the wheel's own library search
      # paths (e.g. mlir_aie.libs/libcrypto-...so.3).  The shared libraries
      # (libLLVM.so, libclang-cpp.so, ...) must be patched too, because they
      # need libstdc++/libz and only see the main executable's RUNPATH when
      # loaded as dependencies.  Doing this once in the venv derivation means
      # materialized copies are already usable.
      for dir in "$SITE/llvm-aie/bin" "$SITE/llvm-aie/lib" "$SITE/mlir_aie/bin" "$SITE/mlir_aie/lib"; do
        if [ -d "$dir" ]; then
          for f in "$dir/"*; do
            if [ -f "$f" ]; then
              # Only touch ELF files; patchelf errors on .o/.py/etc.
              if ${patchelf}/bin/patchelf --print-interpreter "$f" >/dev/null 2>&1; then
                ${patchelf}/bin/patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$f" || true
              fi
              ${patchelf}/bin/patchelf --add-rpath '${stdenv.cc.cc.lib}/lib' "$f" || true
              ${patchelf}/bin/patchelf --add-rpath '${zlib}/lib' "$f" || true
            fi
          done
        fi
      done

      mkdir -p $out/nix-support
      echo "OpenFlowLM IRON toolchain venv (Python 3.12)" > $out/nix-support/hydra-build-products
    '';

    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  inherit pyVersion pySite pyDeps nativeTools runtimeLibs ironvenv;

  env = {
    # Standard environment variables needed by export scripts at run time.
    # Use the combined XRT so the amdxdna plugin is discoverable next to lib/.
    XILINX_XRT = "${xrt-combined}";
    # The venv is materialized at $TMPDIR/ironvenv by callers; keep these
    # paths relative so they can be prefixed to the chosen venv location.
    PEANO_INSTALL_DIR = "${pySite}/llvm-aie";
    PATH = "${pySite}/llvm-aie/bin:${pySite}/mlir_aie/bin";
    PYTHONPATH = "${pySite}";
    # Only put XRT on LD_LIBRARY_PATH.  The wheel binaries (aiecc, Peano
    # clang) have been patchelf'd with their own RUNPATHs, so they do not
    # need the C++ runtime here; adding stdenv.cc.cc.lib would shadow the
    # newer libstdc++ that xclbinutil's RUNPATH needs and break it in the
    # sandbox.
    LD_LIBRARY_PATH = lib.makeLibraryPath [ xrt-combined ];
  };
}
