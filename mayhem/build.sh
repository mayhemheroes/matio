#!/usr/bin/env bash
#
# matio/mayhem/build.sh — build tbeu/matio (a C library that reads/writes MATLAB .mat files:
# MAT4, MAT5 and MAT7.3/HDF5) and link its OSS-Fuzz harness `ossfuzz/matio_fuzzer.cpp` as a
# sanitized libFuzzer target plus a standalone (non-fuzzer) reproducer. ALSO build matio's own
# test_mat CLI with NORMAL flags so mayhem/test.sh can run a behavioral known-answer oracle.
#
# The fuzzed surface is the .mat PARSER on attacker bytes: the harness writes the fuzz input to a
# temp file, Mat_Open()s it and walks every variable (Mat_VarReadNextInfo + Mat_VarReadDataAll +
# Mat_VarPrint + Mat_VarDuplicate). We compile the matio library ITSELF with $SANITIZER_FLAGS so the
# parser code (mat4.c/mat5.c/mat73.c/read_data.c/inflate.c) is instrumented — not just the harness.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). HDF5 (libhdf5-dev) + zlib are installed in the Dockerfile so the MAT7.3
# path is exercised. CMake project (cmake/options.cmake: MATIO_WITH_HDF5 / MATIO_MAT73 / MATIO_WITH_ZLIB).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO
# sanitizers (the program's natural crash) — and the link still works because we add -lz/-lhdf5/-lm.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX DEBUG_FLAGS

cd "$SRC"

# ── 1) Build the matio static library WITH sanitizers (the fuzzed parser code is instrumented) ───
# Static lib (MATIO_SHARED=OFF) so we can link it straight into the harness. HDF5 + zlib ON so the
# MAT7.3/HDF5 + compressed MAT5 paths are reachable from the fuzzer.
BUILD_DIR="$SRC/build-mayhem"
rm -rf "$BUILD_DIR"
cmake -S "$SRC" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DMATIO_SHARED=OFF \
  -DMATIO_WITH_HDF5=ON \
  -DMATIO_WITH_ZLIB=ON \
  -DMATIO_MAT73=ON \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$BUILD_DIR" -j"$MAYHEM_JOBS" --target matio

MATIO_LIB="$(find "$BUILD_DIR" -name 'libmatio.a' | head -1)"
[ -f "$MATIO_LIB" ] || { echo "ERROR: libmatio.a not produced by the cmake build" >&2; \
  find "$BUILD_DIR" -name 'libmatio*' -print >&2; exit 1; }

# matioConfig.h / matio_pubconf.h are generated into the build tree's src/ — the harness includes
# <matio.h>, which pulls them in. Include both the source src/ and the generated src/.
MATIO_INCLUDES=(-I "$SRC/src" -I "$BUILD_DIR/src")

# Link deps for the static matio: HDF5 (MAT7.3), zlib (compressed MAT5), libm.
# On debian the HDF5 lib is named libhdf5_serial (pkg-config name "hdf5"), NOT libhdf5 — derive the
# real link flags from pkg-config so the harness links against the same HDF5 CMake found.
HDF5_LIBS=()
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists hdf5; then
  # shellcheck disable=SC2207
  HDF5_LIBS=($(pkg-config --libs hdf5))
else
  HDF5_LIBS=(-lhdf5_serial)
fi
LINK_DEPS=("${HDF5_LIBS[@]}" -lz -lm)

# Bake a weak __asan_default_options = "detect_leaks=0" into the fuzzer (only when ASan is in the
# flags): the parser leaks partially-read buffers on malformed inputs, which would otherwise flood.
ASAN_OPTS_OBJ=""
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  "$CC" -c "$SRC/mayhem/asan_default_options.c" -o /tmp/asan_default_options.o
  ASAN_OPTS_OBJ="/tmp/asan_default_options.o"
fi

# ── 2) Build the matio_fuzzer harness twice: libFuzzer target + standalone reproducer ────────────
HARNESS="$SRC/ossfuzz/matio_fuzzer.cpp"
[ -f "$HARNESS" ] || { echo "ERROR: $HARNESS missing" >&2; exit 1; }

# libFuzzer target -> /mayhem/matio_fuzzer
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 \
    "${MATIO_INCLUDES[@]}" -I "$SRC/ossfuzz" \
    "$HARNESS" $LIB_FUZZING_ENGINE "$MATIO_LIB" "${LINK_DEPS[@]}" $ASAN_OPTS_OBJ \
    -o /mayhem/matio_fuzzer

# standalone reproducer (no libFuzzer runtime). The LLVM driver is C; compile it as a C object so
# clang++ doesn't mangle its extern "C" LLVMFuzzerTestOneInput reference.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 \
    "${MATIO_INCLUDES[@]}" -I "$SRC/ossfuzz" \
    "$HARNESS" /tmp/standalone_main.o "$MATIO_LIB" "${LINK_DEPS[@]}" \
    -o /mayhem/matio_fuzzer-standalone

echo "built matio_fuzzer (+ standalone)"

# ── 3) Build matio's OWN test_mat CLI with NORMAL flags (clean, separate tree) so test.sh only
#       RUNS it. test_mat is matio's functional driver (read/write/copy .mat with known answers). ──
TEST_DIR="$SRC/build-tests"
rm -rf "$TEST_DIR"
env -u CFLAGS -u CXXFLAGS \
cmake -S "$SRC" -B "$TEST_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DMATIO_SHARED=OFF \
  -DMATIO_WITH_HDF5=ON \
  -DMATIO_WITH_ZLIB=ON \
  -DMATIO_MAT73=ON \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX"
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS" --target test_mat

TEST_BIN="$(find "$TEST_DIR" -name 'test_mat' -type f -perm -u+x | head -1)"
[ -x "$TEST_BIN" ] || { echo "ERROR: test_mat not produced" >&2; find "$TEST_DIR" -name 'test_mat*' >&2; exit 1; }
# Stash it at the stable path test.sh expects (skip if cmake already put it there).
if [ "$TEST_BIN" != "$SRC/build-tests/test_mat" ]; then
  cp -f "$TEST_BIN" "$SRC/build-tests/test_mat"
fi

echo "build.sh complete:"
ls -la /mayhem/matio_fuzzer /mayhem/matio_fuzzer-standalone "$SRC/build-tests/test_mat" 2>&1 || true
