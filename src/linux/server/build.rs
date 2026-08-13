// Stage 0 build script.
//
// 1. bindgen the xnu_sys hooks contract from SOURCE headers (no build needed) ->
//    proves the 36-field xnu_sys_hooks_t + all xnu_sys types bind correctly in Rust.
// 2. When XNU_SYS_LIB is set (a dir with the cider build's static libs), link
//    the real xnu-sys + libsimple so xnu_sys_init resolves -> the Stage 0 link proof.
// 3. Compile fast_context.c (the landed P1 signal-mask-free ucontext) into the
//    crate for the Stage 3 spike (Arm A).
//
// The prior link-model proof (stub xnu-sys, XNU_SYS_LIB wiring) was validated in
// a throwaway prototype (since removed); this consumes the REAL project the same way.
use std::env;
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // crate lives at <repo>/linux/server; the C++ xnu-sys it links is still at
    // <repo>/src/external/ciderd. nix/server.nix stages a synthetic tree
    // mirroring these real repo paths, so the same relative paths resolve in a dev
    // `cargo build` and in the nix build.
    let xnu_sys = manifest.join("../../vendor/pins/ciderd/xnu-sys");
    let xnu_sys_inc = xnu_sys.join("include");
    let libsimple_inc = manifest.join("../../src/libsimple/include");
    let fast_context = manifest.join("../../vendor/pins/ciderd/src/fast_context.c");

    // ---- (1) bindgen: the hooks contract + types (source headers only) ----
    let mut builder = bindgen::Builder::default()
        .header("wrapper.h")
        .clang_arg(format!("-I{}", xnu_sys_inc.display()))
        .clang_arg(format!("-I{}", libsimple_inc.display()));

    // The internal structs the ported glue needs (#71). wrapper.h reaches internal-include,
    // the XNU roots, and two GENERATED trees: ciderd/rpc.h (the RPC wrapper
    // generator, via xnu-sys.h) and the MIG output for mach/task.h, which is the only
    // place semaphore_create and semaphore_destroy are declared.
    //
    // The generated trees do not exist in a bare checkout, so cargo is TOLD where they are
    // rather than guessing: XNU_SYS_GEN_INCLUDE, colon separated, exactly as -I takes them.
    // It is required, not optional. Making it optional would mean a cargo build and a buck2
    // build produce crates with different contents from identical sources, and a divergence
    // like that surfaces later as a bug that only reproduces under one of them.
    println!("cargo:rerun-if-env-changed=XNU_SYS_GEN_INCLUDE");
    let gen_roots = env::var("XNU_SYS_GEN_INCLUDE").unwrap_or_default();
    let gen_roots: Vec<&str> = gen_roots.split(':').filter(|s| !s.is_empty()).collect();
    if gen_roots.is_empty() {
        panic!(
            "XNU_SYS_GEN_INCLUDE is not set.\n\
             wrapper.h binds xnu-sys's internal structs, which reach two GENERATED header \
             trees (ciderd/rpc.h and the MIG mach/task.h). Point this at their \
             directories, colon separated. buck2 wires them as target deps, so the usual \
             fix is to build through buck2 (//src/linux/server:ciderd), or to run \
             buck2 build //vendor/pins/ciderd:dserver_rpc \
             //vendor/pins/ciderd/xnu-sys:mig_mach_task and pass their output \
             directories here."
        );
    }
    // mig FIRST: mach/task.h exists as both a MIG output and a hand-written XNU header, and
    // semaphore_create/semaphore_destroy are declared only in the generated one.
    for root in &gen_roots {
        builder = builder.clang_arg(format!("-I{root}"));
    }
    for root in [
        "internal-include", "defines", "xnu/osfmk", "xnu/bsd", "xnu/libkern",
        "xnu/osfmk/libsa", "xnu/pexpert", "xnu/iokit", "xnu/EXTERNAL_HEADERS", "xnu",
    ] {
        builder = builder.clang_arg(format!("-I{}", xnu_sys.join(root).display()));
    }
    builder = builder
        .clang_arg(format!(
            "-I{}",
            manifest.join("../../vendor/pins/ciderd/include").display()
        ))
        // The XNU headers do not parse without xnu-sys's own flags; -fblocks above all,
        // since osfmk/kern/priority_queue.h uses blocks. The buck2 path loads the full set
        // from vendor/pins/ciderd/xnu-sys/flags.bzl, which the generator writes
        // from the same CMakeLists these come from.
        .clang_arg("-fblocks")
        .clang_arg("-Wno-nullability-completeness")
        .clang_arg("-Wno-expansion-to-defined")
        .clang_arg("-Wno-elaborated-enum-base")
        .allowlist_type("xnu_sys_semaphore")
        .allowlist_type("xnu_sys_task")
        .allowlist_function("semaphore_create")
        .allowlist_function("semaphore_destroy")
        .allowlist_function("semaphore_signal")
        .allowlist_function("semaphore_wait")
        .allowlist_var("KERN_SUCCESS")
        .allowlist_var("KERN_ABORTED");
    // Only the SIZE of the XNU giants crosses; nothing here reads their fields. Without
    // this, struct task drags most of osfmk into the bindings for no gain.
    for t in ["task", "thread", "ipc_.*", "vm_.*", "_?lck_.*", "queue_.*",
              "priority_queue.*", "os_ref.*", "waitq.*", "zone.*"] {
        builder = builder.opaque_type(t);
    }

    let bindings = builder
        // The xnu_sys surface we care about; keep the XNU/libsimple internals out.
        .allowlist_type("xnu_sys_hooks_t")
        .allowlist_type("xnu_sys_hooks")
        .allowlist_type("xnu_sys_.*_t")
        .allowlist_type("xnu_sys_.*_f")
        .allowlist_type("libsimple_lock_t")
        .allowlist_var("XNU_SYS_.*")
        // fn-pointer struct fields become Option<unsafe extern "C" fn...>, which
        // lets us zero-init the vtable and fill only the hooks we implement.
        .default_enum_style(bindgen::EnumVariation::Rust { non_exhaustive: true })
        .derive_default(false)
        .layout_tests(false)
        .generate()
        .expect("bindgen failed on the xnu_sys hooks contract");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out.join("xnu_sys.rs"))
        .expect("write xnu_sys.rs");

    // ---- (3) compile fast_context.c (P1) -- always; it is self-contained ----
    if fast_context.exists() {
        cc::Build::new()
            .file(&fast_context)
            .define("DSERVER_FAST_CONTEXT", "1")
            .warnings(false)
            .compile("dserver_fast_context");
    } else {
        println!("cargo:warning=fast_context.c not found at {}", fast_context.display());
    }

    // ---- (2) link the real xnu-sys when provided ----
    // XNU_SYS_LIB = dir holding libciderd_xnu_sys.a + liblibsimple_ciderd.a
    // (exported by the cider build; see nix wiring). Without it, `cargo check`
    // still validates the Rust/FFI side; only the final bin link needs it.
    if let Ok(libdir) = env::var("XNU_SYS_LIB") {
        println!("cargo:rustc-link-search=native={libdir}");
        println!("cargo:rustc-link-lib=static=ciderd_xnu_sys");
        println!("cargo:rustc-link-lib=static=libsimple_ciderd");
        // XNU/xnu-sys C pulls these Linux libs:
        for l in ["pthread", "dl", "m", "rt"] {
            println!("cargo:rustc-link-lib=dylib={l}");
        }
    }
    println!("cargo:rerun-if-env-changed=XNU_SYS_LIB");
    println!("cargo:rerun-if-changed=wrapper.h");
}
