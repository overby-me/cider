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
mod elfcalls;
mod jump;
mod loader;
mod rpc;
mod stack;
mod threads;

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
    root_path: Option<String>,
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
    // The guest program's argv is mldr's argv[1..] (both the execve-! and binfmt shapes put
    // the guest's own argv there). Falls back to [guest_path] when mldr has no extra args.
    let guest_argv: Vec<String> = if argv.len() > 1 {
        argv[1..].to_vec()
    } else {
        vec![guest_path.clone()]
    };
    eprintln!("[mldr-rs] argv={argv:?}");

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
            // M4: create the RPC socket, check in, and fetch the vchroot root -- all BEFORE the
            // dyld load (which needs the root) and the stack (which needs kernfd).
            eprintln!(
                "[mldr-rs] wire: sizeof(RpcCallCheckin)={} (expect 40)",
                rpc::checkin_call_size()
            );
            let mut kernfd: c_int = -1;
            let mut vchroot_root: Option<String> = None;
            if let Some(ref sockpath) = special.sockpath {
                let rpcfd = unsafe { rpc::create_socket(sockpath) };
                if rpcfd >= 0 {
                    kernfd = rpcfd;
                    let code = unsafe { rpc::checkin(rpcfd, sockpath, 0x7fff_ffe0_0000) };
                    eprintln!("[mldr-rs] checkin({sockpath}) -> code={code}");
                    rpc::set_sockpath(sockpath);
                    rpc::set_thread_socket(rpcfd);
                    vchroot_root = unsafe { rpc::vchroot_path(rpcfd) };
                    eprintln!("[mldr-rs] vchroot_path -> {vchroot_root:?}");
                } else {
                    eprintln!("[mldr-rs] rpc socket creation failed");
                }
            } else {
                eprintln!("[mldr-rs] (no __mldr_sockpath; skipping checkin)");
            }

            // M3b: recursive dyld load (LC_LOAD_DYLINKER); dyld's entry is the real jump target.
            // root_path priority: __mldr_DYLD_ROOT_PATH (first proc) -> vchroot_path RPC (post-
            // vchroot) -> derive from guest_path minus the Mac path -> MLDR_ROOT_PATH.
            let mut final_entry = r.entry;
            if macho.header.filetype == 2 {
                // MH_EXECUTE
                if let Some(dylinker) = loader::find_dylinker(&data) {
                    let root = special
                        .root_path
                        .clone()
                        .or_else(|| vchroot_root.clone())
                        .or_else(|| {
                            let mac = guest_argv.first()?;
                            if mac.starts_with('/') {
                                guest_path.strip_suffix(mac.as_str()).map(String::from)
                            } else {
                                None
                            }
                        })
                        .or_else(|| std::env::var("MLDR_ROOT_PATH").ok())
                        .unwrap_or_default();
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

            // M5a + M3c: the elf_calls vtable, then the start stack with the real kernfd/elfcalls.
            // Clean the guest env: expose __mldr_DYLD_ROOT_PATH to dyld as DYLD_ROOT_PATH,
            // and strip the other __mldr_ control vars (mldr.c:208-252).
            let envp: Vec<String> = std::env::vars()
                .filter_map(|(k, v)| {
                    if k == "__mldr_DYLD_ROOT_PATH" {
                        Some(format!("DYLD_ROOT_PATH={v}"))
                    } else if k.starts_with("__mldr_") {
                        None
                    } else {
                        Some(format!("{k}={v}"))
                    }
                })
                .collect();
            let elfcalls_addr = elfcalls::make();
            eprintln!("[mldr-rs] elf_calls vtable @ {elfcalls_addr:#x}");
            let sp = unsafe {
                stack::setup_stack(
                    0x7fff_ffe0_0000,
                    r.mh,
                    kernfd,
                    elfcalls_addr,
                    &guest_path,
                    &guest_argv,
                    &envp,
                )
            };
            let sp0 = unsafe { *(sp as *const u64) };
            let argc = unsafe { *((sp + 8) as *const u64) };
            eprintln!("[mldr-rs] stack sp={sp:#x} sp[0](mh)={sp0:#x} argc={argc}");

            // M5b: jump into dyld -- only when we are a real guest (checked in). A test run
            // (no __mldr_sockpath) stops here rather than abandoning the Rust runtime's stack.
            if special.sockpath.is_some() {
                eprintln!("[mldr-rs] jumping to entry {final_entry:#x} with sp {sp:#x}");
                unsafe { jump::jump_to_entry(final_entry, sp) };
            } else {
                eprintln!("[mldr-rs] (test run; not jumping -- set __mldr_sockpath to run a guest)");
            }
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
    // The daemon passes the vchroot/libexec root here (container.rs sets
    // __mldr_DYLD_ROOT_PATH = libexec_path); it is the root for resolving dyld.
    if let Ok(v) = std::env::var("__mldr_DYLD_ROOT_PATH") {
        if !v.is_empty() {
            s.root_path = Some(v);
        }
    }
    // On re-exec (execve emulation), __mldr_DYLD_ROOT_PATH is gone but the guest env carries
    // plain DYLD_ROOT_PATH -- use it as the root fallback.
    if s.root_path.is_none() {
        if let Ok(v) = std::env::var("DYLD_ROOT_PATH") {
            if !v.is_empty() {
                s.root_path = Some(v);
            }
        }
    }
    s
}
