#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
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
# Nebula's translation units (folly/thrift templates under ASan) peak around 1.5 GB of RAM each, so the
# default parallelism is capped by the memory the container may actually use (cgroup limit, else MemTotal).
mem_bytes=$(cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null | grep -m1 -E '^[0-9]+$' || true)
[ -n "$mem_bytes" ] || mem_bytes=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) * 1024 ))
mem_jobs=$(( mem_bytes / 1610612736 )); [ "$mem_jobs" -ge 1 ] || mem_jobs=1
cpu_jobs=$(nproc); [ "$mem_jobs" -lt "$cpu_jobs" ] || mem_jobs=$cpu_jobs
: "${MAYHEM_JOBS:=$mem_jobs}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Nebula's prebuilt third-party closure, baked into the image by the Dockerfile (nothing is fetched here).
TP=/opt/vesoft/third-party/3.3
[ -d "$TP" ] || { echo "missing $TP — the Dockerfile must install the nebula third-party closure" >&2; exit 1; }

# clang >= 16 turns boost::mpl's enum-constexpr-conversion warning (in the 3.3 closure's headers) into an error.
COMMON_FLAGS="-Wno-enum-constexpr-conversion"
FUZZ_BUILD="$SRC/cmake-build-fuzz"
TEST_BUILD="$SRC/cmake-build-test"

# The compiler is taken from the CC/CXX environment (no -DCMAKE_*_COMPILER): when the image build resolves
# `clang` through the ccache masquerade dir and a later re-run resolves it directly, an explicit -D makes cmake
# see a changed compiler, wipe its cache and silently reconfigure WITHOUT the -D options below (target gone).
# With only the environment, an existing build tree keeps the compiler it was configured with.

# 1) Sanitized + SanCov-instrumented project (every nebula object under ASan+UBSan, not only the harness) and
#    upstream's own parser_fuzzer target (src/parser/test/fuzzing, enabled by ENABLE_FUZZ_TEST).
#    - jemalloc/memory tracker off: they conflict with ASan's allocator.
#    - upstream's parser_fuzzer link omits ${PROXYGEN_LIBRARIES} though FunctionManager.cpp calls
#      proxygen::md5Encode, so the closure's proxygen is appended to the link line (CMAKE_CXX_STANDARD_LIBRARIES
#      is emitted after all objects) together with lsan_off.o (LeakSanitizer off at build time).
mkdir -p "$FUZZ_BUILD"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $COMMON_FLAGS"
cmake -S "$SRC" -B "$FUZZ_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  "-DCMAKE_CXX_STANDARD_LIBRARIES=-Wl,--start-group -lproxygen -lwangle -lfizz -lfolly -lssl -lcrypto -lsodium -Wl,--end-group $FUZZ_BUILD/lsan_off.o" \
  -DNEBULA_THIRDPARTY_ROOT="$TP" \
  -DENABLE_TESTING=ON -DENABLE_FUZZ_TEST=ON \
  -DENABLE_JEMALLOC=OFF -DENABLE_MEMORY_TRACKER=OFF \
  -DENABLE_CCACHE=OFF -DENABLE_WERROR=OFF -DENABLE_CREATE_GIT_HOOKS=OFF
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target parser_fuzzer

# 2) Fuzzer binary, and the run-once standalone reproducer: the same objects and libraries, with the libFuzzer
#    engine swapped for LLVM's StandaloneFuzzTargetMain (SanCov callbacks come from the ASan runtime).
install -m 0755 "$FUZZ_BUILD/bin/parser_fuzzer" /mayhem/parser_fuzzer
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
link_cmd=$(ninja -C "$FUZZ_BUILD" -t commands bin/parser_fuzzer | tail -n 1)
link_cmd=${link_cmd#: && }
link_cmd=${link_cmd% && :}
case "$link_cmd" in *" -fsanitize=fuzzer "*" -o bin/parser_fuzzer "*) ;; *) echo "unexpected parser_fuzzer link line" >&2; exit 1 ;; esac
link_cmd=${link_cmd/ -fsanitize=fuzzer / }
link_cmd=${link_cmd/ -o bin\/parser_fuzzer / -o /mayhem/parser_fuzzer-standalone $FUZZ_BUILD/standalone_main.o }
( cd "$FUZZ_BUILD" && eval "$link_cmd" )

# 3) The project's own gtest suites for the parser, with the project's NORMAL flags (default Debug, jemalloc on,
#    no sanitizers, no DWARF pin) in a separate tree, so mayhem/test.sh only runs them.
TEST_FLAGS="$COMMON_FLAGS $COVERAGE_FLAGS"
cmake -S "$SRC" -B "$TEST_BUILD" -G Ninja \
  -DCMAKE_C_FLAGS="$TEST_FLAGS" -DCMAKE_CXX_FLAGS="$TEST_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
  -DNEBULA_THIRDPARTY_ROOT="$TP" \
  -DENABLE_TESTING=ON \
  -DENABLE_CCACHE=OFF -DENABLE_WERROR=OFF -DENABLE_CREATE_GIT_HOOKS=OFF
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target parser_test scanner_test expression_parsing_test
