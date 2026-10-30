# AGENTS.md

Fluxa: behavioral simulator (Kahn process network interpreter) for the Fluxa HLS language. Pure Rust, **zero external dependencies** — do not add crates. Docs (incl. README) are in Traditional Chinese; README references the spec 《Fluxa 語言規格 v0.1》, whose file is not in this repo. Simulator version history: `_doc/v0.1.md`, `_doc/v0.2.md`.

## Commands

```
cargo build --release
./target/release/fluxa examples/fir.fx              # run all tests in file
./target/release/fluxa a.fx b.fx                    # multi-file: merged like `iverilog a.v b.v`
./target/release/fluxa examples/fir.fx --test fir_impulse
./target/release/fluxa examples/fir.fx --list       # list tests
./target/release/fluxa examples/mac.fx --trace      # print every send/recv
./target/release/fluxa examples/gemm.fx --stats     # per-channel token counts / max FIFO occupancy
./rv32i.sh                                          # RV32I core example: rv32i.fx + smoke.fx + tests_basic.fx
./rv64.sh                                           # RV64IMA + Zicsr + M/S/U + Sv39 (v0.3 M4): rv64.fx + smoke.fx + tests_basic.fx + tests_mmu.fx + tests_amo.fx
cargo test --release                                # example regression suite
```

- Exit codes: 0 = all pass, 1 = test failure, 2 = load/syntax error.
- Multi-file loading: fn names must be unique across files (merge is an error otherwise); `--list`/`--test` see the merged program. Error line numbers encode file index internally (`ast::FILE_STRIDE` = 1_000_000) and are decoded for display via `Program::loc` — don't compare raw line numbers.
- `test.sh` is just the README command block; `./rv32i.sh` is the real rv32i runner.
- There is no CI, linter, or formatter config; verify with `cargo test --release`.

## Testing

- `tests/examples.rs` drives the `.fx` files in `examples/` as the regression suite. `err_*.fx` examples are **expected-to-fail** and assert error message substrings (e.g. `"does not fit i24"`, `"deadlock"`, `"does not own the rx endpoint"`). Changing an error message's wording breaks these tests — update `tests/examples.rs` in the same change.
- `no_false_deadlocks_under_repetition` runs gemm+fanout 100× checking for scheduling race flakiness. Run with `--release`; the deadlock-detection test is timing-sensitive in debug builds.
- To run a single example's tests by name: `./target/release/fluxa examples/fir.fx --test <name>`.
- `rv32i/err_*.fx` are expected-to-fail demos run manually against `rv32i.fx` (e.g. `fluxa rv32i/rv32i.fx rv32i/err_wb_depth.fx` must report a deadlock). The rv32i harness drains the dump channel before `io`, so a harness channel must be deep enough for a program's total MMIO output or the pipeline deadlocks before reaching ECALL.

## Deliberate scope boundaries (do not "fix")

These are intentionally unimplemented per README / spec; encountering them should produce a clear error or be parsed-and-ignored, not implemented:

- `stage` layer and `;;` (cycle-accurate semantics are a different simulator).
- Static checks: II reachability (E0412), bank conflicts (E0401), SDF rate balance (E0501).
- `pipeline(ii = n)` and `schedule`: parsed, no behavioral effect.
- Non-blocking channel ops (`try_recv`/`empty`) are forbidden — they would break KPN determinism.

## Core semantics (breaking these breaks the spec)

- Determinism (spec §3.10 property 5): output token sequences must be independent of scheduling and FIFO depth. Every task is an OS thread; channels are bounded FIFOs with blocking send/recv.
- Channel endpoints (`Tx`/`Rx`) are linear resources: `spawn` transfers ownership; using an endpoint after transfer is an error. Tasks close owned `Tx` on exit (end-of-stream) so `for x in rx` terminates.
- Arithmetic uses exact 120-bit integers with dynamic range checks at typed landing sites (`let`, `carry`, params, channel/array elements) → E0301. Narrowing must be explicit: `as`, `.to::<T>(round=, ovf=)`, `.sat::<T>()`, `.wrap::<T>()`.
- `@reg`: reads inside an iteration see the old value; writes commit at iteration end (matches hardware shift-register behavior in `unroll`).
- `fixed<I,F>`: exact arithmetic — addition aligns fractional bits, multiplication adds them.

## Layout

`src/lexer.rs` → `parser.rs` → `ast.rs` → `interp.rs` (tree-walking interpreter) with `runtime.rs` (scheduler, channels, deadlock detection), `value.rs` (values/types/fixed-point). Entry points: `lib.rs` (`load`/`load_many`/`run_test`, used by both `main.rs` and `tests/examples.rs`) and `main.rs` (CLI).
