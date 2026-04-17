// C0-3 shim: invoke sbpf-linker's stage 2 directly on Zig's .o output.
// We bypass bpf-linker entirely (which wants LLVM 20, not available here)
// by depending only on sbpf-assembler + sbpf-common + object.
mod parse;

use sbpf_assembler::Program;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        anyhow::bail!("usage: {} <input.o> <output.so>", args[0]);
    }
    let input = std::fs::read(&args[1])?;
    let parse_result = parse::parse_bytecode(&input)
        .map_err(|e| anyhow::anyhow!("parse: {:?}", e))?;
    let program = Program::from_parse_result(parse_result, None);
    let bytecode = program.emit_bytecode();
    std::fs::write(&args[2], &bytecode)?;
    eprintln!("wrote {} ({} bytes)", args[2], bytecode.len());
    Ok(())
}
