#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Nebula's own parser gtest suites (built by mayhem/build.sh with the project's normal flags). Each
# `TEST`/`ASSERT_*` checks a parse result (accepted/rejected statements, the re-printed AST, expression
# precedence, lexer token and column counts), so a neutered or no-op program fails: a suite that prints no
# gtest summary line counts as a failure.
TESTS="$SRC/cmake-build-test/bin/test"
passed=0 ; failed=0 ; skipped=0 ; rc=0
for spec in parser_test:50 scanner_test:2 expression_parsing_test:2; do
  name=${spec%%:*} ; min=${spec##*:}
  bin="$TESTS/$name"
  if [ ! -x "$bin" ]; then echo "missing $bin — mayhem/build.sh must build it" >&2 ; failed=$(( failed + 1 )) ; continue ; fi
  out=$("$bin" 2>&1) ; trc=$?
  printf '%s\n' "$out" | tail -n 8
  p=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) tests\?\..*/\1/p' | tail -n 1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) tests\?, listed below.*/\1/p' | tail -n 1)
  s=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9][0-9]*\) tests\?, listed below.*/\1/p' | tail -n 1)
  p=${p:-0} ; f=${f:-0} ; s=${s:-0}
  if [ "$trc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1 ; fi
  if [ "$p" -lt "$min" ] && [ "$f" -eq 0 ]; then echo "$name: only $p passing tests, expected at least $min" >&2 ; f=1 ; fi
  passed=$(( passed + p )) ; failed=$(( failed + f )) ; skipped=$(( skipped + s ))
done
emit_ctrf "gtest" "$passed" "$failed" "$skipped"
