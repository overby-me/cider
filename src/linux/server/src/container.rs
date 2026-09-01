//! Container bring-up: the Linux-side plumbing ciderd's `main()` does before the
//! RPC loop (ciderd.cpp:513). Faithful port of the core sequence -- privilege
//! dance, a private mount namespace, the prefix overlay, a new PID namespace for the
//! guest init, and the mldr/vchroot exec of that init. This is the piece that turns the
//! proven RPC engine into a daemon that actually HOSTS a guest.
//!
//! IMPORTANT (validation): this code needs root (cider.c launches ciderd as
//! mapped-root inside a user namespace) plus CAP_SYS_ADMIN for unshare/mount/clone. It
//! CANNOT run in the nix build sandbox and is not exercised by a flake-check demo; it is
//! validated by splicing the daemon into a real cider runtime (the run recipe in
//! docs/changelog.md) and launching it through the cider launcher. Deferred vs the C++
//! for now (all best-effort prefix work, orthogonal to the namespace/mount/clone core):
//! setupUserHome, ciderPreInit, fixPermissions, and rlimit bumps. The writable-/nix
//! overlay (for guest Nix / M1) IS ported (`mount_nix_overlay`). See
//! docs/changelog.md (bucket B, the container main).

use std::ffi::CString;
use std::io;
use std::os::raw::c_int;

/// Where cider.c passed us: the prefix, the launching user's uid/gid, the readiness
/// pipe, and (env-configured so the daemon is relocatable) the libexec root, the mldr
/// binary, and the guest init to exec. Mirrors the argv[1..5] + compile-time paths the
/// C++ daemon uses.
pub struct Config {
    pub prefix: String,
    pub original_uid: libc::uid_t,
    pub original_gid: libc::gid_t,
    pub ready_pipe: c_int,
    pub libexec_path: String,
    pub mldr_path: String,
    pub init_path: String,
}

impl Config {
    /// Parse argv (prefix, uid, gid, pipefd, fix_permissions) + env (paths + init).
    /// Mirrors ciderd.cpp:531-550 and spawnLaunchd's DSERVER_INIT/DARLING_NO_LAUNCHD.
    pub fn from_args_and_env(args: &[String]) -> Result<Config, String> {
        if args.len() < 5 {
            return Err("ciderd is not meant to be started manually".into());
        }
        let uid = args[2].parse::<libc::uid_t>().map_err(|e| e.to_string())?;
        let gid = args[3].parse::<libc::gid_t>().map_err(|e| e.to_string())?;
        let ready_pipe = args[4].parse::<c_int>().map_err(|e| e.to_string())?;
        let env = |k: &str| std::env::var(k).ok();
        // Paths: baked at C++ compile time (LIBEXEC_PATH / Config::defaultMldrPath); here
        // taken from env so a spliced daemon points at its runtime dir.
        let libexec_path = env("DSERVER_LIBEXEC_PATH").ok_or("DSERVER_LIBEXEC_PATH not set")?;
        let mldr_path = env("DSERVER_MLDR_PATH").ok_or("DSERVER_MLDR_PATH not set")?;
        // The guest init: DSERVER_INIT, else the DARLING_NO_LAUNCHD bypass (shellspawn),
        // else launchd (DARLINGSERVER_INIT_PROCESS). Mirrors spawnLaunchd:263-279.
        let init_path = env("DSERVER_INIT").unwrap_or_else(|| {
            let no_launchd = env("CIDER_NO_LAUNCHD")
                .or_else(|| env("DARLING_NO_LAUNCHD"))
                .unwrap_or_default();
            if matches!(no_launchd.as_bytes().first(), Some(b'1') | Some(b't') | Some(b'T')) {
                "/usr/libexec/shellspawn".to_string()
            } else {
                env("CIDERD_INIT_PROCESS")
                    .or_else(|| env("DARLINGSERVER_INIT_PROCESS"))
                    .unwrap_or_else(|| "/sbin/launchd".to_string())
            }
        });
        Ok(Config {
            prefix: args[1].clone(),
            original_uid: uid,
            original_gid: gid,
            ready_pipe,
            libexec_path,
            mldr_path,
            init_path,
        })
    }
}

fn errno() -> io::Error {
    io::Error::last_os_error()
}

// ---- privilege dance (setres*id): drop to the user for prefix work, regain root for
// privileged mounts, permanently drop before running guest code. ciderd.cpp:464. ----

/// Temporarily drop to (uid,gid) keeping root as the saved id (so we can regain it).
pub unsafe fn temp_drop_privileges(uid: libc::uid_t, gid: libc::gid_t) -> io::Result<()> {
    if libc::setresgid(gid, gid, 0) < 0 {
        return Err(errno());
    }
    if libc::setresuid(uid, uid, 0) < 0 {
        return Err(errno());
    }
    Ok(())
}

/// Regain root (real/effective/saved = 0).
pub unsafe fn regain_privileges() -> io::Result<()> {
    if libc::setresuid(0, 0, 0) < 0 {
        return Err(errno());
    }
    if libc::setresgid(0, 0, 0) < 0 {
        return Err(errno());
    }
    Ok(())
}

/// Permanently drop to (uid,gid) (saved id too -- root is unrecoverable after this).
pub unsafe fn perma_drop_privileges(uid: libc::uid_t, gid: libc::gid_t) -> io::Result<()> {
    if libc::setresgid(gid, gid, gid) < 0 {
        return Err(errno());
    }
    if libc::setresuid(uid, uid, uid) < 0 {
        return Err(errno());
    }
    Ok(())
}

// ---- mount namespace + prefix overlay (ciderd.cpp:611-660) ----

/// Enter a private mount namespace and set up the base mounts: a fresh tmpfs /dev/shm
/// and remount / as MS_SLAVE (so the overlay is not propagated back and is torn down
/// with the init). Must run as root, before dropping privileges.
pub unsafe fn enter_mount_namespace() -> io::Result<()> {
    // overlay cannot be mounted inside a user namespace, so we take our own mount ns and
    // do the mounts while (mapped-)root here.
    if libc::unshare(libc::CLONE_NEWNS) != 0 {
        return Err(errno());
    }

    let shm = CString::new("/dev/shm").unwrap();
    let tmpfs = CString::new("tmpfs").unwrap();
    libc::umount(shm.as_ptr());
    // MS_NOEXEC is skipped on WSL1 in the C++; we keep it (the common case).
    let shm_flags = (libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC) as libc::c_ulong;
    if libc::mount(tmpfs.as_ptr(), shm.as_ptr(), tmpfs.as_ptr(), shm_flags, std::ptr::null()) != 0 {
        return Err(errno());
    }

    // systemd marks / as MS_SHARED; make it a slave so the overlay is not propagated and
    // is unmounted once the init dies.
    let root = CString::new("/").unwrap();
    if libc::mount(std::ptr::null(), root.as_ptr(), std::ptr::null(), (libc::MS_REC | libc::MS_SLAVE) as libc::c_ulong, std::ptr::null()) != 0 {
        return Err(errno());
    }
    Ok(())
}

/// Mount the prefix overlay: lowerdir = the read-only cider root (libexec), upperdir =
/// the prefix (guest-writable), workdir = "<prefix>.workdir". ciderd.cpp:642-660.
pub unsafe fn mount_prefix_overlay(prefix: &str, libexec_path: &str) -> io::Result<()> {
    let overlay = CString::new("overlay").unwrap();
    let target = CString::new(prefix).unwrap();
    // Try with index=off first, then without (older kernels reject the option) -- the
    // same EINVAL fallback the C++ does.
    let opts_a = format!("lowerdir={libexec_path},upperdir={prefix},workdir={prefix}.workdir,index=off");
    let c_a = CString::new(opts_a).unwrap();
    if libc::mount(overlay.as_ptr(), target.as_ptr(), overlay.as_ptr(), 0, c_a.as_ptr() as *const libc::c_void) == 0 {
        return Ok(());
    }
    let e = errno();
    if e.raw_os_error() == Some(libc::EINVAL) {
        let opts_b = format!("lowerdir={libexec_path},upperdir={prefix},workdir={prefix}.workdir");
        let c_b = CString::new(opts_b).unwrap();
        if libc::mount(overlay.as_ptr(), target.as_ptr(), overlay.as_ptr(), 0, c_b.as_ptr() as *const libc::c_void) == 0 {
            return Ok(());
        }
        return Err(errno());
    }
    Err(e)
}

/// Optional writable native /nix for guest Nix (ciderd.cpp:670). Opt-in via a
/// `<prefix>/.enable-writable-nix` marker plus a host `/nix/store`. nix refuses to build in
/// a diverted (non-`/nix/store`) store, and the host /nix the container sees is read-only to
/// the mapped root; so overlay the host `/nix/store` and `/nix/var` (read-only lowers -- the
/// guest inherits the host's valid-paths DB and trusts pre-populated deps) with writable
/// uppers, at the container's `/nix/store` and `/nix/var`. The uppers live in a
/// `<prefix>.nixrw` sibling: overlayfs forbids an upperdir that is itself on an overlay, and
/// the prefix is one. Two SEPARATE overlays (a socket in /nix/var defeats one whole-/nix
/// overlay), each needing `userxattr` for unprivileged/mapped-root overlayfs. Entirely
/// best-effort: any failure leaves /nix as-is and the container still boots. Must run as
/// root, after the prefix overlay and before dropping privileges.
pub unsafe fn mount_nix_overlay(prefix: &str) {
    let marker = CString::new(format!("{prefix}/.enable-writable-nix")).unwrap();
    let store = CString::new("/nix/store").unwrap();
    if libc::access(marker.as_ptr(), libc::F_OK) != 0 || libc::access(store.as_ptr(), libc::F_OK) != 0 {
        return;
    }
    let back = format!("{prefix}.nixrw");
    let mkdir = |p: &str| {
        if let Ok(c) = CString::new(p) {
            libc::mkdir(c.as_ptr(), 0o755);
        }
    };
    mkdir(&format!("{prefix}/nix"));
    mkdir(&back);
    let overlay = CString::new("overlay").unwrap();
    for sub in ["store", "var"] {
        let mnt = format!("{prefix}/nix/{sub}");
        let up = format!("{back}/{sub}.up");
        let wk = format!("{back}/{sub}.work");
        mkdir(&mnt);
        mkdir(&up);
        mkdir(&wk);
        let opts = format!("lowerdir=/nix/{sub},upperdir={up},workdir={wk},userxattr,index=off");
        let c_mnt = CString::new(mnt).unwrap();
        let c_opts = CString::new(opts).unwrap();
        if libc::mount(overlay.as_ptr(), c_mnt.as_ptr(), overlay.as_ptr(), 0, c_opts.as_ptr() as *const libc::c_void) != 0 {
            eprintln!("container: writable /nix/{sub} overlay failed: {}", errno());
        }
    }
}

// ---- PID namespace + guest init (ciderd.cpp:751-789) ----

/// Fork into a NEW PID namespace via clone(CLONE_NEWPID|SIGCHLD): the child becomes the
/// parent of the guest init (which will be PID 1 in that namespace). Returns the child
/// pid in the parent, or never returns in the child (it execs the init). `child_ready`
/// is the read end of a pipe the child waits on for the parent's go-ahead (the socket
/// must exist first). Mirrors the clone at line 753.
pub unsafe fn spawn_init_in_pid_namespace(cfg: &Config, child_wait_read: c_int) -> io::Result<libc::pid_t> {
    // clone (not fork) so the child is PID 1 of a new PID namespace while we keep making
    // our own threads/processes. SIGCHLD so waitpid works as usual.
    let pid = libc::syscall(libc::SYS_clone, (libc::CLONE_NEWPID | libc::SIGCHLD) as libc::c_ulong, 0usize, 0usize, 0usize, 0usize) as libc::pid_t;
    if pid < 0 {
        return Err(errno());
    }
    if pid == 0 {
        // ---- child: becomes the guest init's parent in the new PID namespace ----
        // mount procfs for the new PID namespace at <prefix>/proc.
        let put_old = CString::new(format!("{}/proc", cfg.prefix)).unwrap();
        let proc_src = CString::new("proc").unwrap();
        if libc::mount(proc_src.as_ptr(), put_old.as_ptr(), proc_src.as_ptr(), 0, std::ptr::null()) != 0 {
            eprintln!("container: cannot mount procfs: {}", errno());
            libc::_exit(1);
        }
        // permanently drop privileges before running guest code.
        if perma_drop_privileges(cfg.original_uid, cfg.original_gid).is_err() {
            eprintln!("container: perma_drop_privileges failed: {}", errno());
            libc::_exit(1);
        }
        libc::prctl(libc::PR_SET_DUMPABLE, 1, 0, 0, 0);
        // wait for the parent's green light (the RPC socket must exist first).
        let mut buf = [0u8; 1];
        libc::read(child_wait_read, buf.as_mut_ptr() as *mut libc::c_void, 1);
        libc::close(child_wait_read);
        spawn_launchd(cfg); // execs the guest init; diverges (never returns)
    }
    Ok(pid)
}

/// Exec the guest init through mldr + vchroot: this replaces the child with mldr, which
/// vchroots into the prefix and runs the init (launchd or the shellspawn bypass) as
/// guest PID 1. Sets the __mldr_* env the loader needs. ciderd.cpp:255 (spawnLaunchd).
pub unsafe fn spawn_launchd(cfg: &Config) -> ! {
    let sock = format!("{}/.ciderd.sock", cfg.prefix);
    std::env::set_var("__mldr_DYLD_ROOT_PATH", &cfg.libexec_path);
    std::env::set_var("__mldr_sockpath", &sock);
    // #23 milestone-4: the authoritative vchroot prefix (the overlay mount, guest `/`). Plain env, not
    // __mldr_, so it survives mldr's env-clean and every descendant inherits it; mldr seeds the guest
    // from it (guarded to skip guest pid 1, whose vchroot setup a pre-seed would hang) instead of a
    // vchroot_path RPC when the executable-path derivation cannot (a basename argv0 like `cp`).
    std::env::set_var("__cider_vchroot_prefix", &cfg.prefix);

    // execl(mldr, "mldr!<libexec>/usr/libexec/cider/vchroot", "vchroot", prefix, init, NULL)
    let mldr = CString::new(cfg.mldr_path.clone()).unwrap();
    let arg0 = CString::new(format!("mldr!{}/usr/libexec/cider/vchroot", cfg.libexec_path)).unwrap();
    let a_vchroot = CString::new("vchroot").unwrap();
    let a_prefix = CString::new(cfg.prefix.clone()).unwrap();
    let a_init = CString::new(cfg.init_path.clone()).unwrap();
    let argv = [
        arg0.as_ptr(),
        a_vchroot.as_ptr(),
        a_prefix.as_ptr(),
        a_init.as_ptr(),
        std::ptr::null(),
    ];
    libc::execv(mldr.as_ptr(), argv.as_ptr());
    eprintln!("container: failed to exec mldr/launchd: {}", errno());
    libc::abort();
}

/// Signal the launching cider.c that the container is set up (write to the ready pipe),
/// mirroring ciderd.cpp:743.
pub unsafe fn signal_launcher_ready(cfg: &Config) {
    let dot = b".";
    libc::write(cfg.ready_pipe, dot.as_ptr() as *const libc::c_void, 1);
    libc::close(cfg.ready_pipe);
}
