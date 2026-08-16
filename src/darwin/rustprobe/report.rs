// A SECOND FILE ON PURPOSE, and it is a check rather than a convenience.
//
// rustc finds this through `mod report;` in probe.rs, so it is a HIDDEN input: it appears in no
// argv and, because buck2 aquery reports no input list at all, in nothing the Nix endpoint can
// see either. Staging the crate ROOT and nothing else is what made a guest crate ONE FILE, and
// that limit is recorded in buck/rules/rust.bzl. srcset.rs now takes the whole directory for a
// darwin_rust_staticlib action, the same way it always has for a host rustc action.
//
// So if the endpoint ever regresses to staging only the root, this file stops existing during
// the build and the probe fails to compile with "file not found for module `report`". That is
// the point: the check is the crate itself, and it cannot pass by accident.

/// The line the runtime check greps for, built here so the module is genuinely used.
pub fn line(argc: i32, from_env: usize) -> String {
    format!("cider-rust-probe argc={argc} env_args={from_env}")
}
