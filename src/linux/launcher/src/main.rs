// cider -- the Darling launcher, Rust rewrite of src/linux/startup/cider.c (task #64).
//
// Responsibilities (cider.c does NO mounts/vchroot -- ciderd owns those):
//   1. Acquire privilege: rootless user-namespace re-exec (or setuid-root).
//   2. Bootstrap the prefix dir tree + passwd/group on first run.
//   3. Start / validate / join / tear down the container by running ciderd
//      as the container init, coordinating readiness (sync pipe + shellspawn.sock poll).
//   4. Connect to the guest shellspawn socket and proxy one shell/binary.
//
// PHASE A (this file): the full boot path + the non-interactive proxy (direct fd
// passing), which is exactly what the boot-stress exercises. PHASE B adds the PTY /
// interactive path, signal forwarding, and the startup watchdog's killContainer.
//
// Raw libc only, to match the server crate and build offline. Line refs are to the
// C original for maintainability.
#![allow(dead_code)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

// ---- compile-time config (darling-config.h / shellspawn.h) ----
const SYSTEM_ROOT: &str = "/Volumes/SystemRoot";
const SHELLSPAWN_SOCKPATH: &str = "/var/run/shellspawn.sock";
const INSTALL_PREFIX: &str = env!("CIDER_INSTALL_PREFIX");
const GIT_BRANCH: &str = env!("CIDER_GIT_BRANCH");
const GIT_COMMIT: &str = env!("CIDER_GIT_COMMIT");

// ---- shellspawn wire protocol (src/darwin/shellspawn/shellspawn.h) ----
const SHELLSPAWN_ADDARG: u16 = 1;
const SHELLSPAWN_SETENV: u16 = 2;
const SHELLSPAWN_CHDIR: u16 = 3;
const SHELLSPAWN_GO: u16 = 4;
const SHELLSPAWN_SIGNAL: u16 = 5;
const SHELLSPAWN_SETUIDGID: u16 = 6;
const SHELLSPAWN_SETEXEC: u16 = 7;

// Globals for the interactive proxy (Phase B): the signal self-pipe, the pty master, and
// the shellspawn socket, so the async-signal handler and the atexit termios-restore can
// reach them without threading state through the loop.
static SELF_PIPE_R: AtomicI32 = AtomicI32::new(-1);
static SELF_PIPE_W: AtomicI32 = AtomicI32::new(-1);
static PTY_MASTER: AtomicI32 = AtomicI32::new(-1);
static SHSOCK: AtomicI32 = AtomicI32::new(-1);
static TERMIOS_SAVED: AtomicBool = AtomicBool::new(false);
static mut ORIG_TERMIOS: std::mem::MaybeUninit<libc::termios> = std::mem::MaybeUninit::uninit();

/// Launcher-wide state, the C globals g_originalUid/Gid/workingDirectory/fixPermissions.
struct Ctx {
    prefix: String,
    orig_uid: u32,
    orig_gid: u32,
    working_dir: String,
    fix_permissions: bool,
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() <= 1 {
        show_help();
        std::process::exit(1);
    }

    // Privilege gate (cider.c:131-142).
    if unsafe { libc::geteuid() } != 0 {
        if std::env::var_os("CIDER_USERNS_STAGE2").is_none() {
            enter_userns_and_reexec(&argv); // only returns on failure
            missing_setuid_root();
        } else {
            missing_setuid_root();
        }
    }
    std::env::remove_var("CIDER_USERNS_STAGE2");

    // Capture identity (cider.c:144-148). Rootless: getuid()==0 inside the userns,
    // so orig_uid/gid == 0 and every owner/seteuid check downstream is a no-op.
    let orig_uid = unsafe { libc::getuid() };
    let orig_gid = unsafe { libc::getgid() };
    unsafe {
        libc::setuid(0);
        libc::setgid(0);
    }

    // Resolve prefix (cider.c:150-161).
    let prefix = match std::env::var("CIDERPREFIX") {
        Ok(p) if !p.is_empty() => p,
        _ => default_prefix_path(),
    };
    if prefix.len() > 255 {
        die("Prefix path too long (>255)");
    }
    std::env::remove_var("CIDERPREFIX");
    let working_dir = getcwd();

    let mut ctx = Ctx {
        prefix,
        orig_uid,
        orig_gid,
        working_dir,
        fix_permissions: false,
    };

    // Prefix bootstrap (cider.c:163-168).
    if !check_prefix_dir(&ctx.prefix) {
        setup_prefix(&ctx);
        ctx.fix_permissions = true;
    } else {
        // An existing prefix may predate a directory the runtime now needs; see ensure_prefix_dirs.
        ensure_prefix_dirs(&ctx);
    }
    check_prefix_owner(&ctx);

    // --help / --version only when they precede the subcommand (getopt "+" semantics,
    // cider.c:170-207).
    match argv[1].as_str() {
        "--help" | "-h" => {
            show_help();
            std::process::exit(0);
        }
        "--version" | "-v" => {
            show_version();
            std::process::exit(0);
        }
        _ => {}
    }

    let mut pid_init = get_init_process(&ctx); // cider.c:209

    // shutdown subcommand, handled before any ns work (cider.c:211-239).
    if argv[1] == "shutdown" {
        do_shutdown(pid_init);
        std::process::exit(0);
    }

    // Stale-container reap (cider.c:246-255): a prior rootless container lives in a
    // different userns whose mnt ns we cannot setns into -> discard + restart.
    if pid_init != 0 && !container_joinable(pid_init) {
        kill_container(&ctx);
        let _ = std::fs::remove_file(format!("{}/.init.pid", ctx.prefix));
        let _ = std::fs::remove_file(format!("{}{}", ctx.prefix, SHELLSPAWN_SOCKPATH));
        pid_init = 0;
    }

    // Start the container if none (cider.c:258-283).
    if pid_init == 0 {
        let _ = std::fs::remove_file(format!("{}{}", ctx.prefix, SHELLSPAWN_SOCKPATH));
        setup_workdir(&ctx);
        pid_init = spawn_init_process(&ctx); // blocks on the sync pipe until mounts ready
        put_init_pid(&ctx, pid_init);
        // Poll for the guest to boot shellspawn, up to 360s (cider.c:277-282).
        let sock = format!("{}{}", ctx.prefix, SHELLSPAWN_SOCKPATH);
        let sock_c = cstr(&sock);
        let mut ok = false;
        for _ in 0..3600 {
            if unsafe { libc::access(sock_c.as_ptr(), libc::F_OK) } == 0 {
                ok = true;
                break;
            }
            unsafe { libc::usleep(100 * 1000) };
        }
        if !ok {
            die("Timed out waiting for the guest shellspawn socket");
        }
    }

    // Join the container mnt ns so we can connect to the overlay-resident socket
    // (cider.c:285-287, the Linux 4.11 / overlayfs socket hack), through its user ns when it has
    // one of its own: see try_enter_container for why the order matters.
    if !same_namespace(pid_init, "user") {
        join_namespace(pid_init, libc::CLONE_NEWUSER, "user");
    }
    join_namespace(pid_init, libc::CLONE_NEWNS, "mnt");

    // Drop euid (cider.c:289; no-op rootless).
    unsafe { libc::seteuid(ctx.orig_uid) };

    // Dispatch (cider.c:291-330).
    match argv[1].as_str() {
        "shell" => spawn_shell(&ctx, &argv[2..]),
        "exec" => {
            if argv.len() <= 2 {
                die("exec requires a binary path");
            }
            let full = full_path(&argv[2]);
            let mut a = vec![full.clone()];
            a.extend_from_slice(&argv[3..]);
            spawn_binary(&ctx, &full, &a);
        }
        _ => {
            // Bare `cider <prog> [args]`: realpath+SYSTEM_ROOT, shell-wrapped.
            let full = full_path(&argv[1]);
            let mut a = vec![full];
            a.extend_from_slice(&argv[2..]);
            spawn_shell(&ctx, &a);
        }
    }
}

// ======================= privilege (cider.c:65-103) =======================

fn enter_userns_and_reexec(argv: &[String]) {
    // Capture the REAL ids before entering the new userns (cider.c:80-81).
    let ruid = unsafe { libc::getuid() };
    let rgid = unsafe { libc::getgid() };
    if unsafe { libc::unshare(libc::CLONE_NEWUSER) } != 0 {
        return; // unsupported -> caller -> missing_setuid_root
    }
    // setgroups=deny is mandatory before an unprivileged gid_map write; order matters.
    if !write_string_to_file("/proc/self/setgroups", "deny") {
        return;
    }
    if !write_string_to_file("/proc/self/uid_map", &format!("0 {ruid} 1\n")) {
        return;
    }
    if !write_string_to_file("/proc/self/gid_map", &format!("0 {rgid} 1\n")) {
        return;
    }
    std::env::set_var("CIDER_USERNS_STAGE2", "1");
    // execv(/proc/self/exe, argv) -- returns only on failure.
    let exe = cstr("/proc/self/exe");
    let cargs: Vec<CString> = argv.iter().map(|a| cstr(a)).collect();
    let mut ptrs: Vec<*const c_char> = cargs.iter().map(|c| c.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    unsafe { libc::execv(exe.as_ptr(), ptrs.as_ptr()) };
}

fn write_string_to_file(path: &str, content: &str) -> bool {
    let p = cstr(path);
    let fd = unsafe { libc::open(p.as_ptr(), libc::O_WRONLY) };
    if fd < 0 {
        return false;
    }
    let bytes = content.as_bytes();
    let n = unsafe { libc::write(fd, bytes.as_ptr() as *const c_void, bytes.len()) };
    unsafe { libc::close(fd) };
    n == bytes.len() as isize
}

fn missing_setuid_root() -> ! {
    eprintln!(
        "cider: cannot set up a container: need unprivileged user namespaces \
         (sysctl kernel.unprivileged_userns_clone=1) or a setuid-root cider binary."
    );
    std::process::exit(1);
}

// ======================= prefix (cider.c:1075-1269) =======================

fn default_prefix_path() -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => format!("{h}/.cider"),
        _ => die("HOME is not set and CIDERPREFIX was not given"),
    }
}

fn check_prefix_dir(prefix: &str) -> bool {
    let p = cstr(prefix);
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::stat(p.as_ptr(), &mut st) } == 0 {
        if (st.st_mode & libc::S_IFMT) == libc::S_IFDIR {
            return true;
        }
        die("The prefix path exists but is not a directory");
    }
    if errno() == libc::ENOENT {
        return false;
    }
    die("Cannot stat the prefix directory");
}

fn check_prefix_owner(ctx: &Ctx) {
    if ctx.orig_uid == 0 {
        return; // rootless: skip
    }
    let p = cstr(&ctx.prefix);
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::stat(p.as_ptr(), &mut st) } == 0 && st.st_uid != ctx.orig_uid {
        die("You do not own the prefix directory");
    }
}

fn setup_workdir(ctx: &Ctx) {
    let p = ctx.prefix.trim_end_matches('/');
    create_dir(&format!("{p}.workdir"));
}

fn create_dir(path: &str) {
    let p = cstr(path);
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::stat(p.as_ptr(), &mut st) } == 0 {
        if (st.st_mode & libc::S_IFMT) != libc::S_IFDIR {
            die(&format!("{path} exists but is not a directory"));
        }
        return;
    }
    if errno() == libc::ENOENT {
        if unsafe { libc::mkdir(p.as_ptr(), 0o755) } != 0 {
            die(&format!("Cannot create directory {path}"));
        }
        return;
    }
    die(&format!("Cannot stat {path}"));
}

/// The directories the runtime needs, made on EVERY launch rather than only at creation.
///
/// setup_prefix runs once, when a prefix is first made, so a prefix created by an older build never
/// gains a directory added later. That is not theoretical: a prefix here was missing /var/tmp, and
/// launchd puts its client socket in /var/tmp/launchd, so mkdir failed with ENOENT, ipc_server_init
/// gave up, job_mig_getsocket answered BOOTSTRAP_NO_MEMORY, and every launchctl reported
/// "launch_msg(): Socket is not connected". The container never came up, and nothing said why.
///
/// Making the list idempotent costs a handful of stat calls per launch and repairs such a prefix
/// in place.
fn ensure_prefix_dirs(ctx: &Ctx) {
    create_dir(&ctx.prefix);
    for d in [
        "/Volumes",
        "/Applications",
        "/usr",
        "/usr/local",
        "/usr/local/share",
        "/private",
        "/private/tmp",
        "/private/var",
        "/private/var/log",
        "/private/var/db",
        // launchd as PID 1 puts its client socket in _PATH_VARTMP/launchd, and mkdir does not
        // create parents, so without this its ipc_server_init gives up and every launchctl says
        // "launch_msg(): Socket is not connected". NECESSARY BUT NOT SUFFICIENT, measured: with
        // the directory present launchd still never creates the socket, because the MIG call that
        // would ask it to never reaches launchd. See docs/wayland-port.md.
        "/private/var/tmp",
        // the job overrides database launchctl opens on startup
        "/private/var/db/launchd.db",
        "/private/var/db/launchd.db/com.apple.launchd",
        "/private/etc",
        "/var",
        "/var/run",
        "/var/tmp",
        "/var/log",
    ] {
        create_dir(&format!("{}{}", ctx.prefix, d));
    }

    /*
     * /tmp IS A SYMLINK ON macOS, and here it was a directory or nothing at all.
     *
     * The runtime sets TMPDIR to /private/tmp and creates it, so anything that asks the system for a
     * temporary directory lands there, while anything that writes to the literal /tmp lands in a
     * different place or fails. scripts/run-tests.nu copies its sources to <prefix>/private/tmp and
     * compiles them at /tmp, which is the same path on macOS and two places here: cd said No such
     * file or directory and the harness reported that the toolchain was broken.
     *
     * Only an ABSENT or EMPTY /tmp is replaced. A prefix whose /tmp already holds files keeps it,
     * because moving a running container's temporary files is not this function's business. /var and
     * /etc are symlinks on macOS too and are left as real directories here deliberately: they hold
     * runtime state already and nothing has asked for that yet.
     */
    ensure_private_symlink(&ctx.prefix, "/tmp", "private/tmp");
}

fn ensure_private_symlink(prefix: &str, at: &str, target: &str) {
    let path = format!("{prefix}{at}");

    match std::fs::symlink_metadata(&path) {
        Ok(md) if md.file_type().is_symlink() => return,
        Ok(md) if md.is_dir() => {
            let empty = std::fs::read_dir(&path).map(|mut d| d.next().is_none()).unwrap_or(false);

            if !empty {
                return;
            }
            let _ = std::fs::remove_dir(&path);
        }
        Ok(_) => return,
        Err(_) => {}
    }
    let _ = std::os::unix::fs::symlink(target, &path);
}

fn setup_prefix(ctx: &Ctx) {
    unsafe {
        libc::seteuid(ctx.orig_uid);
        libc::setegid(ctx.orig_gid);
    }
    ensure_prefix_dirs(ctx);
    let (name, uid, gid) = get_user_info(ctx.orig_uid);
    write_prefix_file(
        ctx,
        "/private/etc/passwd",
        &format!(
            "root:*:0:0:System Administrator:/var/root:/bin/sh\n\
             {name}:*:{uid}:{gid}:Darling User:/Users/{name}:/bin/bash\n"
        ),
    );
    write_prefix_file(
        ctx,
        "/private/etc/master.passwd",
        &format!(
            "root:*:0:0::0:0:System Administrator:/var/root:/bin/sh\n\
             {name}:*:{uid}:{gid}::0:0:Darling User:/Users/{name}:/bin/bash\n"
        ),
    );
    write_prefix_file(
        ctx,
        "/private/etc/group",
        &format!("wheel:*:0:root,{name}\n{name}:*:{gid}:{name}\n"),
    );
    unsafe {
        libc::seteuid(0);
        libc::setegid(0);
    }
}

fn write_prefix_file(ctx: &Ctx, rel: &str, content: &str) {
    let _ = std::fs::write(format!("{}{}", ctx.prefix, rel), content);
}

fn get_user_info(uid: u32) -> (String, u32, u32) {
    unsafe {
        let pw = libc::getpwuid(uid);
        if !pw.is_null() && !(*pw).pw_name.is_null() {
            let name = CStr::from_ptr((*pw).pw_name).to_string_lossy().into_owned();
            return (name, (*pw).pw_uid, (*pw).pw_gid);
        }
    }
    ("cider".to_string(), uid, uid)
}

// ==================== container lifecycle (cider.c) ====================

fn get_init_process(ctx: &Ctx) -> i32 {
    let path = format!("{}/.init.pid", ctx.prefix);
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return 0,
    };
    let pid: i32 = match content.trim().parse() {
        Ok(p) => p,
        Err(_) => {
            let _ = std::fs::remove_file(&path);
            return 0;
        }
    };
    // liveness (cider.c:1310-ish)
    if unsafe { libc::kill(pid, 0) } != 0 && errno() == libc::ESRCH {
        let _ = std::fs::remove_file(&path);
        return 0;
    }
    // comm must be "ciderd" (cider.c:1323)
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
    if comm.trim() != "ciderd" {
        let _ = std::fs::remove_file(&path);
        return 0;
    }
    // setuid mode only: /proc/<pid>/status Uid/Gid must match (cider.c:1331)
    if ctx.orig_uid != 0 && !status_matches_ids(pid, ctx.orig_uid, ctx.orig_gid) {
        let _ = std::fs::remove_file(&path);
        return 0;
    }
    pid
}

fn status_matches_ids(pid: i32, uid: u32, gid: u32) -> bool {
    let s = match std::fs::read_to_string(format!("/proc/{pid}/status")) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let (mut uok, mut gok) = (false, false);
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            uok = rest
                .split_whitespace()
                .all(|f| f.parse::<u32>().map(|v| v == uid).unwrap_or(false));
        } else if let Some(rest) = line.strip_prefix("Gid:") {
            gok = rest
                .split_whitespace()
                .all(|f| f.parse::<u32>().map(|v| v == gid).unwrap_or(false));
        }
    }
    uok && gok
}

/// Whether a surviving container can actually be ENTERED, which is not the same question as
/// whether its namespace files can be opened.
///
/// This used to open /proc/<pid>/ns/mnt and answer yes if that succeeded. Opening succeeds for any
/// live process this user can see; setns is what fails. So a container left by a previous
/// invocation was declared joinable, the reap-and-restart path above was skipped, and the join a
/// few lines later died with "Cannot join mnt namespace of pid N". THE ONLY HONEST TEST OF A
/// SYSCALL IS THE SYSCALL, and setns cannot be undone in this process, so a forked child does it
/// and reports by exit status.
fn container_joinable(pid: i32) -> bool {
    let child = unsafe { libc::fork() };

    if child < 0 {
        return false;
    }
    if child == 0 {
        let ok = try_enter_container(pid);
        unsafe { libc::_exit(if ok { 0 } else { 1 }) };
    }

    let mut status: c_int = 0;
    if unsafe { libc::waitpid(child, &mut status, 0) } != child {
        return false;
    }
    libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0
}

/// The two setns calls a caller needs, in the order the kernel requires.
///
/// A rootless container lives in a user namespace of its own, and setns(CLONE_NEWNS) demands
/// CAP_SYS_ADMIN in the user namespace that OWNS the mount namespace. The invocation that created
/// the container has that; a later one does not, which is why a second cider shell in the same
/// prefix used to fail while the first succeeded. Joining the user namespace first grants those
/// capabilities, exactly as nsenter -U -m does.
fn try_enter_container(pid: i32) -> bool {
    if !same_namespace(pid, "user") && !setns_path(pid, "user", libc::CLONE_NEWUSER) {
        return false;
    }
    setns_path(pid, "mnt", libc::CLONE_NEWNS)
}

fn same_namespace(pid: i32, name: &str) -> bool {
    let mine = std::fs::read_link(format!("/proc/self/ns/{name}")).ok();
    let theirs = std::fs::read_link(format!("/proc/{pid}/ns/{name}")).ok();

    mine.is_some() && mine == theirs
}

fn setns_path(pid: i32, name: &str, nstype: c_int) -> bool {
    let p = cstr(&format!("/proc/{pid}/ns/{name}"));
    let fd = unsafe { libc::open(p.as_ptr(), libc::O_RDONLY) };

    if fd < 0 {
        return false;
    }
    let ok = unsafe { libc::setns(fd, nstype) } == 0;
    unsafe { libc::close(fd) };
    ok
}

fn join_namespace(pid: i32, nstype: c_int, name: &str) {
    let p = cstr(&format!("/proc/{pid}/ns/{name}"));
    let fd = unsafe { libc::open(p.as_ptr(), libc::O_RDONLY) };
    if fd < 0 {
        die(&format!("Cannot open {name} namespace of pid {pid}"));
    }
    if unsafe { libc::setns(fd, nstype) } != 0 {
        die(&format!("Cannot join {name} namespace of pid {pid}"));
    }
    unsafe { libc::close(fd) };
}

fn spawn_init_process(ctx: &Ctx) -> i32 {
    let mut pipefd = [0 as c_int; 2];
    if unsafe { libc::pipe(pipefd.as_mut_ptr()) } != 0 {
        die("pipe() failed");
    }
    // Fresh UTS+IPC ns in the PARENT before fork, so launcher + daemon share them
    // (cider.c:967).
    if unsafe { libc::unshare(libc::CLONE_NEWUTS | libc::CLONE_NEWIPC) } != 0 {
        die("unshare(CLONE_NEWUTS|CLONE_NEWIPC) failed");
    }
    // Build every CString BEFORE fork -- the child must be async-signal-safe (no alloc).
    let ds_bin = ds_bin_path();
    let ds_bin_c = cstr(&ds_bin);
    let argv0 = cstr("ciderd");
    let prefix_c = cstr(&ctx.prefix);
    let uid_c = cstr(&ctx.orig_uid.to_string());
    let gid_c = cstr(&ctx.orig_gid.to_string());
    let pipe_c = cstr(&pipefd[1].to_string());
    let fixperm_c = cstr(if ctx.fix_permissions { "1" } else { "0" });
    // Pre-built (the child is async-signal-safe, no alloc): detach the daemon's stdio.
    // The daemon -- and the shellspawn init it spawns -- are PERSISTENT (the launcher
    // reuses a joinable container), so if they inherit the launcher's fd-0/1/2 they pin
    // the CALLER's stdout open forever and a one-shot `cider <cmd>` never sees its pipe
    // close (looks like a hang; the launcher can't exit). Per-command guest output flows
    // via explicit shellspawn fd-passing, not inheritance, so redirecting the daemon's
    // own stdio is safe. Validated: the launcher now exits cleanly after a one-shot cmd.
    let devnull_c = cstr("/dev/null");
    let log_c = cstr(&format!("{}/ciderd.log", ctx.prefix));
    let argv: [*const c_char; 7] = [
        argv0.as_ptr(),
        prefix_c.as_ptr(),
        uid_c.as_ptr(),
        gid_c.as_ptr(),
        pipe_c.as_ptr(),
        fixperm_c.as_ptr(),
        std::ptr::null(),
    ];
    let (read_fd, write_fd) = (pipefd[0], pipefd[1]);

    let pid = unsafe { libc::fork() };
    if pid < 0 {
        die("fork() failed");
    }
    if pid == 0 {
        // CHILD: async-signal-safe only -- close, open/dup2, execv, _exit. No allocation.
        unsafe {
            libc::close(read_fd);
            // stdin <- /dev/null, stdout+stderr -> prefix/ciderd.log, so the
            // persistent daemon/shellspawn release the caller's fd-0/1/2 (fixes the
            // one-shot teardown hang). Readiness sync uses its own high fd (pipefd[1]).
            let nfd = libc::open(devnull_c.as_ptr(), libc::O_RDONLY);
            if nfd >= 0 {
                libc::dup2(nfd, 0);
                if nfd > 2 {
                    libc::close(nfd);
                }
            }
            let lfd = libc::open(
                log_c.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_APPEND,
                0o644 as libc::c_int,
            );
            if lfd >= 0 {
                libc::dup2(lfd, 1);
                libc::dup2(lfd, 2);
                if lfd > 2 {
                    libc::close(lfd);
                }
            }
            libc::execv(ds_bin_c.as_ptr(), argv.as_ptr());
            libc::_exit(1);
        }
    }
    // PARENT: close the write end and block until the daemon signals mounts ready.
    unsafe {
        libc::close(write_fd);
        let mut b = [0u8; 1];
        libc::read(read_fd, b.as_mut_ptr() as *mut c_void, 1);
        libc::close(read_fd);
    }
    pid
}

fn ds_bin_path() -> String {
    if let Ok(p) = std::env::var("DSERVER_PATH") {
        if !p.is_empty() {
            return p;
        }
    }
    // Resolve the daemon next to our own binary (same bin/ dir) -- relocatable, so the
    // installed launcher needs no baked absolute prefix. Falls back to INSTALL_PREFIX.
    if let Ok(exe) = std::fs::read_link("/proc/self/exe") {
        if let Some(dir) = exe.parent() {
            let cand = dir.join("ciderd");
            if cand.exists() {
                return cand.to_string_lossy().into_owned();
            }
        }
    }
    format!("{INSTALL_PREFIX}/bin/ciderd")
}

fn put_init_pid(ctx: &Ctx, pid: i32) {
    unsafe {
        libc::seteuid(ctx.orig_uid);
        libc::setegid(ctx.orig_gid);
    }
    let _ = std::fs::write(format!("{}/.init.pid", ctx.prefix), pid.to_string());
    unsafe {
        libc::seteuid(0);
        libc::setegid(0);
    }
}

fn kill_container(ctx: &Ctx) {
    // Read the pid DIRECTLY from .init.pid (getInitProcess returns 0 rootless).
    let content = match std::fs::read_to_string(format!("{}/.init.pid", ctx.prefix)) {
        Ok(c) => c,
        Err(_) => return,
    };
    let pid: i32 = match content.trim().parse() {
        Ok(p) => p,
        Err(_) => return,
    };
    if let Ok(children) = std::fs::read_to_string(format!("/proc/{pid}/task/{pid}/children")) {
        for c in children.split_whitespace() {
            if let Ok(cp) = c.parse::<i32>() {
                unsafe { libc::kill(cp, libc::SIGKILL) };
            }
        }
    }
    unsafe { libc::kill(pid, libc::SIGKILL) };
}

fn do_shutdown(pid_init: i32) {
    if pid_init == 0 {
        die("There is no cider container running");
    }
    if let Ok(children) =
        std::fs::read_to_string(format!("/proc/{pid_init}/task/{pid_init}/children"))
    {
        if let Some(first) = children.split_whitespace().next() {
            if let Ok(lp) = first.parse::<i32>() {
                unsafe { libc::kill(lp, libc::SIGKILL) };
            }
        }
    }
    unsafe { libc::kill(pid_init, libc::SIGKILL) };
}

// ==================== shellspawn client (cider.c:360-916) ====================

fn spawn_shell(ctx: &Ctx, args: &[String]) -> ! {
    let sockfd = connect_shellspawn(ctx);
    setup_shellspawn_env(sockfd);
    // Join args into one single-quoted -c string (cider.c:852-897).
    if !args.is_empty() {
        let joined = args
            .iter()
            .map(|a| single_quote(a))
            .collect::<Vec<_>>()
            .join(" ");
        push_cmd(sockfd, SHELLSPAWN_ADDARG, b"-c");
        push_cmd(sockfd, SHELLSPAWN_ADDARG, joined.as_bytes());
    }
    setup_working_dir(ctx, sockfd);
    setup_ids(ctx, sockfd);
    let (fds, master) = setup_fds();
    install_signal_forwarding(sockfd, master);
    spawn_go(sockfd, &fds);
    shell_loop(ctx, sockfd, master)
}

fn spawn_binary(ctx: &Ctx, binary: &str, args: &[String]) -> ! {
    let sockfd = connect_shellspawn(ctx);
    setup_shellspawn_env(sockfd);
    push_cmd(sockfd, SHELLSPAWN_SETEXEC, binary.as_bytes());
    for a in args {
        push_cmd(sockfd, SHELLSPAWN_ADDARG, a.as_bytes());
    }
    setup_working_dir(ctx, sockfd);
    setup_ids(ctx, sockfd);
    let (fds, master) = setup_fds();
    install_signal_forwarding(sockfd, master);
    spawn_go(sockfd, &fds);
    shell_loop(ctx, sockfd, master)
}

fn connect_shellspawn(ctx: &Ctx) -> c_int {
    let path = format!("{}{}", ctx.prefix, SHELLSPAWN_SOCKPATH);
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        die("socket(AF_UNIX) failed");
    }
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let pbytes = path.as_bytes();
    if pbytes.len() >= addr.sun_path.len() {
        die("shellspawn socket path too long");
    }
    for (i, &b) in pbytes.iter().enumerate() {
        addr.sun_path[i] = b as c_char;
    }
    let r = unsafe {
        libc::connect(
            fd,
            &addr as *const _ as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
        )
    };
    if r < 0 {
        die("connect() to the shellspawn socket failed");
    }
    fd
}

fn push_cmd(fd: c_int, cmd: u16, data: &[u8]) {
    // packed shellspawn_cmd { u16 cmd; u16 data_length; char data[]; }
    let mut buf = Vec::with_capacity(4 + data.len());
    buf.extend_from_slice(&cmd.to_le_bytes());
    buf.extend_from_slice(&(data.len() as u16).to_le_bytes());
    buf.extend_from_slice(data);
    write_all(fd, &buf);
}

fn setup_shellspawn_env(fd: c_int) {
    let login = get_login();

    push_env(fd, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin");
    push_env(fd, "TMPDIR", "/private/tmp");
    push_env(fd, "HOME", &format!("/Users/{login}"));
    // SHELL IS A PATH, AND A HOST PATH MEANS NOTHING IN HERE. On a nix host it is something like
    // /nix/store/...-bash-5.3p9/bin/bash, which does not exist inside the container, so every
    // application that launches "the user shell" from it fails to exec and reports a broken pipe
    // with no other explanation. iTerm2 opens a session that way. The guest ships /bin/bash.
    push_env(fd, "SHELL", "/bin/bash");
    // AND A HOST USERNAME IS NO BETTER THAN A HOST PATH. These were inherited straight from the
    // host, so USER said overby.me while HOME said /Users/root, and the only account this
    // container has is root. Anything that resolves the name gets nothing: iTerm2 opens its
    // session with login -fp $USER, getpwnam answered NULL, and login printed Login incorrect and
    // sat at a prompt. The terminal drew perfectly and could not run a shell.
    push_env(fd, "USER", &login);
    push_env(fd, "LOGNAME", &login);
    for (k, v) in std::env::vars() {
        if k == "PATH"
            || k == "TMPDIR"
            || k == "HOME"
            || k == "SHELL"
            || k == "USER"
            || k == "LOGNAME"
        {
            continue;
        }
        push_env(fd, &k, &v);
    }
}

fn push_env(fd: c_int, k: &str, v: &str) {
    push_cmd(fd, SHELLSPAWN_SETENV, format!("{k}={v}").as_bytes());
}

fn get_login() -> String {
    unsafe {
        let pw = libc::getpwuid(libc::geteuid());
        if !pw.is_null() && !(*pw).pw_name.is_null() {
            return CStr::from_ptr((*pw).pw_name).to_string_lossy().into_owned();
        }
        let l = libc::getlogin();
        if !l.is_null() {
            return CStr::from_ptr(l).to_string_lossy().into_owned();
        }
    }
    "unknown".to_string()
}

fn setup_working_dir(ctx: &Ctx, fd: c_int) {
    push_cmd(
        fd,
        SHELLSPAWN_CHDIR,
        format!("{}{}", SYSTEM_ROOT, ctx.working_dir).as_bytes(),
    );
}

fn setup_ids(ctx: &Ctx, fd: c_int) {
    let ids = [ctx.orig_uid as i32, ctx.orig_gid as i32];
    let bytes = unsafe { std::slice::from_raw_parts(ids.as_ptr() as *const u8, 8) };
    push_cmd(fd, SHELLSPAWN_SETUIDGID, bytes);
}

/// setupFDs/setupPtys (cider.c:655-838). Interactive (isatty(stdin)): allocate a PTY,
/// raw-mode our terminal, hand the slave to the guest as all three fds, keep the master.
/// Non-interactive: pass our real stdio directly. Returns (guest_fds, pty_master|-1).
fn setup_fds() -> ([c_int; 3], c_int) {
    unsafe {
        if libc::isatty(0) == 1 {
            let (master, slave) = openpty_cider();
            setup_raw_termios(master);
            ([slave, slave, slave], master)
        } else {
            ([libc::dup(0), libc::dup(1), libc::dup(2)], -1)
        }
    }
}

fn spawn_go(fd: c_int, fds: &[c_int; 3]) {
    send_go_with_fds(fd, fds);
    unsafe { libc::close(fds[0]) };
}

fn send_go_with_fds(fd: c_int, fds: &[c_int; 3]) {
    // GO header: packed shellspawn_cmd { cmd=GO, data_length=0 }.
    let mut hdr = [0u8; 4];
    hdr[0..2].copy_from_slice(&SHELLSPAWN_GO.to_le_bytes());
    let mut iov = libc::iovec {
        iov_base: hdr.as_mut_ptr() as *mut c_void,
        iov_len: hdr.len(),
    };
    let fdbytes = 3 * std::mem::size_of::<c_int>() as u32;
    let cmsg_space = unsafe { libc::CMSG_SPACE(fdbytes) } as usize;
    let mut cbuf = vec![0u8; cmsg_space];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf.as_mut_ptr() as *mut c_void;
    msg.msg_controllen = cmsg_space as _;
    unsafe {
        let cmsg = libc::CMSG_FIRSTHDR(&msg);
        (*cmsg).cmsg_level = libc::SOL_SOCKET;
        (*cmsg).cmsg_type = libc::SCM_RIGHTS;
        (*cmsg).cmsg_len = libc::CMSG_LEN(fdbytes) as _;
        std::ptr::copy_nonoverlapping(fds.as_ptr(), libc::CMSG_DATA(cmsg) as *mut c_int, 3);
        if libc::sendmsg(fd, &msg, 0) < 0 {
            die("sendmsg(GO) failed");
        }
    }
}

/// The proxy loop (cider.c shellLoop:491-621). Poll fds: [0]=sockfd, [1]=signal
/// self-pipe, and for an interactive PTY [2]=stdin, [3]=master. Non-interactive keeps
/// only sockfd + self-pipe (the guest holds our real fds directly). Watchdog bounds the
/// pre-"started" wait (DARLING_SHELL_STARTUP_TIMEOUT, default 60s) then killContainer +
/// exit(120) so a captured stdout pipe is released.
fn shell_loop(ctx: &Ctx, sockfd: c_int, master: c_int) -> ! {
    let pipe_r = SELF_PIPE_R.load(Ordering::SeqCst);
    let mut started = false;
    let startup_to = startup_timeout();
    loop {
        let mut pfds = [
            libc::pollfd { fd: sockfd, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: pipe_r, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: if master != -1 { 0 } else { -1 }, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 },
        ];
        let n: libc::nfds_t = if master != -1 { 4 } else { 2 };
        let timeout = if started || startup_to <= 0 { -1 } else { startup_to * 1000 };
        let r = unsafe { libc::poll(pfds.as_mut_ptr(), n, timeout) };
        if r < 0 {
            if errno() == libc::EINTR {
                continue;
            }
            die("poll() failed");
        }
        if r == 0 && !started {
            eprintln!("cider: timed out waiting for the guest program to start");
            kill_container(ctx);
            exit_clean(120);
        }
        // pty master -> our stdout
        if master != -1 && pfds[3].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            pump(master, 1);
        }
        // our stdin -> pty master
        if master != -1 && pfds[2].revents & libc::POLLIN != 0 {
            pump(0, master);
        }
        // forwarded signals
        if pfds[1].revents & libc::POLLIN != 0 {
            drain_signals(pipe_r, master);
        }
        // socket: the 1-byte started marker, then the 4-byte exit status
        if pfds[0].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            if !started {
                let mut b = [0u8; 1];
                let rn = unsafe { libc::read(sockfd, b.as_mut_ptr() as *mut c_void, 1) };
                if rn == 1 {
                    started = true;
                } else {
                    exit_clean(1); // EOF before the started marker
                }
            } else {
                let mut st = [0u8; 4];
                if read_full(sockfd, &mut st) == 4 {
                    exit_clean(i32::from_le_bytes(st));
                }
                exit_clean(1);
            }
        }
    }
}

// ===================== interactive PTY + signals (Phase B) =====================

unsafe fn openpty_cider() -> (c_int, c_int) {
    // Lenient openpty (cider.c:630-653): tolerate grantpt EPERM (Debian).
    let master = libc::posix_openpt(libc::O_RDWR);
    if master < 0 {
        die("posix_openpt() failed");
    }
    libc::grantpt(master); // return ignored on purpose
    if libc::unlockpt(master) != 0 {
        die("unlockpt() failed");
    }
    let name = libc::ptsname(master);
    if name.is_null() {
        die("ptsname() failed");
    }
    let slave = libc::open(name, libc::O_RDWR | libc::O_NOCTTY);
    if slave < 0 {
        die("open(pts slave) failed");
    }
    (master, slave)
}

fn setup_raw_termios(master: c_int) {
    unsafe {
        let mut orig: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(0, &mut orig) != 0 {
            return;
        }
        ORIG_TERMIOS.write(orig);
        TERMIOS_SAVED.store(true, Ordering::SeqCst);
        libc::atexit(restore_termios);
        // Raw mode (cider.c:655-693).
        let mut raw = orig;
        raw.c_lflag &= !(libc::ICANON | libc::ISIG | libc::IEXTEN | libc::ECHO);
        raw.c_iflag &= !(libc::BRKINT
            | libc::ICRNL
            | libc::IGNBRK
            | libc::IGNCR
            | libc::INLCR
            | libc::INPCK
            | libc::ISTRIP
            | libc::IXON
            | libc::PARMRK);
        raw.c_oflag &= !libc::OPOST;
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        libc::tcsetattr(0, libc::TCSANOW, &raw);
        // Push our window size to the master.
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(0, libc::TIOCGWINSZ, &mut ws) == 0 {
            libc::ioctl(master, libc::TIOCSWINSZ, &ws);
        }
    }
}

extern "C" fn restore_termios() {
    if TERMIOS_SAVED.load(Ordering::SeqCst) {
        unsafe {
            let t = ORIG_TERMIOS.assume_init_ref();
            libc::tcsetattr(0, libc::TCSANOW, t);
        }
    }
}

/// Install a self-pipe + a handler for signals 1..31 (cider.c:501-506). The handler
/// only writes the signal number to the pipe (async-signal-safe), and the poll loop
/// forwards it -- avoiding the C handler's malloc-in-signal-context (map 3.6).
fn install_signal_forwarding(sockfd: c_int, master: c_int) {
    let mut pipefd = [0 as c_int; 2];
    if unsafe { libc::pipe(pipefd.as_mut_ptr()) } != 0 {
        return;
    }
    unsafe { libc::fcntl(pipefd[1], libc::F_SETFL, libc::O_NONBLOCK) };
    SELF_PIPE_R.store(pipefd[0], Ordering::SeqCst);
    SELF_PIPE_W.store(pipefd[1], Ordering::SeqCst);
    SHSOCK.store(sockfd, Ordering::SeqCst);
    PTY_MASTER.store(master, Ordering::SeqCst);
    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = handle_signal as extern "C" fn(c_int) as libc::sighandler_t;
    unsafe { libc::sigfillset(&mut sa.sa_mask) };
    sa.sa_flags = 0;
    for sig in 1..32 {
        // KILL/STOP cannot be caught -- those sigaction calls fail harmlessly.
        unsafe { libc::sigaction(sig, &sa, std::ptr::null_mut()) };
    }
}

extern "C" fn handle_signal(sig: c_int) {
    let w = SELF_PIPE_W.load(Ordering::SeqCst);
    if w >= 0 {
        let b = [sig as u8];
        unsafe { libc::write(w, b.as_ptr() as *const c_void, 1) };
    }
}

fn drain_signals(pipe_r: c_int, master: c_int) {
    let mut buf = [0u8; 64];
    let n = unsafe { libc::read(pipe_r, buf.as_mut_ptr() as *mut c_void, buf.len()) };
    if n <= 0 {
        return;
    }
    let sockfd = SHSOCK.load(Ordering::SeqCst);
    for &sig in &buf[..n as usize] {
        let signo = sig as c_int;
        if signo == libc::SIGWINCH && master != -1 {
            // Copy our new window size to the master (cider.c:431-437).
            let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
            unsafe {
                if libc::ioctl(0, libc::TIOCGWINSZ, &mut ws) == 0 {
                    libc::ioctl(master, libc::TIOCSWINSZ, &ws);
                }
            }
        } else {
            // Non-pty SIGINT -> SIGTERM (bash ignores a forwarded SIGINT) (cider.c:443-447).
            let s = if master == -1 && signo == libc::SIGINT {
                libc::SIGTERM
            } else {
                signo
            };
            push_cmd(sockfd, SHELLSPAWN_SIGNAL, &(s as i32).to_le_bytes());
        }
    }
}

fn pump(from: c_int, to: c_int) {
    let mut buf = [0u8; 4096];
    let n = unsafe { libc::read(from, buf.as_mut_ptr() as *mut c_void, buf.len()) };
    if n > 0 {
        let mut off = 0isize;
        while off < n {
            let w = unsafe {
                libc::write(
                    to,
                    buf.as_ptr().offset(off) as *const c_void,
                    (n - off) as usize,
                )
            };
            if w <= 0 {
                break;
            }
            off += w;
        }
    }
}

fn exit_clean(code: i32) -> ! {
    restore_termios();
    std::process::exit(code);
}

// ============================= small helpers =============================

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

fn die(msg: &str) -> ! {
    eprintln!("cider: {msg}");
    std::process::exit(1);
}

fn errno() -> c_int {
    unsafe { *libc::__errno_location() }
}

fn getcwd() -> String {
    let mut buf = [0 as c_char; 4096];
    if unsafe { libc::getcwd(buf.as_mut_ptr(), buf.len()) }.is_null() {
        return "/".to_string();
    }
    unsafe { CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned() }
}

fn single_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

fn startup_timeout() -> i32 {
    // CIDER_ is canonical; DARLING_ is the compat fallback.
    std::env::var("CIDER_SHELL_STARTUP_TIMEOUT")
        .or_else(|_| std::env::var("DARLING_SHELL_STARTUP_TIMEOUT"))
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(60)
}

fn full_path(arg: &str) -> String {
    let a = cstr(arg);
    let mut buf = [0 as c_char; 4096];
    let r = unsafe { libc::realpath(a.as_ptr(), buf.as_mut_ptr()) };
    if r.is_null() {
        die(&format!("{arg} is not a supported command or a file"));
    }
    let resolved = unsafe { CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned() };
    format!("{SYSTEM_ROOT}{resolved}")
}

fn read_full(fd: c_int, buf: &mut [u8]) -> usize {
    let mut total = 0;
    while total < buf.len() {
        let n = unsafe {
            libc::read(
                fd,
                buf[total..].as_mut_ptr() as *mut c_void,
                buf.len() - total,
            )
        };
        if n <= 0 {
            break;
        }
        total += n as usize;
    }
    total
}

fn write_all(fd: c_int, buf: &[u8]) {
    let mut total = 0;
    while total < buf.len() {
        let n = unsafe {
            libc::write(
                fd,
                buf[total..].as_ptr() as *const c_void,
                buf.len() - total,
            )
        };
        if n <= 0 {
            die("write() to the shellspawn socket failed");
        }
        total += n as usize;
    }
}

fn show_help() {
    eprintln!(
        "Darling (Rust launcher {GIT_BRANCH}-{GIT_COMMIT})\n\
         Usage:\n  cider shell [command...]   run a command in the container\n\
         \x20 cider exec <binary> [args] exec a Mach-O binary\n\
         \x20 cider shutdown             stop the container"
    );
}

fn show_version() {
    println!("Darling (Rust launcher) {GIT_BRANCH}-{GIT_COMMIT}");
}
