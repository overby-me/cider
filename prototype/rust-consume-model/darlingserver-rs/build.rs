// build.rs ONLY CONSUMES the separately-built duct-tape project -- it points the
// linker at the prebuilt static lib. It does NOT build duct-tape (that is its own
// derivation, upstream). This is the whole "consume, don't build" idea, and it is
// exactly what build.rs is for: link-time consumption of a native artifact.
use std::env;

fn main() {
    let lib = env::var("DUCT_TAPE_LIB")
        .expect("DUCT_TAPE_LIB must point at the prebuilt duct-tape lib dir");
    println!("cargo:rustc-link-search=native={lib}");
    println!("cargo:rustc-link-lib=static=dtape");
    println!("cargo:rerun-if-env-changed=DUCT_TAPE_LIB");
}
