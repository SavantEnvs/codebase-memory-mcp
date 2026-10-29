#!/usr/bin/env bash
#
# mayhem/test.sh — RUN codebase-memory-mcp's own C test suites that cover the fuzzed code (built by mayhem/build.sh).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
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

RUNNER=build/c/cbm-test-runner
[ -x "$RUNNER" ] || { echo "$RUNNER missing: mayhem/build.sh should have built it" >&2; exit 1; }

# The suites that assert the behavior of the code the harness fuzzes (extractors, Cypher parser, config
# editors, store, compression) plus the foundation they sit on. Each one checks known inputs against
# known outputs (extracted definitions/calls, parsed queries, rewritten config files, round-trips).
SUITES="arena hash_table str_util ac cypher extraction extraction_imports extraction_inheritance
parse_coverage grammar_regression language config_json_like config_toml_edit config_yaml_edit
config_text_edit lz4 zstd store_nodes store_edges store_search yaml"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
"$RUNNER" $SUITES > "$OUT" 2>&1
rc=$?
tail -n 30 "$OUT"

# Counts come from the runner's own summary line ("N passed[, N failed][, N skipped]"). A runner that
# exits 0 without running anything prints no summary and fails here.
summary="$(sed 's/\x1b\[[0-9;]*m//g' "$OUT" | grep -E '^[[:space:]]*[0-9]+ passed' | tail -n 1)"
if [ -z "$summary" ]; then
  echo "no '<N> passed' summary from $RUNNER (rc=$rc)" >&2
  emit_ctrf "cbm-test-runner" 0 1 0
  exit 1
fi
passed="$(printf '%s' "$summary" | sed -nE 's/^[[:space:]]*([0-9]+) passed.*/\1/p')"
failed="$(printf '%s' "$summary" | sed -nE 's/.* ([0-9]+) failed.*/\1/p')"
skipped="$(printf '%s' "$summary" | sed -nE 's/.* ([0-9]+) skipped.*/\1/p')"
passed="${passed:-0}"; failed="${failed:-0}"; skipped="${skipped:-0}"
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
[ "$passed" -gt 0 ] || failed=$(( failed + 1 ))
emit_ctrf "cbm-test-runner" "$passed" "$failed" "$skipped"
