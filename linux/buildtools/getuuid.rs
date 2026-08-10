//! getuuid: print the UUID(s) of a Mach-O file, semicolons between them for a fat file.
//!
//! Rust port of linux/buildtools/getuuid.c (#76). Darling-origin, GPL, Copyright (C) 2018
//! Lubos Dolezel; the header stays on the file and a Cider line is added beside it.
//!
//! BEHAVIOUR PRESERVED EXACTLY, including the parts that look like oversights, because this
//! output is parsed by other things in the tree:
//!
//!   no trailing newline. The C prints the UUID with printf and never a \n, so a caller
//!   capturing stdout gets exactly the digits. Adding one would be a silent format change.
//!   the semicolon SEPARATES rather than terminates, driven by a `static bool hadUuid` in the
//!   C that persists across every call, including across archs of a fat file. That static is
//!   why the separator logic lives in the walker here rather than in each printer.
//!   a thin image stops at the FIRST LC_UUID. printUuidMH returns true as soon as it prints.
//!   a fat image ORs its arch results, so one arch with a UUID makes the whole run succeed.
//!   an unrecognised magic exits 1 IMMEDIATELY, in the middle of a fat walk if that is where
//!   it happens, rather than returning false and letting the caller decide.
//!   the open failure message has no trailing newline either, matching the C.
//!
//! THE ONE DELIBERATE DIFFERENCE: the C mmaps the file and casts structures out of the
//! mapping; this reads the file and parses at offsets with checked arithmetic. A malformed
//! cmdsize walked the C off the end of the mapping, which is a crash at best. Every read here
//! is bounds checked and a truncated or lying header ends the walk instead.

use std::io::Write;

const MH_MAGIC: u32 = 0xfeed_face;
const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_CIGAM: u32 = 0xbeba_feca;
const LC_UUID: u32 = 0x1b;

/// mach_header is 7 u32; mach_header_64 adds a reserved u32.
const SIZEOF_MACH_HEADER: usize = 28;
const SIZEOF_MACH_HEADER_64: usize = 32;
const SIZEOF_FAT_HEADER: usize = 8;
const SIZEOF_FAT_ARCH: usize = 20;

fn u32_at(buf: &[u8], off: usize) -> Option<u32> {
    let end = off.checked_add(4)?;
    let b = buf.get(off..end)?;
    Some(u32::from_ne_bytes([b[0], b[1], b[2], b[3]]))
}

/// Walker state. Replaces the C `static bool hadUuid`, which was function-local but persisted
/// for the whole process; carrying it explicitly is the same behaviour without the static.
struct Walk {
    had_uuid: bool,
    out: String,
}

impl Walk {
    /// `printUuid`: print this load command if it is an LC_UUID, and say whether it was.
    fn print_uuid(&mut self, buf: &[u8], lc: usize) -> bool {
        let Some(cmd) = u32_at(buf, lc) else { return false };
        if cmd != LC_UUID {
            return false;
        }
        // uuid_command is cmd, cmdsize, then the 16 raw bytes.
        let Some(uuid) = buf.get(lc + 8..lc + 24) else { return false };
        if self.had_uuid {
            self.out.push(';');
        }
        let h = |b: &[u8]| b.iter().map(|x| format!("{:02X}", x)).collect::<String>();
        self.out.push_str(&format!(
            "{}-{}-{}-{}-{}",
            h(&uuid[0..4]), h(&uuid[4..6]), h(&uuid[6..8]), h(&uuid[8..10]), h(&uuid[10..16])
        ));
        self.had_uuid = true;
        true
    }

    /// `printUuidMH` / `printUuidMH64`: walk ncmds load commands, stop at the first UUID.
    fn print_thin(&mut self, buf: &[u8], base: usize, hdr_size: usize) -> bool {
        let Some(ncmds) = u32_at(buf, base + 16) else { return false };
        let mut lc = match base.checked_add(hdr_size) {
            Some(v) => v,
            None => return false,
        };
        for _ in 0..ncmds {
            if self.print_uuid(buf, lc) {
                return true;
            }
            let Some(cmdsize) = u32_at(buf, lc + 4) else { return false };
            // A zero cmdsize would spin forever on the C too; end the walk instead.
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

    /// `printFat` and `printTaf` share everything but the byte order of the two fields read.
    fn print_fat(&mut self, buf: &[u8], base: usize, swapped: bool) -> bool {
        let sw = |v: u32| if swapped { v.swap_bytes() } else { v };
        let Some(nfat) = u32_at(buf, base + 4).map(sw) else { return false };
        let mut rv = false;
        for i in 0..nfat as usize {
            let arch = base + SIZEOF_FAT_HEADER + i * SIZEOF_FAT_ARCH;
            let Some(offset) = u32_at(buf, arch + 8).map(sw) else { return false };
            // The C adds this offset to the base of the FILE, not of the fat header.
            rv |= self.print_any(buf, offset as usize);
        }
        rv
    }

    /// `printUuidAny`: dispatch on the magic at this offset.
    fn print_any(&mut self, buf: &[u8], base: usize) -> bool {
        let Some(magic) = u32_at(buf, base) else {
            eprintln!("File format not recognized");
            std::process::exit(1);
        };
        match magic {
            MH_MAGIC => self.print_thin(buf, base, SIZEOF_MACH_HEADER),
            MH_MAGIC_64 => self.print_thin(buf, base, SIZEOF_MACH_HEADER_64),
            FAT_MAGIC => self.print_fat(buf, base, false),
            FAT_CIGAM => self.print_fat(buf, base, true),
            _ => {
                // The C exits here rather than returning, even mid fat walk.
                eprintln!("File format not recognized");
                std::process::exit(1);
            }
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
        eprintln!(
            "getuuid: Prints the UUID(s) of a Mach-O file, separated by semicolons (in case of fat files)"
        );
        eprintln!("Usage: getuuid <macho-file>");
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

    let mut w = Walk { had_uuid: false, out: String::new() };
    let ok = w.print_any(&buf, 0);

    print!("{}", w.out);
    let _ = std::io::stdout().flush();
    std::process::exit(if ok { 0 } else { 1 });
}
