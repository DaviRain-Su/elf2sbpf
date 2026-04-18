# Architecture Decision Records (ADR)

[中文版本](decisions.zh.md)

This file records choices of the form "why we did not do X" or "why we chose A
instead of B" — the kinds of questions future reviewers are likely to ask.
Each entry includes: background → decision → consequences/trade-offs → what
would make us revisit it.

---

## ADR-001: Do not introduce Solana runtime validation infrastructure

**Date**: 2026-04-18  
**Related task**: C2-C  
**Status**: closed, will reopen only if bytewise equivalence breaks

### Background

The PRD risk table (§8) listed "implicit Solana runtime constraints on ELF
layout that we may not have observed" as a medium-risk item, and suggested
runtime validation in C2 via `solana-test-validator` or litesvm.

### Decision

Do not implement it. Reasons:

1. **Bytewise equivalence already transitively covers runtime correctness**:
   - all 9 zignocchio example `.so` outputs are **byte-identical** to
     `reference-shim` (see the C1-I.3 integration test)
   - `reference-shim` outputs are known to work on real Solana deployments
   - therefore elf2sbpf outputs are necessarily equivalent at runtime

2. **The cost structure is not worth it**:
   - litesvm would either reintroduce Rust into the project, violating the
     core "zero Rust dependency" positioning, or expand the scope of the
     zignocchio upstream PR
   - `solana-test-validator` requires the Solana CLI and is heavy for CI
   - using `solana-sbpf` crates directly would still reintroduce Rust

3. **The only extra signal it could catch is a double-oracle failure**:
   both `reference-shim` and elf2sbpf would have to be wrong in exactly the
   same way, which is an ignorable probability for this stage

### Consequences / trade-offs

- Cost: if future byteparser/emit changes fail in the exact same way as
  `reference-shim`, runtime-only validation would be the first thing to reveal
  it. This is a second-order probability event.
- Benefit: Epic C goes from roughly 1–2 days to 0 additional days, keeping C2 moving.

### Revisit triggers

- real users report "bytes match but deployment fails"
- `reference-shim` is no longer considered trustworthy
- someone wants to add V3 or debug-info support, both of which may introduce
  runtime-visible bugs that are not obvious from byte-level comparison alone

---

## ADR-002: Keep `reference-shim/` on the main branch

**Date**: 2026-04-18  
**Related task**: C2-E.3 (candidate cleanup item)  
**Status**: kept, re-evaluate post-v0.2

### Background

`reference-shim/` is a minimal Rust shim whose functionality overlaps with
elf2sbpf. C2-E.3 proposed deleting it at the time of the v0.1 release.

### Decision

Keep it, at least until v0.2 (or 6 months after C2 is fully complete). Reasons:

1. **Fast regression triage**:
   if elf2sbpf regresses in the future, we can directly compare against
   `./reference-shim/target/release/elf2sbpf-shim` without rebuilding the
   whole setup
2. **Backstop for ADR-001**:
   we rely on bytewise equivalence as the proof of runtime correctness, and
   `reference-shim` is the oracle for that proof. Remove it and the oracle is gone.
3. **Small footprint**:
   `reference-shim/` source is only about two files / ~400 lines; the target
   directory is gitignored, so it adds very little weight to the repo

### Consequences / trade-offs

- Cost: the repository is not conceptually "pure Zig" from a dependency-story
  perspective, although no Rust build artifacts are committed
- Benefit: the oracle stays immediately available, and release notes do not
  need to explain why it disappeared

### Revisit triggers

- an external contributor opens an issue saying `reference-shim` increases
  the reading burden
- 6 months have passed after the upstream C2-D integration lands and the
  correctness of elf2sbpf has been well validated by the community
