// wrapgen: writes the Mach-O stub that lets a Darwin program call into a HOST ELF library.
//
// THE RUST REWRITE of wrapgen.cpp (#76). Provenance was the question that blocked this one, and
// it is settled: the C++ carries no copyright header, and local history cannot say where it came
// from because the #87 move squashed it, so it was settled by BLOB IDENTITY instead. The upstream
// Darling file at src/libelfloader/wrapgen/wrapgen.cpp has git blob 7079e613ecf6 and so does
// ours, byte for byte. Darling-origin, unmodified, and the missing header is upstream's absence
// rather than something the move lost. The Cider copyright line below is ours; the design is
// Darling's.
//
// WHY THIS ONE IS NOT LIKE getuuid AND elfdep. Those two are consumed by nothing, so a parity
// harness over a handful of probes was proof enough. This is LOAD BEARING: buck/rules/codegen.bzl
// runs it at BUILD TIME through the elf_wrapper rule, it dlopen()s the real .so while it runs, and
// three packages consume the C it writes. So the gate is the GENERATED OUTPUT over every library
// any consumer feeds it, 22 of them, byte for byte.
//
// THE ONE DELIBERATE DIFFERENCE, the same one the other two tools made: the C++ mmaps the file and
// casts structures straight out of the mapping, so a lying offset walks off the end of the
// mapping. This reads the file and parses at CHECKED offsets. Every output-visible behaviour is
// preserved exactly, including the ones that look like oversights: the soname WARNING goes to
// stderr and the run still succeeds, the .c is created and left behind even when parsing then
// fails, and the vars header is opened only when there are vars to put in it.
//
// Copyright (C) 2026 Niclas Overby. Original design and output format: Darling.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::Write;
use std::os::raw::{c_char, c_int, c_void};

const ELFMAG: &[u8; 4] = b"\x7fELF";
const ELFCLASS64: u8 = 2;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;
const EM_AARCH64: u16 = 183;
const PT_DYNAMIC: u32 = 2;
const DT_NULL: i64 = 0;
const DT_SONAME: i64 = 14;
const DT_STRTAB: i64 = 5;
const SHT_DYNSYM: u32 = 11;
const STT_OBJECT: u8 = 1;
const STT_FUNC: u8 = 2;
const STB_GLOBAL: u8 = 1;
const STV_DEFAULT: u8 = 0;
const SHN_UNDEF: u16 = 0;

/// glibc struct link_map, of which only l_name is read. Declared here rather than pulled from a
/// crate: two fields is less surface than a dependency.
#[repr(C)]
struct LinkMap {
    l_addr: u64,
    l_name: *mut c_char,
}

fn errno_text() -> String {
    // strerror, not std::io::Error: the C prints "No such file or directory" and Display would
    // add " (os error 2)". That exact difference was the one defect that survived review on the
    // last two host tools, so it is not a hypothetical.
    let e = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    unsafe {
        let p = libc::strerror(e as c_int);
        if p.is_null() {
            String::new()
        } else {
            CStr::from_ptr(p).to_string_lossy().into_owned()
        }
    }
}

fn dlerror_text() -> String {
    unsafe {
        let p = libc::dlerror();
        if p.is_null() {
            String::new()
        } else {
            CStr::from_ptr(p).to_string_lossy().into_owned()
        }
    }
}

/// Little-endian scalar reads at CHECKED offsets, which is the whole of the deliberate difference
/// from the C++: an offset past the end is an error here and a wild read there.
fn u16_at(b: &[u8], off: usize) -> Option<u16> {
    b.get(off..off + 2).map(|s| u16::from_le_bytes([s[0], s[1]]))
}

fn u32_at(b: &[u8], off: usize) -> Option<u32> {
    b.get(off..off + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

fn u64_at(b: &[u8], off: usize) -> Option<u64> {
    b.get(off..off + 8)
        .map(|s| u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]))
}

fn cstr_at(b: &[u8], off: usize) -> Option<String> {
    let rest = b.get(off..)?;
    let end = rest.iter().position(|c| *c == 0)?;
    Some(String::from_utf8_lossy(&rest[..end]).into_owned())
}

/// The program header table, as (p_type, p_offset, p_vaddr, p_filesz, p_memsz).
fn phdrs(b: &[u8]) -> Vec<(u32, u64, u64, u64, u64)> {
    let e_phoff = u64_at(b, 32).unwrap_or(0) as usize;
    let e_phentsize = u16_at(b, 54).unwrap_or(0) as usize;
    let e_phnum = u16_at(b, 56).unwrap_or(0) as usize;
    let mut out = Vec::new();
    for i in 0..e_phnum {
        let p = e_phoff + i * e_phentsize;
        match (
            u32_at(b, p),
            u64_at(b, p + 8),
            u64_at(b, p + 16),
            u64_at(b, p + 32),
            u64_at(b, p + 40),
        ) {
            (Some(t), Some(off), Some(vaddr), Some(filesz), Some(memsz)) => {
                out.push((t, off, vaddr, filesz, memsz))
            }
            _ => break,
        }
    }
    out
}

fn vaddr_to_offset(b: &[u8], vaddr: u64) -> u64 {
    for (_t, off, p_vaddr, _filesz, memsz) in phdrs(b) {
        let vend = p_vaddr.wrapping_add(memsz);
        if p_vaddr <= vaddr && vaddr < vend {
            return off + vaddr - p_vaddr;
        }
    }
    0
}

struct Parsed {
    soname: String,
    functions: BTreeSet<String>,
    vars: BTreeSet<String>,
}

fn parse_elf(path: &str) -> Result<Parsed, String> {
    let b = match std::fs::read(path) {
        Ok(b) => b,
        Err(_) => return Err(format!("Error opening {path}: {}", errno_text())),
    };

    if b.len() < 64 || &b[..4] != ELFMAG || b[4] != ELFCLASS64 {
        return Err(format!("{path} is not a 64-bit ELF"));
    }
    if u16_at(&b, 16) != Some(ET_DYN) {
        return Err(format!("{path} is not a dynamic library ELF"));
    }
    // The e_machine gate only guards against handing wrapgen a non-native or corrupt object;
    // reading the dynamic symbol table (all wrapgen does) is arch-independent. Accept the two
    // host arches the port targets (aarch64 port, task A16), rather than x86-64 alone.
    match u16_at(&b, 18) {
        Some(EM_X86_64) | Some(EM_AARCH64) => {}
        _ => return Err(format!("{path} is not an ELF for a supported architecture")),
    }

    // The first PT_DYNAMIC segment, and only the first: the C++ breaks out of the loop.
    let mut strtab: Option<usize> = None;
    let mut soname = String::new();
    for (t, off, _vaddr, filesz, _memsz) in phdrs(&b) {
        if t != PT_DYNAMIC {
            continue;
        }
        let (mut off_strtab, mut off_soname) = (0u64, 0u64);
        let mut j = 0u64;
        while j < filesz {
            let d = (off + j) as usize;
            let tag = match u64_at(&b, d) {
                Some(v) => v as i64,
                None => break,
            };
            let val = u64_at(&b, d + 8).unwrap_or(0);
            match tag {
                DT_STRTAB => off_strtab = vaddr_to_offset(&b, val),
                DT_SONAME => off_soname = vaddr_to_offset(&b, val),
                DT_NULL => break,
                _ => {}
            }
            j += 16;
        }
        if off_strtab != 0 {
            strtab = Some(off_strtab as usize);
            if off_soname != 0 {
                // BOTH OFFSETS, and this is where a reading of the C++ goes wrong. DT_SONAME is
                // an index INTO the string table, and the C++ still runs it through
                // vaddr_to_offset (which returns it unchanged whenever the first LOAD segment
                // starts at vaddr 0) and then adds it to `strings`, which is already
                // base + off_strtab. So the byte read is off_strtab + off_soname, not off_soname.
                if let Some(s) = cstr_at(&b, (off_strtab + off_soname) as usize) {
                    soname = s;
                }
            }
        }
        break;
    }

    let mut functions: BTreeSet<String> = BTreeSet::new();
    let mut vars: BTreeSet<String> = BTreeSet::new();
    if let Some(strings) = strtab {
        let e_shoff = u64_at(&b, 40).unwrap_or(0) as usize;
        let e_shentsize = u16_at(&b, 58).unwrap_or(0) as usize;
        let e_shnum = u16_at(&b, 60).unwrap_or(0) as usize;
        for i in 0..e_shnum {
            let s = e_shoff + i * e_shentsize;
            if u32_at(&b, s + 4) != Some(SHT_DYNSYM) {
                continue;
            }
            let sh_offset = u64_at(&b, s + 24).unwrap_or(0) as usize;
            let sh_size = u64_at(&b, s + 32).unwrap_or(0) as usize;
            let mut j = 0usize;
            while j < sh_size {
                let sym = sh_offset + j;
                j += 24;
                let st_name = match u32_at(&b, sym) {
                    Some(v) => v as usize,
                    None => break,
                };
                let st_info = match b.get(sym + 4) {
                    Some(v) => *v,
                    None => break,
                };
                let st_other = match b.get(sym + 5) {
                    Some(v) => *v,
                    None => break,
                };
                let st_shndx = u16_at(&b, sym + 6).unwrap_or(0);
                let st_value = u64_at(&b, sym + 8).unwrap_or(0);
                let sym_type = st_info & 0xf;
                let sym_bind = st_info >> 4;
                if sym_type != STT_OBJECT && sym_type != STT_FUNC {
                    continue;
                }
                if sym_bind != STB_GLOBAL {
                    continue;
                }
                if st_shndx == SHN_UNDEF || st_value == 0 {
                    continue;
                }
                if (st_other & 0x3) != STV_DEFAULT {
                    continue;
                }
                let name = match cstr_at(&b, strings + st_name) {
                    Some(n) => n,
                    None => continue,
                };
                if sym_type == STT_FUNC {
                    functions.insert(name);
                } else {
                    vars.insert(name);
                }
            }
            break;
        }
    }

    if soname.is_empty() {
        eprintln!("WARNING: No DT_SONAME in {path}.");
        soname = match path.rfind('/') {
            Some(i) => path[i + 1..].to_string(),
            None => path.to_string(),
        };
    }
    if functions.is_empty() {
        return Err(format!("No symbols found in {path}"));
    }
    Ok(Parsed { soname, functions, vars })
}

fn generate_wrapper(out: &mut File, soname: &str, symbols: &BTreeSet<String>) -> std::io::Result<()> {
    out.write_all(
        b"#include <elfcalls.h>\nextern struct elf_calls* _elfcalls;\n\nextern const char __elfname[];\n\n",
    )?;
    out.write_all(
        b"static void* lib_handle;\n__attribute__((constructor)) static void initializer() {\n\tlib_handle = _elfcalls->dlopen_fatal(__elfname);\n}\n\n",
    )?;
    out.write_all(
        b"__attribute__((destructor)) static void destructor() {\n\t_elfcalls->dlclose_fatal(lib_handle);\n}\n\n",
    )?;
    for sym in symbols {
        write!(
            out,
            "void* {sym}() {{\n\t__asm__(\".symbol_resolver _{sym}\");\n\treturn _elfcalls->dlsym_fatal(lib_handle, \"{sym}\");\n}}\n\n"
        )?;
    }
    // The \n sequences here are LITERAL backslash-n in the emitted C string, not newlines: this
    // is one asm() line holding a multi-line assembly string.
    write!(
        out,
        "asm(\".section __TEXT,__elfname\\n.private_extern ___elfname\\n___elfname: .asciz \\\"{soname}\\\"\");\n"
    )
}

fn generate_var_wrappers(
    out: &mut File,
    header: &mut File,
    vars: &BTreeSet<String>,
) -> std::io::Result<()> {
    header.write_all(b"#pragma once\n\n")?;
    header.write_all(b"#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n")?;
    for sym in vars {
        write!(
            out,
            "void* __elf_get_{sym}(void) {{\n\treturn _elfcalls->dlsym_fatal(lib_handle, \"{sym}\");\n}}\n\n"
        )?;
        write!(
            header,
            "extern __typeof({sym})* __elf_get_{sym}(void);\n#define {sym} (*__elf_get_{sym}())\n\n"
        )?;
    }
    header.write_all(b"\n\n#ifdef __cplusplus\n}\n#endif\n\n")
}

/// The library path, resolved the way the C++ resolves it: if it is not readable as given, load it
/// and ask the loader where it found it, which is simpler than parsing ld.so.conf.
fn resolve_library(arg: &str) -> Result<String, String> {
    let c = match CString::new(arg) {
        Ok(c) => c,
        Err(_) => return Ok(arg.to_string()),
    };
    if unsafe { libc::access(c.as_ptr(), libc::R_OK) } != -1 {
        return Ok(arg.to_string());
    }
    unsafe {
        let handle = libc::dlopen(c.as_ptr(), libc::RTLD_LAZY | libc::RTLD_LOCAL);
        if handle.is_null() {
            return Err(format!("Cannot load {arg}: {}", dlerror_text()));
        }
        let mut lm: *mut LinkMap = std::ptr::null_mut();
        let rc = libc::dlinfo(
            handle,
            libc::RTLD_DI_LINKMAP,
            &mut lm as *mut *mut LinkMap as *mut c_void,
        );
        if rc != 0 {
            // The C++ prints this one to stderr AND throws with the same text, so the message
            // appears twice. Reproduced rather than tidied.
            let e = dlerror_text();
            eprint!("Cannot locate {arg}: {e}");
            return Err(format!("Cannot locate {arg}: {e}"));
        }
        let name = if lm.is_null() || (*lm).l_name.is_null() {
            String::new()
        } else {
            CStr::from_ptr((*lm).l_name).to_string_lossy().into_owned()
        };
        libc::dlclose(handle);
        Ok(name)
    }
}

fn main() -> std::process::ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() != 4 {
        eprintln!(
            "Usage: {} <library-name> <output-file> <var-access-header>",
            argv.first().map(|s| s.as_str()).unwrap_or("wrapgen")
        );
        return std::process::ExitCode::FAILURE;
    }

    // Opened BEFORE anything can fail, exactly as the C++ does, so a later error still leaves the
    // file behind. Buck2 requires the declared output to exist and the runner relies on it.
    let mut out = match File::create(&argv[2]) {
        Ok(f) => f,
        Err(_) => {
            eprintln!("Cannot open output file");
            return std::process::ExitCode::FAILURE;
        }
    };

    let lib = match resolve_library(&argv[1]) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("{e}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let parsed = match parse_elf(&lib) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            return std::process::ExitCode::FAILURE;
        }
    };
    if let Err(e) = generate_wrapper(&mut out, &parsed.soname, &parsed.functions) {
        eprintln!("{e}");
        return std::process::ExitCode::FAILURE;
    }
    if !parsed.vars.is_empty() {
        let mut header = match File::create(&argv[3]) {
            Ok(f) => f,
            Err(_) => {
                eprintln!("Cannot open output macro header file");
                return std::process::ExitCode::FAILURE;
            }
        };
        if let Err(e) = generate_var_wrappers(&mut out, &mut header, &parsed.vars) {
            eprintln!("{e}");
            return std::process::ExitCode::FAILURE;
        }
    }
    std::process::ExitCode::SUCCESS
}
