// Stage 0 build script.
//
// 1. bindgen the dtape hooks contract from SOURCE headers (no build needed) ->
//    proves the 36-field dtape_hooks_t + all dtape types bind correctly in Rust.
// 2. When DUCT_TAPE_LIB is set (a dir with the darling build's static libs), link
//    the real duct-tape + libsimple so dtape_init resolves -> the Stage 0 link proof.
// 3. Compile fast_context.c (the landed P1 signal-mask-free ucontext) into the
//    crate for the Stage 3 spike (Arm A).
//
// The prior link-model proof (stub duct-tape, DUCT_TAPE_LIB wiring) is in
// prototype/rust-consume-model/; this consumes the REAL project the same way.
use std::env;
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // crate lives at <repo>/linux/darlingserver/darlingserver-rs; the C++ duct-tape it
    // links is still at <repo>/src/external/darlingserver. nix/darlingserver-rs.nix
    // stages a synthetic tree mirroring these real repo paths, so the same relative
    // paths resolve in a dev `cargo build` and in the nix build.
    let dtape_inc = manifest.join("../../../src/external/darlingserver/duct-tape/include");
    let libsimple_inc = manifest.join("../../../src/libsimple/include");
    let fast_context = manifest.join("../../../src/external/darlingserver/src/fast_context.c");

    // ---- (1) bindgen: the hooks contract + types (source headers only) ----
    let bindings = bindgen::Builder::default()
        .header("wrapper.h")
        .clang_arg(format!("-I{}", dtape_inc.display()))
        .clang_arg(format!("-I{}", libsimple_inc.display()))
        // The dtape surface we care about; keep the XNU/libsimple internals out.
        .allowlist_type("dtape_hooks_t")
        .allowlist_type("dtape_hooks")
        .allowlist_type("dtape_.*_t")
        .allowlist_type("dtape_.*_f")
        .allowlist_type("libsimple_lock_t")
        .allowlist_var("DTAPE_.*")
        // fn-pointer struct fields become Option<unsafe extern "C" fn...>, which
        // lets us zero-init the vtable and fill only the hooks we implement.
        .default_enum_style(bindgen::EnumVariation::Rust { non_exhaustive: true })
        .derive_default(false)
        .layout_tests(false)
        .generate()
        .expect("bindgen failed on the dtape hooks contract");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out.join("dtape_bindings.rs"))
        .expect("write dtape_bindings.rs");

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

    // ---- (2) link the real duct-tape when provided ----
    // DUCT_TAPE_LIB = dir holding libdarlingserver_duct_tape.a + liblibsimple_darlingserver.a
    // (exported by the darling build; see nix wiring). Without it, `cargo check`
    // still validates the Rust/FFI side; only the final bin link needs it.
    if let Ok(libdir) = env::var("DUCT_TAPE_LIB") {
        println!("cargo:rustc-link-search=native={libdir}");
        println!("cargo:rustc-link-lib=static=darlingserver_duct_tape");
        println!("cargo:rustc-link-lib=static=libsimple_darlingserver");
        // XNU/duct-tape C pulls these Linux libs:
        for l in ["pthread", "dl", "m", "rt"] {
            println!("cargo:rustc-link-lib=dylib={l}");
        }
    }
    println!("cargo:rerun-if-env-changed=DUCT_TAPE_LIB");
    println!("cargo:rerun-if-changed=wrapper.h");
}
