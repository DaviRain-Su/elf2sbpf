// Minimal BPF program with DWARF debug info — tests elf2sbpf's
// .debug_* preservation path (D.2 fixture).
//
// Build with:
//   zig cc -target bpfel-freestanding -mcpu=v2 -O2 -g \
//          -mllvm -bpf-stack-size=4096 \
//          -c mini-debug.c -o mini-debug.o
//
// Then reference-shim produces the golden:
//   reference-shim/target/release/elf2sbpf-shim mini-debug.o mini-debug.shim.so
//
// The zig build test integration loops over this and all 9 zignocchio
// goldens; any change to the debug-preservation path must keep the
// byte-diff green.

static const char msg[] = "debug-test";

typedef unsigned long (*sol_log_fn)(const char *, unsigned long);

unsigned long entrypoint(const unsigned char *input) {
    (void)input;
    sol_log_fn sol_log = (sol_log_fn)0x207559bd;  // murmur3_32("sol_log_")
    sol_log(msg, sizeof(msg) - 1);
    return 0;
}
