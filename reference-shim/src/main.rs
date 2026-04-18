// C0-3 shim: invoke sbpf-linker's stage 2 directly on Zig's .o output.
// We bypass bpf-linker entirely (which wants LLVM 20, not available here)
// by depending only on sbpf-assembler + sbpf-common + object.
mod parse;

use sbpf_assembler::Program;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut arch = sbpf_assembler::SbpfArch::V0;
    let mut positional: Vec<&str> = Vec::new();
    for a in args.iter().skip(1) {
        match a.as_str() {
            "--v0" => arch = sbpf_assembler::SbpfArch::V0,
            "--v3" => arch = sbpf_assembler::SbpfArch::V3,
            other => positional.push(other),
        }
    }
    if positional.len() != 2 {
        anyhow::bail!("usage: {} [--v0|--v3] <input.o> <output.so>", args[0]);
    }
    let input = std::fs::read(positional[0])?;
    let parse_result = parse::parse_bytecode_ex(&input, arch)
        .map_err(|e| anyhow::anyhow!("parse: {:?}", e))?;
    let program = Program::from_parse_result(parse_result, None);
    let bytecode = program.emit_bytecode();
    std::fs::write(positional[1], &bytecode)?;
    eprintln!("wrote {} ({} bytes)", positional[1], bytecode.len());
    Ok(())
}
