//! elfdep: print the ELF dependency (SONAME) recorded in a Mach-O file, if any.
//!
//! Rust port of src/buildtools/elfdep.c (#76). Darling-origin, GPL, Copyright (C) 2018-2020
//! Lubos Dolezel; the header stays and a Cider line is added beside it.
//!
//! The name lives in a section called __elfname inside the __TEXT segment. The walk finds the
//! first such section and prints the NUL terminated string at its file offset.
//!
//! FOUR BEHAVIOURS THAT DIFFER FROM getuuid, and all four are preserved rather than unified,
//! because the two tools are read by different callers:
//!
//!   it prints WITH a trailing newline. getuuid prints without one.
//!   its fat walk SHORT CIRCUITS on the first arch that yields a name; getuuid ORs across all
//!   archs and prints every UUID.
//!   main returns EXIT_SUCCESS whether or not anything was found: the result of the walk is
//!   computed and then discarded. So absence of an __elfname is NOT an error exit, and a
//!   caller has to distinguish on empty stdout. getuuid does the opposite.
//!   the section offset is relative to the CONTAINING IMAGE, not to the file. The C passes
//!   mhdr as the base, so for a fat slice it is the slice base. Getting this wrong reads the
//!   right bytes for a thin file and the wrong ones for a fat file, which is the sort of bug
//!   that only shows up on one input.
//!
//! As with getuuid, the C mmaps and casts; this reads and parses at checked offsets, so a
//! lying cmdsize or a truncated file ends the walk instead of running off the mapping.

const MH_MAGIC: u32 = 0xfeed_face;
const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_CIGAM: u32 = 0xbeba_feca;
const LC_SEGMENT: u32 = 0x1;
const LC_SEGMENT_64: u32 = 0x19;

const SIZEOF_MACH_HEADER: usize = 28;
const SIZEOF_MACH_HEADER_64: usize = 32;
const SIZEOF_FAT_HEADER: usize = 8;
const SIZEOF_FAT_ARCH: usize = 20;

// segment_command: cmd, cmdsize, segname[16], vmaddr, vmsize, fileoff, filesize,
//                  maxprot, initprot, nsects, flags
const SEG32_NSECTS_OFF: usize = 48;
const SIZEOF_SEG32: usize = 56;
// segment_command_64 widens the four address fields to 8 bytes
const SEG64_NSECTS_OFF: usize = 64;
const SIZEOF_SEG64: usize = 72;

// section: sectname[16], segname[16], addr, size, offset, ...
const SIZEOF_SECT32: usize = 68;
const SECT32_OFFSET_OFF: usize = 40;
// section_64 widens addr and size to 8 bytes
const SIZEOF_SECT64: usize = 80;
const SECT64_OFFSET_OFF: usize = 48;

fn u32_at(buf: &[u8], off: usize) -> Option<u32> {
    let b = buf.get(off..off.checked_add(4)?)?;
    Some(u32::from_ne_bytes([b[0], b[1], b[2], b[3]]))
}

/// A fixed-width char array compared the way strcmp does: up to the first NUL.
fn name_is(buf: &[u8], off: usize, want: &str) -> bool {
    let Some(field) = buf.get(off..off + 16) else { return false };
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    &field[..end] == want.as_bytes()
}

fn cstr_at(buf: &[u8], off: usize) -> Option<&str> {
    let rest = buf.get(off..)?;
    let end = rest.iter().position(|&b| b == 0).unwrap_or(rest.len());
    std::str::from_utf8(&rest[..end]).ok()
}

/// `printElfdep`: one load command. `base` is the containing image, not the file.
fn print_elfdep(buf: &[u8], lc: usize, base: usize) -> bool {
    let Some(cmd) = u32_at(buf, lc) else { return false };
    let (nsects_off, seg_size, sect_size, sect_off_off) = match cmd {
        LC_SEGMENT => (SEG32_NSECTS_OFF, SIZEOF_SEG32, SIZEOF_SECT32, SECT32_OFFSET_OFF),
        LC_SEGMENT_64 => (SEG64_NSECTS_OFF, SIZEOF_SEG64, SIZEOF_SECT64, SECT64_OFFSET_OFF),
        _ => return false,
    };
    // segname sits right after cmd and cmdsize in both widths.
    if !name_is(buf, lc + 8, "__TEXT") {
        return false;
    }
    let Some(nsects) = u32_at(buf, lc + nsects_off) else { return false };
    for i in 0..nsects as usize {
        let sect = lc + seg_size + i * sect_size;
        if name_is(buf, sect, "__elfname") {
            let Some(off) = u32_at(buf, sect + sect_off_off) else { return false };
            let Some(s) = cstr_at(buf, base + off as usize) else { return false };
            println!("{}", s);
            return true;
        }
    }
    false
}

fn print_thin(buf: &[u8], base: usize, hdr_size: usize) -> bool {
    let Some(ncmds) = u32_at(buf, base + 16) else { return false };
    let mut lc = base + hdr_size;
    for _ in 0..ncmds {
        if print_elfdep(buf, lc, base) {
            return true;
        }
        let Some(cmdsize) = u32_at(buf, lc + 4) else { return false };
        if cmdsize == 0 {
            return false;
        }
        lc = match lc.checked_add(cmdsize as usize) {
            Some(v) if v < buf.len() => v,
            _ => return false,
        };
    }
    false
}

/// printFat and printTaf, which differ only in byte order and both stop at the first hit.
fn print_fat(buf: &[u8], base: usize, swapped: bool) -> bool {
    let sw = |v: u32| if swapped { v.swap_bytes() } else { v };
    let Some(nfat) = u32_at(buf, base + 4).map(sw) else { return false };
    for i in 0..nfat as usize {
        let arch = base + SIZEOF_FAT_HEADER + i * SIZEOF_FAT_ARCH;
        let Some(offset) = u32_at(buf, arch + 8).map(sw) else { return false };
        if print_any(buf, offset as usize) {
            return true;
        }
    }
    false
}

fn print_any(buf: &[u8], base: usize) -> bool {
    let Some(magic) = u32_at(buf, base) else {
        eprintln!("File format not recognized");
        std::process::exit(1);
    };
    match magic {
        MH_MAGIC => print_thin(buf, base, SIZEOF_MACH_HEADER),
        MH_MAGIC_64 => print_thin(buf, base, SIZEOF_MACH_HEADER_64),
        FAT_MAGIC => print_fat(buf, base, false),
        FAT_CIGAM => print_fat(buf, base, true),
        _ => {
            eprintln!("File format not recognized");
            std::process::exit(1);
        }
    }
}

/// `strerror(errno)`. std::io::Error Display would render ENOENT as
/// "No such file or directory (os error 2)"; the C prints just the strerror text, and this
/// output is captured by callers, so the difference is not cosmetic.
fn strerror(e: &std::io::Error) -> String {
    match e.raw_os_error() {
        Some(code) => unsafe {
            let p = libc::strerror(code);
            if p.is_null() {
                e.to_string()
            } else {
                std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
            }
        },
        None => e.to_string(),
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() != 2 {
        eprintln!("elfdep: Prints the ELF dependency (SONAME) of a Mach-O file, if any");
        eprintln!("Usage: elfdep <macho-file>");
        std::process::exit(1);
    }

    let buf = match std::fs::read(&argv[1]) {
        Ok(b) => b,
        Err(e) => {
            // strerror(3), NOT io::Error Display. Display appends " (os error 2)" and the C
            // does not; the golden capture from the C binary is
            //   Cannot open /nonexistent/path: No such file or directory
            // No trailing newline either, also matching the C.
            eprint!("Cannot open {}: {}", argv[1], strerror(&e));
            std::process::exit(1);
        }
    };

    // The C discards this result and always exits 0. Preserved: a missing __elfname is not an
    // error, and callers distinguish on empty stdout.
    let _found = print_any(&buf, 0);
    std::process::exit(0);
}
