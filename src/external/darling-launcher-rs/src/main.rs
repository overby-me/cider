// darling -- the Darling launcher, Rust rewrite of src/startup/darling.c (task #64).
//
// Responsibilities (darling.c does NO mounts/vchroot -- darlingserver owns those):
//   1. Acquire privilege: rootless user-namespace re-exec (or setuid-root).
//   2. Bootstrap the prefix dir tree + passwd/group on first run.
//   3. Start / validate / join / tear down the container by running darlingserver
//      as the container init, coordinating readiness (sync pipe + shellspawn.sock poll).
//   4. Connect to the guest shellspawn socket and proxy one shell/binary.
//
// PHASE A (this file): the full boot path + the non-interactive proxy (direct fd
// passing), which is exactly what the boot-stress exercises. PHASE B adds the PTY /
// interactive path, signal forwarding, and the startup watchdog's killContainer.
//
// Raw libc only, to match darlingserver-rs and build offline. Line refs are to the
// C original for maintainability.
#![allow(dead_code)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};

// ---- compile-time config (darling-config.h / shellspawn.h) ----
const SYSTEM_ROOT: &str = "/Volumes/SystemRoot";
const SHELLSPAWN_SOCKPATH: &str = "/var/run/shellspawn.sock";
const INSTALL_PREFIX: &str = env!("DARLING_INSTALL_PREFIX");
const GIT_BRANCH: &str = env!("DARLING_GIT_BRANCH");
const GIT_COMMIT: &str = env!("DARLING_GIT_COMMIT");

// ---- shellspawn wire protocol (src/shellspawn/shellspawn.h) ----
const SHELLSPAWN_ADDARG: u16 = 1;
const SHELLSPAWN_SETENV: u16 = 2;
const SHELLSPAWN_CHDIR: u16 = 3;
const SHELLSPAWN_GO: u16 = 4;
const SHELLSPAWN_SIGNAL: u16 = 5;
const SHELLSPAWN_SETUIDGID: u16 = 6;
const SHELLSPAWN_SETEXEC: u16 = 7;

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

    // Privilege gate (darling.c:131-142).
    if unsafe { libc::geteuid() } != 0 {
        if std::env::var_os("DARLING_USERNS_STAGE2").is_none() {
            enter_userns_and_reexec(&argv); // only returns on failure
            missing_setuid_root();
        } else {
            missing_setuid_root();
        }
    }
    std::env::remove_var("DARLING_USERNS_STAGE2");

    // Capture identity (darling.c:144-148). Rootless: getuid()==0 inside the userns,
    // so orig_uid/gid == 0 and every owner/seteuid check downstream is a no-op.
    let orig_uid = unsafe { libc::getuid() };
    let orig_gid = unsafe { libc::getgid() };
    unsafe {
        libc::setuid(0);
        libc::setgid(0);
    }

    // Resolve prefix (darling.c:150-161).
    let prefix = match std::env::var("DPREFIX") {
        Ok(p) if !p.is_empty() => p,
        _ => default_prefix_path(),
    };
    if prefix.len() > 255 {
        die("Prefix path too long (>255)");
    }
    std::env::remove_var("DPREFIX");
    let working_dir = getcwd();

    let mut ctx = Ctx {
        prefix,
        orig_uid,
        orig_gid,
        working_dir,
        fix_permissions: false,
    };

    // Prefix bootstrap (darling.c:163-168).
    if !check_prefix_dir(&ctx.prefix) {
        setup_prefix(&ctx);
        ctx.fix_permissions = true;
    }
    check_prefix_owner(&ctx);

    // --help / --version only when they precede the subcommand (getopt "+" semantics,
    // darling.c:170-207).
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

    let mut pid_init = get_init_process(&ctx); // darling.c:209

    // shutdown subcommand, handled before any ns work (darling.c:211-239).
    if argv[1] == "shutdown" {
        do_shutdown(pid_init);
        std::process::exit(0);
    }

    // Stale-container reap (darling.c:246-255): a prior rootless container lives in a
    // different userns whose mnt ns we cannot setns into -> discard + restart.
    if pid_init != 0 && !container_joinable(pid_init) {
        kill_container(&ctx);
        let _ = std::fs::remove_file(format!("{}/.init.pid", ctx.prefix));
        let _ = std::fs::remove_file(format!("{}{}", ctx.prefix, SHELLSPAWN_SOCKPATH));
        pid_init = 0;
    }

    // Start the container if none (darling.c:258-283).
    if pid_init == 0 {
        let _ = std::fs::remove_file(format!("{}{}", ctx.prefix, SHELLSPAWN_SOCKPATH));
        setup_workdir(&ctx);
        pid_init = spawn_init_process(&ctx); // blocks on the sync pipe until mounts ready
        put_init_pid(&ctx, pid_init);
        // Poll for the guest to boot shellspawn, up to 360s (darling.c:277-282).
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
    // (darling.c:285-287, the Linux 4.11 / overlayfs socket hack).
    join_namespace(pid_init, libc::CLONE_NEWNS, "mnt");

    // Drop euid (darling.c:289; no-op rootless).
    unsafe { libc::seteuid(ctx.orig_uid) };

    // Dispatch (darling.c:291-330).
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
            // Bare `darling <prog> [args]`: realpath+SYSTEM_ROOT, shell-wrapped.
            let full = full_path(&argv[1]);
            let mut a = vec![full];
            a.extend_from_slice(&argv[2..]);
            spawn_shell(&ctx, &a);
        }
    }
}

// ======================= privilege (darling.c:65-103) =======================

fn enter_userns_and_reexec(argv: &[String]) {
    // Capture the REAL ids before entering the new userns (darling.c:80-81).
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
    std::env::set_var("DARLING_USERNS_STAGE2", "1");
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
        "darling: cannot set up a container: need unprivileged user namespaces \
         (sysctl kernel.unprivileged_userns_clone=1) or a setuid-root darling binary."
    );
    std::process::exit(1);
}

// ======================= prefix (darling.c:1075-1269) =======================

fn default_prefix_path() -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => format!("{h}/.darling"),
        _ => die("HOME is not set and DPREFIX was not given"),
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

fn setup_prefix(ctx: &Ctx) {
    unsafe {
        libc::seteuid(ctx.orig_uid);
        libc::setegid(ctx.orig_gid);
    }
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
        "/private/etc",
        "/var",
        "/var/run",
        "/var/tmp",
        "/var/log",
    ] {
        create_dir(&format!("{}{}", ctx.prefix, d));
    }
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
    ("darling".to_string(), uid, uid)
}

// ==================== container lifecycle (darling.c) ====================

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
    // liveness (darling.c:1310-ish)
    if unsafe { libc::kill(pid, 0) } != 0 && errno() == libc::ESRCH {
        let _ = std::fs::remove_file(&path);
        return 0;
    }
    // comm must be "darlingserver" (darling.c:1323)
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
    if comm.trim() != "darlingserver" {
        let _ = std::fs::remove_file(&path);
        return 0;
    }
    // setuid mode only: /proc/<pid>/status Uid/Gid must match (darling.c:1331)
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

fn container_joinable(pid: i32) -> bool {
    let p = cstr(&format!("/proc/{pid}/ns/mnt"));
    let fd = unsafe { libc::open(p.as_ptr(), libc::O_RDONLY) };
    if fd >= 0 {
        unsafe { libc::close(fd) };
        true
    } else {
        false
    }
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
    // (darling.c:967).
    if unsafe { libc::unshare(libc::CLONE_NEWUTS | libc::CLONE_NEWIPC) } != 0 {
        die("unshare(CLONE_NEWUTS|CLONE_NEWIPC) failed");
    }
    // Build every CString BEFORE fork -- the child must be async-signal-safe (no alloc).
    let ds_bin = ds_bin_path();
    let ds_bin_c = cstr(&ds_bin);
    let argv0 = cstr("darlingserver");
    let prefix_c = cstr(&ctx.prefix);
    let uid_c = cstr(&ctx.orig_uid.to_string());
    let gid_c = cstr(&ctx.orig_gid.to_string());
    let pipe_c = cstr(&pipefd[1].to_string());
    let fixperm_c = cstr(if ctx.fix_permissions { "1" } else { "0" });
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
        // CHILD: async-signal-safe only -- close, execv, _exit. No allocation.
        unsafe {
            libc::close(read_fd);
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
    match std::env::var("DSERVER_PATH") {
        Ok(p) if !p.is_empty() => p,
        _ => format!("{INSTALL_PREFIX}/bin/darlingserver"),
    }
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
        die("There is no darling container running");
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

// ==================== shellspawn client (darling.c:360-916) ====================

fn spawn_shell(ctx: &Ctx, args: &[String]) -> ! {
    let sockfd = connect_shellspawn(ctx);
    setup_shellspawn_env(sockfd);
    // Join args into one single-quoted -c string (darling.c:852-897).
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
    let fds = setup_fds();
    spawn_go(sockfd, &fds);
    shell_loop(sockfd)
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
    let fds = setup_fds();
    spawn_go(sockfd, &fds);
    shell_loop(sockfd)
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
    push_env(fd, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin");
    push_env(fd, "TMPDIR", "/private/tmp");
    push_env(fd, "HOME", &format!("/Users/{}", get_login()));
    for (k, v) in std::env::vars() {
        if k == "PATH" || k == "TMPDIR" || k == "HOME" {
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

/// PHASE A: non-interactive -- pass our stdio directly (darling.c setupFDs, non-tty
/// branch). The guest holds our real fds, so its output reaches us with no proxying.
/// PHASE B replaces the isatty() branch with a real PTY.
fn setup_fds() -> [c_int; 3] {
    unsafe { [libc::dup(0), libc::dup(1), libc::dup(2)] }
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

/// PHASE A shell_loop: non-interactive, so only the socket matters (darling.c fdcount=1
/// when the pty master is -1). Wait for the 1-byte "started" marker, then the 4-byte
/// exit status. PHASE B adds stdin/master polling + signal forwarding + killContainer.
fn shell_loop(sockfd: c_int) -> ! {
    let mut started = false;
    let startup_to = startup_timeout();
    loop {
        let mut pfd = libc::pollfd {
            fd: sockfd,
            events: libc::POLLIN,
            revents: 0,
        };
        let timeout = if started || startup_to <= 0 {
            -1
        } else {
            startup_to * 1000
        };
        let r = unsafe { libc::poll(&mut pfd, 1, timeout) };
        if r < 0 {
            if errno() == libc::EINTR {
                continue;
            }
            die("poll() failed");
        }
        if r == 0 && !started {
            eprintln!("darling: timed out waiting for the guest program to start");
            std::process::exit(120);
        }
        if pfd.revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            if !started {
                let mut b = [0u8; 1];
                let n = unsafe { libc::read(sockfd, b.as_mut_ptr() as *mut c_void, 1) };
                if n == 1 {
                    started = true;
                    continue;
                }
                std::process::exit(1); // EOF before the started marker
            }
            let mut st = [0u8; 4];
            if read_full(sockfd, &mut st) == 4 {
                std::process::exit(i32::from_le_bytes(st));
            }
            std::process::exit(1);
        }
    }
}

// ============================= small helpers =============================

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

fn die(msg: &str) -> ! {
    eprintln!("darling: {msg}");
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
    std::env::var("DARLING_SHELL_STARTUP_TIMEOUT")
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
         Usage:\n  darling shell [command...]   run a command in the container\n\
         \x20 darling exec <binary> [args] exec a Mach-O binary\n\
         \x20 darling shutdown             stop the container"
    );
}

fn show_version() {
    println!("Darling (Rust launcher) {GIT_BRANCH}-{GIT_COMMIT}");
}
