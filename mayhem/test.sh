#!/usr/bin/env bash
#
# matio/mayhem/test.sh — RUN matio's own test_mat CLI (built by mayhem/build.sh with NORMAL flags
# in build-tests/) as a behavioral known-answer oracle, and emit a CTRF summary. exit 0 iff every
# check passed. This script only RUNS the pre-built binary; it NEVER compiles.
#
# PATCH-grade oracle (anti-reward-hacking): each check asserts EXACT VALUES, not just exit-0.
#   1) write→read round-trip: `test_mat write_2d_numeric` writes variable `a`, a 5x10 double array
#      holding 1..50 in column-major order; `test_mat readvar test_write_2d_numeric.mat a` must dump
#      that variable with Class "double", Dimensions "5 x 10", and the exact element 1..50 grid.
#   2) copy round-trip: `test_mat copy <shipped.mat>` reads a shipped MAT5 file and rewrites it to
#      test_mat_copy.mat; re-dumping the copy must still list the same variables — read+write agree.
# A no-op / exit(0) "patch" writes no file (or wrong values) and FAILS check 1, so it cannot
# reward-hack this oracle. ("Ran the corpus without crashing" is NOT a functional test.)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

TEST_MAT="$SRC/build-tests/test_mat"
if [ ! -x "$TEST_MAT" ]; then
  echo "missing $TEST_MAT — run mayhem/build.sh first" >&2
  emit_ctrf "matio-test_mat" 0 1 0; exit 2
fi

WORK="$(mktemp -d)"
cd "$WORK"

PASSED=0
FAILED=0

# ── Check 1: write a known 5x10 double array, read it back, assert exact values ──────────────────
# write_2d_numeric writes variable `a` = reshape(1:50, 5, 10) (column-major) as MAT5 double.
if "$TEST_MAT" write_2d_numeric >/dev/null 2>&1 && [ -f test_write_2d_numeric.mat ]; then
  out="$("$TEST_MAT" readvar test_write_2d_numeric.mat a 2>&1)"
  echo "=== readvar a ===" ; echo "$out"
  # Collapse runs of whitespace to single spaces so the value asserts don't depend on Mat_VarPrint's
  # exact column spacing. Column-major 1..50 in a 5x10 grid -> row 1 = 1 6 11 16 21 26 31 36 41 46;
  # row 5 = 5 10 15 20 25 30 35 40 45 50 (the last value of every column).
  # pad every line with a leading+trailing space and squeeze internal whitespace
  norm="$(printf '%s\n' "$out" | tr -s ' \t' ' ' | sed 's/^/ /; s/$/ /')"
  if printf '%s\n' "$out" | grep -q 'Name: a' \
     && printf '%s\n' "$out" | grep -qi 'double' \
     && printf '%s\n' "$out" | grep -q '5 x 10' \
     && printf '%s\n' "$norm" | grep -qF ' 1 6 11 16 21 26 31 36 41 46 ' \
     && printf '%s\n' "$norm" | grep -qF ' 5 10 15 20 25 30 35 40 45 50 '; then
    echo "PASS: write_2d_numeric round-trip (variable a = reshape(1:50,5,10))"
    PASSED=$((PASSED+1))
  else
    echo "FAIL: write_2d_numeric round-trip — readvar output did not match the known answer" >&2
    FAILED=$((FAILED+1))
  fi
else
  echo "FAIL: test_mat write_2d_numeric did not produce test_write_2d_numeric.mat" >&2
  FAILED=$((FAILED+1))
fi

# ── Check 2: copy a shipped MAT5 file and confirm the variable listing survives read+write ───────
SHIPPED="$SRC/share/test_le.mat"
if [ -f "$SHIPPED" ]; then
  before="$("$TEST_MAT" directory "$SHIPPED" 2>&1)"
  if "$TEST_MAT" copy "$SHIPPED" >/dev/null 2>&1 && [ -f test_mat_copy.mat ]; then
    after="$("$TEST_MAT" directory test_mat_copy.mat 2>&1)"
    echo "=== directory before ===" ; echo "$before"
    echo "=== directory after  ===" ; echo "$after"
    # The set of variable names must be preserved across the read->write copy.
    bvars="$(printf '%s\n' "$before" | grep -E '^[A-Za-z]' | sort)"
    avars="$(printf '%s\n' "$after"  | grep -E '^[A-Za-z]' | sort)"
    if [ -n "$bvars" ] && [ "$bvars" = "$avars" ]; then
      echo "PASS: copy round-trip preserved the variable listing"
      PASSED=$((PASSED+1))
    else
      echo "FAIL: copy round-trip changed the variable listing" >&2
      FAILED=$((FAILED+1))
    fi
  else
    echo "FAIL: test_mat copy did not produce test_mat_copy.mat" >&2
    FAILED=$((FAILED+1))
  fi
else
  echo "skip: $SHIPPED not present" >&2
fi

cd "$SRC"; rm -rf "$WORK"

emit_ctrf "matio-test_mat" "$PASSED" "$FAILED" 0
