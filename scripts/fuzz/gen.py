#!/usr/bin/env python3
"""Generate a zignocchio-compatible example from a seed.

Emits `examples/<name>/lib.zig` under the target zignocchio root.
Deterministic per (seed, knobs). The goal is to vary the patterns that
stress elf2sbpf's rodata gap-fill, relocation emit, and dynsym build:

  - number of distinct string literals       (1..6)
  - lengths of those strings                  (irregular, not 8-aligned)
  - number of sol_log_ calls                  (1..8)
  - repetition: multiple calls can share a string (test one rodata
    entry with multiple R_SBF_64_RELATIVE entries pointing at it)

Usage:
    gen.py --seed 42 --zignocchio /path/to/zignocchio --name fuzz_0042
"""

import argparse
import os
import random
import sys


# A small vocabulary of "lorem ipsum"-ish tokens. We concatenate a few at
# random to form each string literal. Lengths are deliberately not powers
# of 2 to exercise the 8-byte padding path.
TOKENS = [
    "solana", "bpf", "elf", "zig", "token", "vault", "seed", "addr",
    "merkle", "hash", "block", "tip", "log", "msg", "call", "sig",
    "tx", "ix", "account", "owner", "rent", "slot", "epoch", "fee",
    "a", "bb", "ccc", "dddd", "eeeee",  # irregular short strings
]


def gen_string(rng: random.Random) -> str:
    """Compose a literal by joining 1-3 random tokens with punctuation."""
    n = rng.randint(1, 3)
    parts = [rng.choice(TOKENS) for _ in range(n)]
    sep = rng.choice([" ", ":", "/", "-", "_"])
    return sep.join(parts)


def gen_lib_zig(seed: int) -> str:
    rng = random.Random(seed)

    num_strings = rng.randint(1, 6)
    strings = [gen_string(rng) for _ in range(num_strings)]

    num_calls = rng.randint(1, 8)
    call_indices = [rng.randrange(num_strings) for _ in range(num_calls)]

    # Assemble the source. Uses only sdk.logMsg — matches the hello
    # example's API surface, so the zignocchio sdk handles everything
    # else (entrypoint wrapper, account parsing, syscall lookup).
    lines = [
        f"//! Fuzz variant {seed}",
        f"//! strings={num_strings} calls={num_calls}",
        "",
        'const sdk = @import("sdk");',
        "",
        "export fn entrypoint(input: [*]u8) u64 {",
        "    return @call(.always_inline, sdk.createEntrypointWithMaxAccounts(1, processInstruction), .{input});",
        "}",
        "",
        "fn processInstruction(",
        "    _: *const sdk.Pubkey,",
        "    _: []sdk.AccountInfo,",
        "    _: []const u8,",
        ") sdk.ProgramResult {",
    ]

    for idx in call_indices:
        # zig-escape double quotes and backslashes in the literal.
        s = strings[idx].replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    sdk.logMsg("{s}");')

    lines.append("    return {};")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--seed", type=int, required=True)
    p.add_argument(
        "--zignocchio",
        default=os.environ.get(
            "ZIGNOCCHIO_DIR", "/Users/davirian/dev/active/zignocchio"
        ),
        help="Path to the zignocchio repo root.",
    )
    p.add_argument("--name", required=True, help="Example name, e.g. fuzz_0042")
    args = p.parse_args()

    out_dir = os.path.join(args.zignocchio, "examples", args.name)
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "lib.zig")
    with open(out_path, "w") as f:
        f.write(gen_lib_zig(args.seed))
    print(out_path, file=sys.stdout)


if __name__ == "__main__":
    main()
