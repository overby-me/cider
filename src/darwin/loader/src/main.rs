// mldr -- Darling guest-side Mach-O loader, Rust rewrite of src/linux/startup/mldr/ (task #65).
//
// M0/M1 (this file): the crate scaffold, argv-shape detection, special-env handling, and
// the Mach-O parse via goblin. The address-space setup (M2), dyld + start stack + commpage
// (M3), ciderd checkin (M4), and register setup + jump-to-entry (M5) are the next
// milestones (docs/changelog.md). All the unsafe mapping/jump work is deferred so
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

/// mldr prints ~15 diagnostic lines per guest process. A real build spawns
/// thousands of processes, so that per-process flood is gated OFF by default and
/// enabled with `MLDR_DEBUG=1`; genuine errors stay unconditional. The flood also
/// caused a false "concurrent-output flake" (task #66): when a caller merges the
/// guest's stdout and stderr (`2>&1`), these stderr lines interleave with real
/// stdout and glue onto output lines, so a line-anchored count under-reports and
/// looks like dropped output. With the flood gated (or streams separated) output
/// is complete. Cached after the first read. It MUST be primed on the aligned
/// main stack (see [`mldr_debug`] callers): the env read is not guaranteed
/// movaps-free, and elfcall-reachable code runs on an 8-byte-misaligned stack.
static MLDR_DEBUG: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);
fn mldr_debug() -> bool {
    use std::sync::atomic::Ordering;
    match MLDR_DEBUG.load(Ordering::Relaxed) {
        1 => false,
        2 => true,
        _ => {
            let on = std::env::var_os("MLDR_DEBUG").is_some();
            MLDR_DEBUG.store(if on { 2 } else { 1 }, Ordering::Relaxed);
            on
        }
    }
}
/// `eprintln!` gated behind [`mldr_debug`]. Use for per-process diagnostics; keep
/// real errors on a bare `eprintln!` so failures are always visible.
macro_rules! dlog {
    ($($arg:tt)*) => { if mldr_debug() { eprintln!($($arg)*); } };
}

/// x86_64 cputype (CPU_TYPE_X86 | CPU_ARCH_ABI64), the default slice preference.
const CPU_TYPE_X86_64: u32 = 0x0100_0007;

/// Normalize a thin-or-fat Mach-O to (selected MachO, its file offset). For a fat/universal
/// binary, pick a slice: honor the guest's bprefs (requested cpu types) in order, else prefer
/// x86_64, else the first slice. Mirrors mldr.c:340-448. The returned offset is threaded into
/// loader::map_image (fat_offset) and find_dylinker so both read the slice, not the fat header.
fn select_slice<'a>(
    mach: goblin::mach::Mach<'a>,
    bprefs: &[u32; 4],
    data: &'a [u8],
) -> (goblin::mach::MachO<'a>, u64) {
    match mach {
        goblin::mach::Mach::Binary(m) => (m, 0),
        goblin::mach::Mach::Fat(multi) => {
            let arches = multi.arches().unwrap_or_default();
            let chosen = bprefs
                .iter()
                .filter(|&&p| p != 0)
                .find_map(|&p| arches.iter().find(|a| a.cputype == p))
                .or_else(|| arches.iter().find(|a| a.cputype == CPU_TYPE_X86_64))
                .or_else(|| arches.first());
            match chosen {
                Some(fa) => match goblin::mach::MachO::parse(data, fa.offset as usize) {
                    Ok(m) => {
                        dlog!(
                            "[mldr] fat: selected slice cputype={:#x} offset={:#x} size={:#x}",
                            fa.cputype, fa.offset, fa.size
                        );
                        (m, fa.offset as u64)
                    }
                    Err(e) => {
                        eprintln!("[mldr] fat: selected slice failed to parse: {e}");
                        std::process::exit(1);
                    }
                },
                None => {
                    eprintln!("[mldr] fat: no usable slice (arches empty)");
                    std::process::exit(1);
                }
            }
        }
    }
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


/// Give the guest a macOS sized descriptor limit instead of the host one.
///
/// macOS ships a SOFT RLIMIT_NOFILE of a few hundred, and Cocoa applications are written to that:
/// the standard way to sanitise a child before exec is to close every descriptor from 3 up to
/// getdtablesize(), which returns the soft limit. On a Linux host that limit is whatever the login
/// session has, and on this one it is 524287.
///
/// Every one of those closes is an RPC to the daemon here, so iTerm2 forking to launch its pty
/// helper turned into half a million round trips: the child sat in recvmsg burning a core, the
/// daemon burned two thirds of another servicing them, and the exec never arrived. That is why a
/// terminal window opened with no shell in it.
///
/// The HARD limit is left alone, so anything that genuinely needs more descriptors can still raise
/// its own soft limit the way it would on macOS.
fn clamp_open_file_limit() {
    const GUEST_SOFT_LIMIT: libc::rlim_t = 1024;

    unsafe {
        let mut limit: libc::rlimit = std::mem::zeroed();

        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) != 0 {
            return;
        }
        if limit.rlim_cur <= GUEST_SOFT_LIMIT {
            return;
        }

        let wanted = libc::rlimit {
            rlim_cur: GUEST_SOFT_LIMIT.min(limit.rlim_max),
            rlim_max: limit.rlim_max,
        };
        libc::setrlimit(libc::RLIMIT_NOFILE, &wanted);
    }
}

fn main() {
    // Prime the MLDR_DEBUG flag here, on main's aligned stack: the env read must
    // not happen later on an elfcall's misaligned stack (movaps constraint).
    mldr_debug();

    clamp_open_file_limit();

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
    dlog!("[mldr] argv={argv:?}");

    let special = parse_special_env();
    dlog!(
        "[mldr] guest={guest_path} sockpath={:?} lifetime_pipe={:?}",
        special.sockpath, special.lifetime_pipe
    );

    // M1: parse the Mach-O (header + load commands, fat selection) via goblin.
    let data = match std::fs::read(&guest_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("[mldr] cannot read {guest_path}: {e}");
            std::process::exit(1);
        }
    };
    let mach = match goblin::mach::Mach::parse(&data) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("[mldr] Mach-O parse error: {e}");
            std::process::exit(1);
        }
    };
    // For a fat/universal binary, pick the slice (bprefs -> x86_64); thin binaries pass through.
    let (macho, fat_offset) = select_slice(mach, &special.bprefs, &data);
    {
            dlog!(
                "[mldr] Mach-O: entry={:#x}, {} load commands",
                macho.entry,
                macho.load_commands.len()
            );
            // M3a: set up the commpage (setup_space does this first).
            let cp = unsafe { commpage::setup() };
            let sig = unsafe { std::ffi::CStr::from_ptr(cp as *const std::os::raw::c_char) }
                .to_string_lossy()
                .into_owned();
            dlog!(
                "[mldr] commpage@{:#x} sig={sig:?} ncpu={}",
                cp as u64,
                unsafe { *cp.add(0x22) }
            );

            // M2: map the segments at vmaddr+slide (raw mmap from the fd).
            let path_c = cstr(&guest_path);
            let fd = unsafe { libc::open(path_c.as_ptr(), libc::O_RDONLY) };
            if fd < 0 {
                eprintln!("[mldr] open({guest_path}) failed");
                std::process::exit(1);
            }
            let r = unsafe { loader::map_image(fd, &macho, fat_offset) };
            dlog!(
                "[mldr] mapped: slide={:#x} mh={:#x} vm_addr_max={:#x} entry={:#x}",
                r.slide, r.mh, r.vm_addr_max, r.entry
            );
            // Sanity: the mapped mach_header must carry MH_MAGIC_64.
            if r.mh != 0 {
                let magic = unsafe { *(r.mh as *const u32) };
                dlog!("[mldr] mapped mach_header magic={magic:#x} (expect 0xfeedfacf)");
            }
            // M4: create the RPC socket, check in, and fetch the vchroot root -- all BEFORE the
            // dyld load (which needs the root) and the stack (which needs kernfd).
            dlog!(
                "[mldr] wire: sizeof(RpcCallCheckin)={} (expect 40)",
                rpc::checkin_call_size()
            );
            let mut kernfd: c_int = -1;
            let mut vchroot_root: Option<String> = None;
            // #11/#25: the checkin reply folds in this task's init constants; carry them to the
            // start stack's apple[] so libsystem_kernel seeds its caches instead of re-RPCing.
            let mut seed_task_self: u32 = 0;
            let mut seed_host_self: u32 = 0;
            let mut seed_uid: i32 = -1;
            let mut seed_gid: i32 = -1;
            if let Some(ref sockpath) = special.sockpath {
                let rpcfd = unsafe { rpc::create_socket(sockpath) };
                if rpcfd >= 0 {
                    kernfd = rpcfd;
                    // stack_hint must be a real stack address (the C passes &dummy), not the
                    // commpage base -- the daemon uses it to locate the thread's stack.
                    let hint = 0u64;
                    let checkin =
                        unsafe { rpc::checkin(rpcfd, sockpath, &hint as *const u64 as u64) };
                    dlog!(
                        "[mldr] checkin({sockpath}) -> code={} task_self={:#x} uid={} gid={}",
                        checkin.code, checkin.task_self, checkin.uid, checkin.gid
                    );
                    seed_task_self = checkin.task_self;
                    seed_host_self = checkin.host_self;
                    seed_uid = checkin.uid;
                    seed_gid = checkin.gid;
                    rpc::set_sockpath(sockpath);
                    rpc::set_thread_socket(rpcfd);
                    vchroot_root = unsafe { rpc::vchroot_path(rpcfd) };
                    dlog!("[mldr] vchroot_path -> {vchroot_root:?}");
                } else {
                    eprintln!("[mldr] rpc socket creation failed");
                }
            } else {
                eprintln!("[mldr] (no __mldr_sockpath; skipping checkin)");
            }

            // The host prefix that guest `/` lives under. Computed once here rather than inside
            // the dylinker branch where it used to sit, because it now feeds TWO things: the
            // dyld image path below, and the executable_path= handed to the guest.
            // Priority: __mldr_DYLD_ROOT_PATH (first proc) -> vchroot_path RPC (post-vchroot)
            // -> derive from guest_path minus the Mac path -> MLDR_ROOT_PATH.
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

            // apple[0] `executable_path=` MUST BE THE PATH AS THE GUEST SEES IT, not the host
            // path mldr read the file from. dyld keeps it as sExecPath, hands it back from
            // getPath(), and then RESOLVES IT: `ImageLoaderMachO::getRPaths` calls
            // `realpath(this->getPath())` before expanding `@loader_path`, and dyld2's
            // `@executable_path` branch calls `realpath(sExecPath)`. Those run in the GUEST
            // namespace, where a host path does not exist, so realpath returns NULL, getRPaths
            // pushes NOTHING, and every LC_RPATH is silently dropped. Nothing reports it either:
            // DYLD_PRINT_RPATHS only logs inside the substitution loop, which never runs when
            // the rpath list came back empty.
            //
            // MEASURED, not deduced. The official Darwin rustc could not load
            // `@rpath/librustc_driver-*.dylib` although the dylib was at /opt/rustc/lib and its
            // LC_RPATH was `@loader_path/../lib`. Symlinking the host path into the guest
            // namespace, changing nothing else, turned that into
            //     RPATH successful expansion of @rpath/librustc_driver-... to:
            //         /opt/rustc/bin/../lib/librustc_driver-...
            // and rustc ran. The trigger is exactly whether realpath resolves this string.
            //
            // Absolute-path dependencies were never affected, which is why bash and every other
            // guest worked and this stayed invisible until a binary using @rpath ran.
            //
            // Deliberately conservative: rewrite ONLY when the host path really sits under the
            // root and the remainder is still absolute. Otherwise keep the old string, so a
            // root that is not this binary's prefix (the first process gets libexec, not the
            // vchroot) cannot turn a working path into a broken one.
            let guest_exe_path = {
                let r = root.trim_end_matches('/');
                if r.is_empty() {
                    None
                } else {
                    guest_path
                        .strip_prefix(r)
                        .filter(|rest| rest.starts_with('/'))
                        .map(String::from)
                }
            }
            .unwrap_or_else(|| guest_path.clone());
            dlog!("[mldr] root={root} exe host={guest_path} guest={guest_exe_path}");

            // M3b: recursive dyld load (LC_LOAD_DYLINKER); dyld's entry is the real jump target.
            let mut final_entry = r.entry;
            if macho.header.filetype == 2 {
                // MH_EXECUTE
                if let Some(dylinker) = loader::find_dylinker(&data[fat_offset as usize..]) {
                    let dyld_path = format!("{root}{dylinker}");
                    dlog!("[mldr] dylinker={dylinker} -> {dyld_path}");
                    match std::fs::read(&dyld_path) {
                        Ok(ddata) => {
                            if let Ok(goblin::mach::Mach::Binary(dmacho)) =
                                goblin::mach::Mach::parse(&ddata)
                            {
                                let dfd =
                                    unsafe { libc::open(cstr(&dyld_path).as_ptr(), libc::O_RDONLY) };
                                let dr = unsafe { loader::map_image(dfd, &dmacho, 0) };
                                dlog!(
                                    "[mldr] dyld mapped: slide={:#x} entry={:#x}",
                                    dr.slide, dr.entry
                                );
                                final_entry = dr.entry; // dyld's entry wins
                            }
                        }
                        Err(e) => eprintln!(
                            "[mldr] dyld not found at {dyld_path}: {e} (set MLDR_ROOT_PATH)"
                        ),
                    }
                }
            }
            dlog!("[mldr] FINAL entry={final_entry:#x}");

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
            dlog!("[mldr] elf_calls vtable @ {elfcalls_addr:#x}");
            let sp = unsafe {
                stack::setup_stack(
                    0x7fff_ffe0_0000,
                    r.mh,
                    kernfd,
                    elfcalls_addr,
                    &guest_exe_path,
                    &guest_argv,
                    &envp,
                    seed_task_self,
                    seed_host_self,
                    seed_uid,
                    seed_gid,
                    vchroot_root.as_deref().unwrap_or(""),
                )
            };
            let sp0 = unsafe { *(sp as *const u64) };
            let argc = unsafe { *((sp + 8) as *const u64) };
            dlog!("[mldr] stack sp={sp:#x} sp[0](mh)={sp0:#x} argc={argc}");

            // M5b: jump into dyld -- only when we are a real guest (checked in). A test run
            // (no __mldr_sockpath) stops here rather than abandoning the Rust runtime's stack.
            if special.sockpath.is_some() {
                dlog!("[mldr] jumping to entry {final_entry:#x} with sp {sp:#x}");
                unsafe { install_trap_diag() };
                unsafe { jump::jump_to_entry(final_entry, sp) };
            } else {
                eprintln!("[mldr] (test run; not jumping -- set __mldr_sockpath to run a guest)");
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

/// Report a fault instead of dying silently, gated on `MLDR_TRAP_DIAG`.
///
/// The guest's own signal machinery is not up until libsystem initializes, so a fault before
/// that point kills the process with nothing anywhere: the daemon's sigprocess never sees it
/// (no SIGNAL_DIAG, no sigexc line) and the shell only reports "Illegal instruction". This
/// installs a handler for the fault signals BEFORE the jump so the faulting RIP and the bytes
/// there are printed. Everything it calls is async-signal-safe: a hand-rolled hex encoder and
/// one `write`, no allocation and no formatting machinery.
pub(crate) unsafe fn install_trap_diag() {
    if std::env::var_os("MLDR_TRAP_DIAG").is_none() {
        return;
    }
    unsafe extern "C" fn on_fault(sig: libc::c_int, _si: *mut libc::siginfo_t, uc: *mut libc::c_void) {
        let mut buf = [0u8; 128];
        let mut n = 0;
        for b in b"[mldr] FAULT sig=" {
            buf[n] = *b; n += 1;
        }
        buf[n] = b'0' + (sig as u8 % 10); n += 1;
        for b in b" rip=0x" {
            buf[n] = *b; n += 1;
        }
        // The faulting PC, per arch (aarch64 port, task A17): x86_64 keeps it in
        // uc_mcontext.gregs[REG_RIP] (16 on Linux), aarch64 in uc_mcontext.pc.
        let rip = if uc.is_null() {
            0u64
        } else {
            let ucp = uc as *const libc::ucontext_t;
            #[cfg(target_arch = "x86_64")]
            {
                (*ucp).uc_mcontext.gregs[16] as u64
            }
            #[cfg(target_arch = "aarch64")]
            {
                (*ucp).uc_mcontext.pc as u64
            }
        };
        for i in (0..16).rev() {
            let nib = ((rip >> (i * 4)) & 0xf) as u8;
            buf[n] = if nib < 10 { b'0' + nib } else { b'a' + nib - 10 };
            n += 1;
        }
        for b in b" insn=" {
            buf[n] = *b; n += 1;
        }
        if rip != 0 {
            let p = rip as *const u8;
            for i in 0..12 {
                let byte = *p.add(i);
                for nib in [byte >> 4, byte & 0xf] {
                    buf[n] = if nib < 10 { b'0' + nib } else { b'a' + nib - 10 };
                    n += 1;
                }
                buf[n] = b' '; n += 1;
            }
        }
        buf[n] = b'\n'; n += 1;
        libc::write(2, buf.as_ptr() as *const libc::c_void, n);
        libc::_exit(132);
    }
    for sig in [libc::SIGILL, libc::SIGSEGV, libc::SIGBUS, libc::SIGFPE] {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = on_fault as usize;
        sa.sa_flags = libc::SA_SIGINFO;
        libc::sigemptyset(&mut sa.sa_mask);
        libc::sigaction(sig, &sa, std::ptr::null_mut());
    }
    eprintln!("[mldr] trap diagnostic armed");
}
