#!/usr/bin/env bash
#
# mayhem/build.sh — build the codebase-memory-mcp fuzz harness, its standalone reproducer, and the test runner.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Upstream builds with Makefile.cbm; mayhem/fuzz.mk reuses its flags and vendored-object rules but compiles
# each source to its own object, so the build is parallel and incremental (re-running it is a no-op).
CBM_FUZZ_DIR=build/fuzz
CBM_TEST_DIR=build/c
FUZZ_SANITIZE="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
mkdir -p "$CBM_FUZZ_DIR" "$CBM_TEST_DIR"

# LeakSanitizer off at build time (not the bug class fuzzed here): link this hook into every fuzz binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$CBM_FUZZ_DIR/lsan_off.o"
# LLVM's run-once driver, compiled as C so its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$CBM_FUZZ_DIR/standalone_main.o"

# 1+2) The project and the harness (tests/fuzz/cbm_fuzz.c, three targets selected by CBM_FUZZ_TARGET)
#      with sanitizers + coverage, as the libFuzzer binary and the standalone reproducer.
make -f mayhem/fuzz.mk -j"$MAYHEM_JOBS" mayhem-fuzz mayhem-standalone \
    BUILD_DIR="$CBM_FUZZ_DIR" CC="$CC" CXX="$CXX" SANITIZE="$FUZZ_SANITIZE" \
    LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
    MAYHEM_LSAN_OBJ="$CBM_FUZZ_DIR/lsan_off.o" MAYHEM_STANDALONE_MAIN_OBJ="$CBM_FUZZ_DIR/standalone_main.o" \
    MAYHEM_FUZZ_OUT=/mayhem/cbm-fuzz MAYHEM_STANDALONE_OUT=/mayhem/cbm-fuzz-standalone

# 3) The project's own test runner, built exactly as upstream's `make test` does (its default
#    ASan+UBSan -O1 flags; separate build dir from the fuzz build). test.sh only runs it.
make -f mayhem/fuzz.mk -j"$MAYHEM_JOBS" mayhem-test-runner \
    BUILD_DIR="$CBM_TEST_DIR" CC="$CC" CXX="$CXX" \
    SANITIZE="-fsanitize=address,undefined -fno-omit-frame-pointer $COVERAGE_FLAGS"
