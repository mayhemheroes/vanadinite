#!/usr/bin/env bash
#
# vanadinite/mayhem/test.sh — RUN repnop/vanadinite's own upstream test suite (`cargo test`,
# every HOST-runnable crate) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: these are upstream's REAL unit suites with concrete assertions —
#   - collections (src/shared): hash map insert/lookup/removal, singly/doubly linked list and
#     LRU behavior — known-answer container semantics;
#   - fat32: FAT path/name parsing against expected values;
#   - vidlgen: the VIDL lexer/parser suites asserting exact token streams and parse trees.
# These assert concrete values, so a no-op / "exit(0)" patch CANNOT pass them.
# This script only RUNS the suite; build.sh pre-compiled it with `cargo test --no-run`.
#
# Tests FOUND but SKIPPED (reasons detailed in mayhem/test-packages.sh):
#   - src/kernel/vanadinite tests — riscv64imac-only, `cargo xtask test` under QEMU;
#   - materialize — librust dep is riscv inline-asm, no host build;
#   - endian/netstack — alchemy_derive's syn 2 dep misses the `full` feature standalone.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-nightly-2023-01-20}"
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

TRIPLE="x86_64-unknown-linux-gnu"
source mayhem/test-packages.sh   # defines SHARED_TEST_PACKAGES / USERSPACE_TEST_PACKAGES

echo "=== running cargo test (vanadinite host-runnable upstream suites) ==="
# Same invocation shape as build.sh's --no-run pre-build (cached; no recompilation). Invoked from
# the repo ROOT so the riscv target overrides in src/*/.cargo do not apply; explicit host target.
# --no-fail-fast so we count every test; RUSTFLAGS cleared so nothing leaks from the fuzz build.
out=""
rc=0
if [ "${#SHARED_TEST_PACKAGES[@]}" -gt 0 ]; then
  o="$(RUSTFLAGS="" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" \
        --manifest-path src/shared/Cargo.toml --target "$TRIPLE" --target-dir mayhem-test-target \
        $(printf -- '-p %s ' "${SHARED_TEST_PACKAGES[@]}") 2>&1)" || rc=1
  out="$out$o"$'\n'
fi
if [ "${#USERSPACE_TEST_PACKAGES[@]}" -gt 0 ]; then
  o="$(RUSTFLAGS="" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" \
        --manifest-path src/userspace/Cargo.toml --target "$TRIPLE" --target-dir mayhem-test-target \
        $(printf -- '-p %s ' "${USERSPACE_TEST_PACKAGES[@]}") 2>&1)" || rc=1
  out="$out$o"$'\n'
fi
printf '%s\n' "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines (compile error, sabotaged cargo, ...), that is a FAILURE — the
# oracle must never pass without evidence of tests actually running.
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines (cargo rc=$rc) — failing" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if cargo reported non-zero but we counted 0 failures (e.g. a
# compile error in one package), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
