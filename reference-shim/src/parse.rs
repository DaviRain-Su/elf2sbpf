use sbpf_assembler::Token;
use sbpf_assembler::ast::AST;
use sbpf_assembler::astnode::{ASTNode, GlobalDecl, Label, ROData};
use sbpf_assembler::parser::ParseResult;
use sbpf_assembler::section::DebugSection;
use sbpf_common::{
    inst_param::Number, instruction::Instruction, opcode::Opcode,
};

use either::Either;
use object::RelocationTarget::Symbol;
use object::{
    File, Object as _, ObjectSection as _, ObjectSymbol as _, SectionIndex,
};

use std::collections::{BTreeSet, HashMap};

#[derive(Debug)]
pub enum SbpfLinkerError {
    ObjectFileOpenError(object::Error),
    ObjectFileReadError(std::io::Error),
    BuildProgramError { errors: Vec<sbpf_assembler::CompileError> },
    InstructionParseError(String),
}

impl From<object::Error> for SbpfLinkerError {
    fn from(e: object::Error) -> Self { Self::ObjectFileOpenError(e) }
}
impl From<std::io::Error> for SbpfLinkerError {
    fn from(e: std::io::Error) -> Self { Self::ObjectFileReadError(e) }
}

// Staged rodata region. We collect these before emitting so we can sort by
// address and fill anonymous gaps before the AST is built.
struct RodataEntry {
    section_index: SectionIndex,
    address: u64,
    size: u64,
    name: String,
    bytes: Vec<Number>,
}

pub fn parse_bytecode_ex(
    bytes: &[u8],
    arch: sbpf_assembler::SbpfArch,
) -> Result<ParseResult, SbpfLinkerError> {
    parse_bytecode_impl(bytes, arch)
}

pub fn parse_bytecode(bytes: &[u8]) -> Result<ParseResult, SbpfLinkerError> {
    parse_bytecode_impl(bytes, sbpf_assembler::SbpfArch::V0)
}

fn parse_bytecode_impl(
    bytes: &[u8],
    arch: sbpf_assembler::SbpfArch,
) -> Result<ParseResult, SbpfLinkerError> {
    let mut ast = AST::new();

    let obj = File::parse(bytes)?;

    // Track all read-only sections including .rodata* and .data.rel.ro* sections.
    // .data.rel.ro* is read-only after load-time pointer patching and can be
    // an lddw relocation target just like .rodata*.
    let mut ro_sections = HashMap::new();
    for section in obj.sections().filter(|section| {
        section
            .name()
            .map(|name| {
                name.starts_with(".rodata") || name.starts_with(".data.rel.ro")
            })
            .unwrap_or(false)
    }) {
        ro_sections.insert(section.index(), section);
    }

    let mut text_section_bases = HashMap::new();
    let mut text_size = 0u64;
    for section in obj.sections().filter(|section| {
        section.name().map(|name| name.starts_with(".text")).unwrap_or(false)
    }) {
        text_section_bases.insert(section.index(), text_size);
        text_size += section.size();
    }
    let mut pending_rodata: Vec<RodataEntry> = Vec::new();
    let mut rodata_table: HashMap<(Option<SectionIndex>, u64), String> =
        HashMap::new();

    for symbol in obj.symbols() {
        if let Some(ro_section) = symbol
            .section_index()
            .and_then(|section_index| ro_sections.get(&section_index))
        {
            // STT_SECTION symbols have size == 0; anonymous gaps they cover
            // are handled by the gap-fill pass below.
            if symbol.kind() == object::SymbolKind::Section {
                continue;
            }
            assert!(
                symbol.size() > 0,
                "non-STT_SECTION rodata symbol has size 0"
            );

            let bytes: Vec<Number> = (0..symbol.size())
                .map(|i| {
                    Number::Int(i64::from(
                        ro_section.data().unwrap()
                            [(symbol.address() + i) as usize],
                    ))
                })
                .collect();
            pending_rodata.push(RodataEntry {
                section_index: ro_section.index(),
                address: symbol.address(),
                size: symbol.size(),
                name: symbol.name().unwrap().to_owned(),
                bytes,
            });
        } else if let Some(section_index) = symbol.section_index()
            && let Some(section_base) = text_section_bases.get(&section_index)
        {
            let sym_name = symbol.name().unwrap_or("");
            if sym_name.is_empty() {
                continue;
            }
            ast.nodes.push(ASTNode::Label {
                label: Label { name: sym_name.to_owned(), span: 0..1 },
                offset: section_base + symbol.address(),
            });
            if sym_name == "entrypoint" {
                ast.nodes.push(ASTNode::GlobalDecl {
                    global_decl: GlobalDecl {
                        entry_label: sym_name.to_owned(),
                        span: 0..1,
                    },
                });
            }
        }
    }

    // Pre-gap-fill pass: scan text sections for lddw relocations and collect
    // all addressed offsets inside each rodata section. This handles the
    // common case where the compiler (Zig / clang -O) emits only an
    // STT_SECTION symbol for a merged string section, and multiple lddw
    // instructions reference distinct offsets inside it. Without this pass,
    // byteparser's gap-fill creates one monolithic anon entry at offset 0
    // and every non-zero addend fails the rodata_table lookup.
    let mut lddw_targets: HashMap<SectionIndex, BTreeSet<u64>> = HashMap::new();
    for section in obj.sections() {
        if !text_section_bases.contains_key(&section.index()) {
            continue;
        }
        let data = section.data().unwrap();
        for (offset, rel) in section.relocations() {
            let sym = match rel.target() {
                Symbol(idx) => match obj.symbol_by_index(idx) {
                    Ok(s) => s,
                    _ => continue,
                },
                _ => continue,
            };
            let Some(target_section) = sym.section_index() else { continue };
            if !ro_sections.contains_key(&target_section) {
                continue;
            }
            // lddw is 16 bytes, opcode byte = 0x18; addend is in bytes 4..8 of
            // the first 8-byte half (little-endian i32 reinterpreted as u64).
            let off = offset as usize;
            if off + 8 > data.len() || data[off] != 0x18 {
                continue;
            }
            let addend = u32::from_le_bytes([
                data[off + 4], data[off + 5], data[off + 6], data[off + 7],
            ]) as u64;
            lddw_targets.entry(target_section).or_default().insert(addend);
        }
    }

    // Gap-fill pass: synthesize rodata entries for byte ranges not covered
    // by any named symbol, subdividing at every lddw target offset so each
    // reference lands at the start of its own rodata entry.
    let mut synthetic_rodata: Vec<RodataEntry> = Vec::new();
    for (section_index, ro_section) in &ro_sections {
        let section_data = ro_section.data().unwrap();
        let section_size = section_data.len() as u64;

        let mut section_entries: Vec<&RodataEntry> = pending_rodata
            .iter()
            .filter(|e| &e.section_index == section_index)
            .collect();
        section_entries.sort_by_key(|e| e.address);

        // Build anchor set: every position at which a new rodata entry must
        // begin. Includes: section start, section end, each named entry's
        // start and end, and each lddw target offset.
        let mut anchors: BTreeSet<u64> = BTreeSet::new();
        anchors.insert(0);
        anchors.insert(section_size);
        for e in &section_entries {
            anchors.insert(e.address);
            anchors.insert(e.address + e.size);
        }
        if let Some(targets) = lddw_targets.get(section_index) {
            for &t in targets {
                if t < section_size {
                    anchors.insert(t);
                }
            }
        }

        // Sanity check: no lddw target may fall strictly inside a named
        // entry's range (would require splitting a named symbol, which no
        // sane compiler should produce).
        if let Some(targets) = lddw_targets.get(section_index) {
            for e in &section_entries {
                for &t in targets {
                    if t > e.address && t < e.address + e.size {
                        panic!(
                            "lddw target {:#x} falls inside named rodata entry {} ({:#x}..{:#x})",
                            t, e.name, e.address, e.address + e.size
                        );
                    }
                }
            }
        }

        // Walk consecutive anchor pairs; emit synthetic entries for windows
        // not already covered by a named entry.
        let anchor_list: Vec<u64> = anchors.into_iter().collect();
        for w in anchor_list.windows(2) {
            let start = w[0];
            let end = w[1];
            if start >= end {
                continue;
            }
            // If a named entry starts at `start`, skip — pending_rodata
            // already owns this range.
            if section_entries.iter().any(|e| e.address == start) {
                continue;
            }
            let gap_bytes: Vec<Number> = section_data
                [start as usize..end as usize]
                .iter()
                .map(|&b| Number::Int(i64::from(b)))
                .collect();
            synthetic_rodata.push(RodataEntry {
                section_index: *section_index,
                address: start,
                size: end - start,
                name: format!(
                    ".rodata.__anon_{:#x}_{:#x}",
                    section_index.0, start
                ),
                bytes: gap_bytes,
            });
        }
    }

    pending_rodata.extend(synthetic_rodata);
    pending_rodata.sort_by_key(|e| (e.section_index.0, e.address));

    let mut rodata_offset = 0u64;
    for entry in pending_rodata {
        ast.rodata_nodes.push(ASTNode::ROData {
            rodata: ROData {
                name: entry.name.clone(),
                args: vec![
                    Token::Directive(String::from("byte"), 0..1),
                    Token::VectorLiteral(entry.bytes, 0..1),
                ],
                span: 0..1,
            },
            offset: rodata_offset,
        });
        rodata_table
            .insert((Some(entry.section_index), entry.address), entry.name);
        rodata_offset += entry.size;
    }

    let mut debug_sections = Vec::default();
    ast.set_rodata_size(rodata_offset);

    for section in obj.sections() {
        if let Some(section_base) = text_section_bases.get(&section.index()) {
            let section_base = *section_base;
            // parse text section and build instruction nodes
            // lddw takes 16 bytes, other instructions take 8 bytes
            let mut offset = 0;
            while offset < section.data().unwrap().len() {
                let data = &section.data().unwrap()[offset..];
                let instruction = Instruction::from_bytes(data);
                if let Err(error) = instruction {
                    return Err(SbpfLinkerError::InstructionParseError(
                        error.to_string(),
                    ));
                }
                let node_len = match instruction.as_ref().unwrap().opcode {
                    Opcode::Lddw => 16,
                    _ => 8,
                };
                ast.nodes.push(ASTNode::Instruction {
                    instruction: instruction.unwrap(),
                    offset: section_base + offset as u64,
                });
                offset += node_len;
            }

            // handle relocations
            for rel in section.relocations() {
                // handle relocations for call targets and rodata referenced by lddw
                let symbol = match rel.1.target() {
                    Symbol(sym) => obj.symbol_by_index(sym).unwrap(),
                    _ => continue,
                };

                let node: &mut Instruction = ast
                    .get_instruction_at_offset(section_base + rel.0)
                    .unwrap();

                if node.opcode == Opcode::Lddw {
                    // addend is not explicit in the relocation entry, but implicitly
                    // encoded as the immediate value of the instruction
                    let addend = match node.imm {
                        Some(Either::Right(Number::Int(val))) => val,
                        _ => 0,
                    };

                    let key = (symbol.section_index(), addend as u64);
                    if rodata_table.contains_key(&key) {
                        // Replace the immediate value with the rodata label
                        let ro_label = rodata_table[&key].clone();
                        node.imm = Some(Either::Left(ro_label));
                    } else {
                        panic!("relocation in lddw is not in .rodata");
                    }
                } else if node.opcode == Opcode::Call {
                    if symbol.kind() == object::SymbolKind::Section {
                        // STT_SECTION target: find the named symbol at
                        // (section_index, addend) where addend is the current
                        // raw integer immediate.
                        let addend = match node.imm {
                            Some(Either::Right(Number::Int(val))) => {
                                val as u64
                            }
                            _ => 0,
                        };
                        let target_name = obj
                            .symbols()
                            .find(|s| {
                                s.section_index() == symbol.section_index()
                                    && s.address() == addend
                                    && s.name()
                                        .map(|n| !n.is_empty())
                                        .unwrap_or(false)
                            })
                            .and_then(|s| s.name().ok())
                            .map(|n| n.to_owned());

                        if let Some(n) = target_name {
                            node.imm = Some(Either::Left(n));
                        }
                        // If no named symbol found, leave the raw integer immediate
                        // in place -- the assembler emits it as a direct offset.
                    } else {
                        let name = symbol.name().unwrap_or("");
                        assert!(
                            !name.is_empty(),
                            "non-STT_SECTION call target has empty name"
                        );
                        node.imm = Some(Either::Left(name.to_owned()));
                    }
                }
            }
        } else if let Ok(section_name) = section.name()
            && section_name.starts_with(".debug_")
        {
            // So we have debug sections, keep them around.
            debug_sections.push(DebugSection::new(
                section_name,
                0, // will compute during emitting
                section.data().unwrap().to_vec(),
            ));
        }
    }
    ast.set_text_size(text_size);

    let mut parse_result = ast
        .build_program(arch)
        .map_err(|errors| SbpfLinkerError::BuildProgramError { errors })?;

    parse_result.debug_sections = debug_sections;

    Ok(parse_result)
}
