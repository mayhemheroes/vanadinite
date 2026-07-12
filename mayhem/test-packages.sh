# Shared between mayhem/build.sh (pre-compiles with --no-run) and mayhem/test.sh (runs) so the
# two can never drift. These are the upstream crates whose test suites are HOST-runnable —
# vanadinite is a RISC-V OS: the kernel's own #[cfg(test)] tests (src/kernel/vanadinite) only
# build for riscv64imac-unknown-none-elf and run under QEMU via `cargo xtask test` (a full
# system-emulation boot; not runnable in this image), so they are found-but-skipped.
# Every crate below carries real upstream #[test] assertions.
# Found-but-skipped (and why):
#   - kernel (src/kernel/vanadinite tests.rs, mem/paging/tests.rs): riscv64imac-only, runs
#     under QEMU full-system emulation via `cargo xtask test` — not runnable in this image;
#   - materialize: depends on librust, whose syscall wrappers are riscv inline-asm (a0/t0
#     registers) — does not compile for the host;
#   - endian, netstack: depend on alchemy -> alchemy_derive, whose syn 2 dep is declared
#     without the `full` feature it actually needs (upstream only ever builds it inside the
#     full riscv workspace where feature unification enables it) — does not compile standalone.
SHARED_TEST_PACKAGES=(collections)
USERSPACE_TEST_PACKAGES=(fat32 vidlgen)
