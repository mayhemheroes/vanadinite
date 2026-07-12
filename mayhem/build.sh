#!/usr/bin/env bash
#
# vanadinite/mayhem/build.sh — build repnop/vanadinite's cargo-fuzz targets as sanitized
# libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS).
#
# vanadinite is a RISC-V OS written in Rust. The kernel itself only builds for
# riscv64imac-unknown-none-elf, but its LIBRARIES are plain no_std crates that build for the
# host — those are what we fuzz:
#   elf64_parse       — feeds bytes to elf64::Elf::new and walks program/section headers +
#                       relocations (src/userspace/libs/elf64). Ported from the OLD fork
#                       integration (Mayhem target `elf64-parse` — name preserved).
#   deserialize_value — json::deserialize::<json::Value> over raw bytes
#                       (src/userspace/libs/json) — upstream's OWN fuzz harness, relocated
#                       additively to mayhem/fuzz (upstream keeps its copy untouched).
#
# cargo-fuzz notes:
#   - the produced binary IS a libFuzzer target — Mayhem runs it directly (`libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc); nightly is required for `-Z`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# Pin every cargo/rustc call to the image's installed nightly, overriding upstream's UNPINNED
# rust-toolchain.toml (`channel = "nightly"`) which would otherwise make rustup download a new
# nightly at build/re-run time (breaking the air-gapped contract).
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-nightly-2023-01-20}"

# DWARF < 4 debug-info contract (§6.2 item 10). -Zdwarf-version=3 forces DWARF 2 so
# Mayhem triage / gdb can resolve project source lines. The rlenv runtime may export
# RUST_DEBUG_FLAGS before re-running build.sh offline; the default only applies when unset/empty.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -Zdwarf-version=3}"

cd "$SRC"

# ── DWARF < 4 enforcement (§6.2 item 10) ────────────────────────────────────────────────────────
# Rust's ASan runtime (librustc-nightly_rt.asan.a) is compiled with the nightly's bundled LLVM,
# which can default to DWARF 4/5. It is linked BEFORE the project code, so without intervention
# the first CU in the binary's .debug_info could be >= 4 — failing the verify-repo check. Fix:
# strip the ASan archive's debug sections once; the stripped .a is baked into the image, so the
# offline PATCH re-run sees the same file.
# The same applies to the PREBUILT std/core rlibs (their CUs are DWARF 4/5 as shipped): the
# fuzz binaries link them in, so strip debug info from every prebuilt toolchain lib once.
# Project code keeps full DWARF 3 line info (built from source with RUST_DEBUG_FLAGS below).
HOST_LIB="$RUSTUP_HOME/toolchains/$RUSTUP_TOOLCHAIN-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib"
if [ -d "$HOST_LIB" ] && [ ! -f "$HOST_LIB/.mayhem-stripped" ]; then
    echo "Stripping debug info from prebuilt toolchain libs (DWARF < 4 contract): $HOST_LIB"
    find "$HOST_LIB" -maxdepth 1 \( -name '*.rlib' -o -name '*.a' \) -exec objcopy --strip-debug {} \;
    touch "$HOST_LIB/.mayhem-stripped" 2>/dev/null || true
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 so those CUs also
# satisfy the check (the cc crate respects CFLAGS/CXXFLAGS). On the re-run these flags are the
# same, so cargo uses the cached libfuzzer.a without recompiling (fingerprint stable).
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# The cargo-fuzz crate is ADDITIVE under mayhem/fuzz/ (upstream's json fuzz crate stays untouched
# at src/userspace/libs/json/fuzz; ours relocates its harness + carries the old fork's elf64 one).
FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=(elf64_parse deserialize_value)
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate what `cargo fuzz build -O --debug-assertions` does, with plain cargo (cargo-fuzz
# refuses to run here: it requires a NON-fuzz ancestor Cargo.toml, and vanadinite has no root
# manifest — its workspaces live under src/*). The flag set below IS the cargo-fuzz/OSS-Fuzz
# Rust contract: `--cfg fuzzing` + `-Zsanitizer=address` (ASan the Rust way — clang's
# $SANITIZER_FLAGS doesn't apply to rustc) + debug assertions + release opt, built for the
# explicit host triple; libfuzzer-sys supplies the libFuzzer main.
# The sancov flags below are EXACTLY what cargo-fuzz injects — without them the binary runs but
# gives libFuzzer/Mayhem NO coverage feedback (0 edges).
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cdebug-assertions \
-Cpasses=sancov-module \
-Cllvm-args=-sanitizer-coverage-level=4 \
-Cllvm-args=-sanitizer-coverage-inline-8bit-counters \
-Cllvm-args=-sanitizer-coverage-pc-table \
-Cllvm-args=-sanitizer-coverage-trace-compares \
${RUST_DEBUG_FLAGS}"

echo "=== cargo build (libFuzzer targets; pinned nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# Run from the fuzz crate (config discovery walks up: mayhem/fuzz -> mayhem -> repo root, so
# only the root [alias] config applies — no riscv target override from src/*/.cargo).
(cd "$FUZZ_DIR" && cargo build --release --target "$TRIPLE" \
  $(printf -- '--bin %s ' "${FUZZ_TARGETS[@]}"))

# Resolve the cargo target dir robustly via `cargo metadata` (default is <fuzz-crate>/target).
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
echo "fuzz target_directory: $TARGET_DIR"

REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    ls -la "$REL" >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Pre-build the project's TEST suite (normal flags; test.sh only RUNS it) ────────────────────
# vanadinite's kernel/userspace BINARIES are riscv-only (their .cargo configs pin
# riscv64*-unknown-none-elf + build-std), so the HOST-runnable upstream suite is the library
# crates' unit tests. We invoke cargo from the repo ROOT (config discovery is CWD-based, so the
# riscv target overrides in src/*/.cargo do NOT apply) with explicit host --target.
# RUSTFLAGS cleared: the suite builds with the crates' NORMAL flags in a separate target dir.
echo "=== cargo test --no-run (normal flags, pre-building the host test suite) ==="
source mayhem/test-packages.sh   # defines SHARED_TEST_PACKAGES / USERSPACE_TEST_PACKAGES
if [ "${#SHARED_TEST_PACKAGES[@]}" -gt 0 ]; then
  RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS" \
    --manifest-path src/shared/Cargo.toml --target "$TRIPLE" --target-dir mayhem-test-target \
    $(printf -- '-p %s ' "${SHARED_TEST_PACKAGES[@]}")
fi
if [ "${#USERSPACE_TEST_PACKAGES[@]}" -gt 0 ]; then
  RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS" \
    --manifest-path src/userspace/Cargo.toml --target "$TRIPLE" --target-dir mayhem-test-target \
    $(printf -- '-p %s ' "${USERSPACE_TEST_PACKAGES[@]}")
fi

echo "build.sh complete:"
ls -la /mayhem/elf64_parse /mayhem/deserialize_value 2>&1 || true
