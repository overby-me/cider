// Bake the compile-time constants cider.c gets from cider-config.h:
//   INSTALL_PREFIX  -> the default ciderd location (INSTALL_PREFIX/bin/ciderd),
//                      overridable at runtime by $DSERVER_PATH (matches cider.c:998-1001).
//   GIT_BRANCH / GIT_COMMIT_HASH -> shown by `cider --version`.
// INSTALL_PREFIX comes from $DARLING_INSTALL_PREFIX at build time (CMAKE_INSTALL_PREFIX
// in the C build); default is a placeholder since iteration passes $DSERVER_PATH.
use std::process::Command;

fn main() {
    let prefix =
        std::env::var("DARLING_INSTALL_PREFIX").unwrap_or_else(|_| "/usr/local".to_string());
    println!("cargo:rustc-env=DARLING_INSTALL_PREFIX={prefix}");
    println!("cargo:rerun-if-env-changed=DARLING_INSTALL_PREFIX");

    let branch = git(&["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_else(|| "unknown".into());
    let commit = git(&["rev-parse", "--short", "HEAD"]).unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=DARLING_GIT_BRANCH={branch}");
    println!("cargo:rustc-env=DARLING_GIT_COMMIT={commit}");
}

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if out.status.success() {
        Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        None
    }
}
