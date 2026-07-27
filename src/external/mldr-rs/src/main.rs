// mldr -- Darling guest-side Mach-O loader, Rust rewrite of src/startup/mldr/ (task #65).
//
// M0/M1 (this file): the crate scaffold, argv-shape detection, special-env handling, and
// the Mach-O parse via goblin. The address-space setup (M2), dyld + start stack + commpage
// (M3), darlingserver checkin (M4), and register setup + jump-to-entry (M5) are the next
// milestones (plan/rust-startup-port.md). All the unsafe mapping/jump work is deferred so
// this compiles first and the parse path can be validated on real guest binaries.
#![allow(dead_code)]

use std::ffi::CString;
use std::os::raw::c_int;

mod commpage;
mod loader;
mod stack;

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

/// State accumulated while loading a Mach-O image (mirrors mldr.c's `struct loader`).
#[derive(Default)]
struct Loader {
    slide: u64,
    entry_point: u64,
    mh: u64, // in-memory mach_header of the executable
    stack_top: u64,
    stack_size: u64,
    root_path: Option<String>,
    kernfd: c_int,
    dyld_all_image_location: u64,
    dyld_all_image_size: u64,
    uuid: [u8; 16],
}

/// Special env vars mldr consumes then strips before the guest sees them (mldr.c:499-544).
#[derive(Default)]
struct SpecialEnv {
    sockpath: Option<String>,
    lifetime_pipe: Option<c_int>,
    bprefs: [u32; 4],
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.is_empty() {
        std::process::exit(1);
    }

    // Invocation shape (mldr.c:127-152):
    //   "mldrpath!guestpath" with shifted argv (execve emulation), or
    //   binfmt: mldr <binary> <original argv...>.
    let guest_path = match argv[0].find('!') {
        Some(idx) => argv[0][idx + 1..].to_string(),
        None => argv.get(1).cloned().unwrap_or_default(),
    };

    let special = parse_special_env();
    eprintln!(
        "[mldr-rs] guest={guest_path} sockpath={:?} lifetime_pipe={:?}",
        special.sockpath, special.lifetime_pipe
    );

    // M1: parse the Mach-O (header + load commands, fat selection) via goblin.
    let data = match std::fs::read(&guest_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("[mldr-rs] cannot read {guest_path}: {e}");
            std::process::exit(1);
        }
    };
    match goblin::mach::Mach::parse(&data) {
        Ok(goblin::mach::Mach::Binary(macho)) => {
            eprintln!(
                "[mldr-rs] Mach-O: entry={:#x}, {} load commands",
                macho.entry,
                macho.load_commands.len()
            );
            // M3a: set up the commpage (setup_space does this first).
            let cp = unsafe { commpage::setup() };
            let sig = unsafe { std::ffi::CStr::from_ptr(cp as *const std::os::raw::c_char) }
                .to_string_lossy()
                .into_owned();
            eprintln!(
                "[mldr-rs] commpage@{:#x} sig={sig:?} ncpu={}",
                cp as u64,
                unsafe { *cp.add(0x22) }
            );

            // M2: map the segments at vmaddr+slide (raw mmap from the fd).
            let path_c = cstr(&guest_path);
            let fd = unsafe { libc::open(path_c.as_ptr(), libc::O_RDONLY) };
            if fd < 0 {
                eprintln!("[mldr-rs] open({guest_path}) failed");
                std::process::exit(1);
            }
            let r = unsafe { loader::map_image(fd, &macho, 0) };
            eprintln!(
                "[mldr-rs] mapped: slide={:#x} mh={:#x} vm_addr_max={:#x} entry={:#x}",
                r.slide, r.mh, r.vm_addr_max, r.entry
            );
            // Sanity: the mapped mach_header must carry MH_MAGIC_64.
            if r.mh != 0 {
                let magic = unsafe { *(r.mh as *const u32) };
                eprintln!("[mldr-rs] mapped mach_header magic={magic:#x} (expect 0xfeedfacf)");
            }
            // M3b: recursive dyld load (LC_LOAD_DYLINKER). dyld's entry becomes the real
            // jump target. The dylinker path is a Mac path needing vchroot (root_path from
            // M4); MLDR_ROOT_PATH lets us test before the checkin RPC exists.
            let mut final_entry = r.entry;
            if macho.header.filetype == 2 {
                // MH_EXECUTE
                if let Some(dylinker) = loader::find_dylinker(&data) {
                    let root = std::env::var("MLDR_ROOT_PATH").unwrap_or_default();
                    let dyld_path = format!("{root}{dylinker}");
                    eprintln!("[mldr-rs] dylinker={dylinker} -> {dyld_path}");
                    match std::fs::read(&dyld_path) {
                        Ok(ddata) => {
                            if let Ok(goblin::mach::Mach::Binary(dmacho)) =
                                goblin::mach::Mach::parse(&ddata)
                            {
                                let dfd =
                                    unsafe { libc::open(cstr(&dyld_path).as_ptr(), libc::O_RDONLY) };
                                let dr = unsafe { loader::map_image(dfd, &dmacho, 0) };
                                eprintln!(
                                    "[mldr-rs] dyld mapped: slide={:#x} entry={:#x}",
                                    dr.slide, dr.entry
                                );
                                final_entry = dr.entry; // dyld's entry wins
                            }
                        }
                        Err(e) => eprintln!(
                            "[mldr-rs] dyld not found at {dyld_path}: {e} (set MLDR_ROOT_PATH)"
                        ),
                    }
                }
            }
            eprintln!("[mldr-rs] FINAL entry={final_entry:#x}");

            // M3c: build the start stack (kernfd/elfcalls placeholders until M4/M5).
            let envp: Vec<String> = std::env::vars().map(|(k, v)| format!("{k}={v}")).collect();
            let sp = unsafe {
                stack::setup_stack(
                    0x7fff_ffe0_0000,
                    r.mh,
                    3,
                    0,
                    &guest_path,
                    std::slice::from_ref(&guest_path),
                    &envp,
                )
            };
            let sp0 = unsafe { *(sp as *const u64) };
            let argc = unsafe { *((sp + 8) as *const u64) };
            eprintln!("[mldr-rs] stack sp={sp:#x} sp[0](mh)={sp0:#x} argc={argc}");
            // TODO M4: darlingserver checkin over the __mldr_sockpath datagram socket.
            // TODO M5: CPU register setup + jmp to final_entry with sp in %rsp.
        }
        Ok(goblin::mach::Mach::Fat(_fat)) => {
            // TODO: honor bprefs, else prefer CPU_TYPE_X86_64 (mldr.c:340-448).
            eprintln!("[mldr-rs] fat Mach-O (slice selection TODO)");
        }
        Err(e) => {
            eprintln!("[mldr-rs] Mach-O parse error: {e}");
            std::process::exit(1);
        }
    }
}

/// Parse the `__mldr_*` special env vars (mldr.c:499-538). Stripping them from the guest's
/// environment is part of M3's argv/envp handling and is not done here yet.
fn parse_special_env() -> SpecialEnv {
    let mut s = SpecialEnv::default();
    if let Ok(v) = std::env::var("__mldr_sockpath") {
        s.sockpath = Some(v);
    }
    if let Ok(v) = std::env::var("__mldr_lifetime_pipe") {
        s.lifetime_pipe = v.parse().ok();
    }
    if let Ok(v) = std::env::var("__mldr_bprefs") {
        for (i, tok) in v.split(',').take(4).enumerate() {
            s.bprefs[i] = tok.trim().parse().unwrap_or(0);
        }
    }
    s
}
