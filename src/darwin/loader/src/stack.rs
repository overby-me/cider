// mldr M3c: build the macOS start stack that dyld expects (src/linux/startup/mldr/stack.c:56-212).
// Allocate the guest stack just below the commpage, then lay out (from the new sp upward):
//   sp[0] = pointer to the executable's in-memory mach_header (Darwin-specific)
//   sp[1] = argc
//   argv[0..argc], NULL, envp[0..envc], NULL, apple[0..3], NULL
// with the argv/envp/apple strings copied high on the same stack. The apple[] array carries
// executable_path=, kernfd=<socket fd>, and elf_calls=<vtable ptr> into libSystem.
use std::os::raw::{c_int, c_void};
use std::ptr;

/// Guest stack size: min(default, RLIMIT_STACK) (mldr.c:828-839 used 16 pages).
///
/// 8 MB, WHICH IS WHAT macOS GIVES THE MAIN THREAD, and the 16 pages this used to inherit from
/// upstream mldr.c is 64 KB, which is not enough to start a Rust binary.
///
/// MEASURED, not guessed. A Darwin Rust hello-world SIGSEGVs under cider inside
/// `dyld_stub_binder+0xF1`, which is the XSAVE buffer setup that runs before lazy binding: it
/// reads `_bufferSize32` (0xA88 = 2696 bytes), subtracts it from rsp, and zeroes upward. From
/// the core: rsp was 0x7FFFFFDF0700 and the stack base was 0x7FFFFFDF0000, so only 0x700 = 1792
/// bytes remained, and the loop ran off the bottom into the PROT_NONE page there. Rust std had
/// already used 0xF900 = 63,744 of the 65,536 bytes before dyld ever got to bind a symbol.
///
/// That is why bash survives on the same stack and a Rust binary does not: it is a startup
/// high-water-mark difference, not anything about the linker, the fixup format or TLS, all of
/// which were checked and cleared first.
fn stack_size() -> u64 {
    let default = 8 * 1024 * 1024u64;
    let mut rl: libc::rlimit = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrlimit(libc::RLIMIT_STACK, &mut rl) } == 0
        && rl.rlim_cur != libc::RLIM_INFINITY
        && rl.rlim_cur > 0
    {
        default.min(rl.rlim_cur as u64)
    } else {
        default
    }
}

/// Copy `s` (NUL-terminated) high on the stack, moving `sp` down; return the string address.
unsafe fn push_str(sp: &mut u64, s: &str) -> u64 {
    let bytes = s.as_bytes();
    *sp -= (bytes.len() + 1) as u64;
    ptr::copy_nonoverlapping(bytes.as_ptr(), *sp as *mut u8, bytes.len());
    *((*sp + bytes.len() as u64) as *mut u8) = 0;
    *sp
}

unsafe fn push_ptr(w: &mut u64, val: u64) {
    *(*w as *mut u64) = val;
    *w += 8;
}

/// Build the start stack and return the sp value to load into %rsp before jumping to dyld.
pub unsafe fn setup_stack(
    stack_top: u64, // == commpage base (0x7fffffe00000); the stack sits just below
    mh: u64,
    kernfd: c_int,
    elfcalls_addr: u64,
    exe_path: &str,
    argv: &[String],
    envp: &[String],
    // #11/#25: per-process init constants from the checkin reply, seeded into libsystem_kernel via
    // apple[]. Sentinels task_self==0 / uid<0 mean "unknown" (checkin failed) -> guest RPCs as before.
    seed_task_self: u32,
    seed_uid: i32,
    seed_gid: i32,
    // #11/#25 v2: vchroot prefix from mldr's own vchroot_path fetch; empty = unknown -> guest RPCs.
    seed_vchroot: &str,
) -> u64 {
    let size = stack_size();
    let base = stack_top - size;
    let p = libc::mmap(
        base as *mut c_void,
        size as usize,
        libc::PROT_READ | libc::PROT_WRITE,
        libc::MAP_ANONYMOUS | libc::MAP_PRIVATE | libc::MAP_FIXED_NOREPLACE | libc::MAP_GROWSDOWN,
        -1,
        0,
    );
    if p == libc::MAP_FAILED {
        eprintln!("[mldr] start-stack mmap at {base:#x} failed");
        std::process::exit(1);
    }

    let apple = [
        format!("executable_path={exe_path}"),
        format!("kernfd={kernfd}"),
        format!("elf_calls={elfcalls_addr:x}"),
        // main_stack=<stackaddr>,<stacksize>,<allocaddr>,<allocsize>, all hex. This is what
        // XNU passes and what libpthread's parse_main_stack_params() reads to fill in the
        // MAIN thread's pthread struct.
        //
        // Without it libpthread takes its fallback path: sysctl(CTL_KERN, KERN_USRSTACK),
        // which Darling answers with SUCCESS and a value of ZERO, so the USRSTACK64 constant
        // fallback never runs and the main thread ends up with stackaddr == NULL. Measured
        // with tests/buck2/guest/stack_probe.c:
        //
        //   main   main_np=1 stackaddr=0x0            stacksize=8388608
        //   worker main_np=0 stackaddr=0x7263ca5c9000 stacksize=524288
        //
        // Spawned threads were fine because their stack comes from the pthread attrs. The
        // main thread is the only one that needs this, and telling libpthread directly is
        // better than fixing the sysctl: it also carries the SIZE, and the sysctl path
        // hardcodes DFLSSIZ (8MB) for a stack that is 16 pages here, which would have left
        // WTF believing it had 8MB of room below the commpage.
        //
        // stackaddr is the HIGH address, per Darwin's pthread_get_stackaddr_np.
        //
        // The 0x PREFIXES are load-bearing. libpthread parses these with its own
        // _pthread_strtoul, whose comment says "Expect hex string starting with 0x" and
        // whose body checks p[0] == '0' && p[1] == 'x' before consuming anything. Bare hex
        // parses as zero, leaves the comma check failing, and sends the whole function down
        // the goto-out path -- which still bzeros the value, so the guest sees an empty
        // main_stack either way and the blanking proves only that the function RAN.
        // What distinguishes the two is the stacksize the probe reports: 0x10000 when this
        // parses, and 8388608 (the DFLSSIZ the sysctl fallback hardcodes) when it does not.
        format!("main_stack=0x{stack_top:x},0x{size:x},0x{base:x},0x{size:x}"),
        // #11/#25: seed the guest's per-process init caches (parsed in mach_driver_init). All hex so
        // the guest reuses __simple_atoi16; task_self=0 / uid=ffffffff (-1) mean "unknown" -> RPC.
        format!("dserver_task_self={seed_task_self:x}"),
        format!("dserver_uid={:x}", seed_uid as u32),
        format!("dserver_gid={:x}", seed_gid as u32),
        format!("dserver_vchroot={seed_vchroot}"),
    ];

    // Strings high, from stack_top downward.
    let mut str_sp = stack_top;
    let argv_ptrs: Vec<u64> = argv.iter().map(|a| push_str(&mut str_sp, a)).collect();
    let envp_ptrs: Vec<u64> = envp.iter().map(|e| push_str(&mut str_sp, e)).collect();
    let apple_ptrs: Vec<u64> = apple.iter().map(|a| push_str(&mut str_sp, a)).collect();

    // Reserve the pointer slots below the strings and 16-align sp.
    let nslots = 2 + argv.len() + 1 + envp.len() + 1 + apple.len() + 1;
    let mut sp = (str_sp & !0xf) - (nslots as u64 * 8);
    sp &= !0xf;

    // Pointer array from sp upward.
    let mut w = sp;
    push_ptr(&mut w, mh);
    push_ptr(&mut w, argv.len() as u64);
    for &pp in &argv_ptrs {
        push_ptr(&mut w, pp);
    }
    push_ptr(&mut w, 0);
    for &pp in &envp_ptrs {
        push_ptr(&mut w, pp);
    }
    push_ptr(&mut w, 0);
    for &pp in &apple_ptrs {
        push_ptr(&mut w, pp);
    }
    push_ptr(&mut w, 0);
    sp
}
