// mldr -- Darling guest-side Mach-O loader, Rust rewrite of src/startup/mldr/ (task #65).
//
// M0/M1 (this file): the crate scaffold, argv-shape detection, special-env handling, and
// the Mach-O parse via goblin. The address-space setup (M2), dyld + start stack + commpage
// (M3), darlingserver checkin (M4), and register setup + jump-to-entry (M5) are the next
// milestones (plan/rust-startup-port.md). All the unsafe mapping/jump work is deferred so
// this compiles first and the parse path can be validated on real guest binaries.
#![allow(dead_code)]

use std::os::raw::c_int;

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
}

fn main() {
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

    let special = parse_special_env();
    eprintln!(
        "[mldr-rs] guest={guest_path} sockpath={:?} lifetime_pipe={:?}",
        special.sockpath, special.lifetime_pipe
    );

    // M1: parse the Mach-O (header + load commands, fat selection) via goblin.
    let data = match std::fs::read(&guest_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("[mldr-rs] cannot read {guest_path}: {e}");
            std::process::exit(1);
        }
    };
    match goblin::mach::Mach::parse(&data) {
        Ok(goblin::mach::Mach::Binary(macho)) => {
            eprintln!(
                "[mldr-rs] Mach-O: entry={:#x}, {} load commands",
                macho.entry,
                macho.load_commands.len()
            );
            // TODO M2: setup_space (commpage + stack) + map segments at vmaddr+slide.
            // TODO M3: load LC_LOAD_DYLINKER (dyld) + build the start stack + apple[].
            // TODO M4: darlingserver checkin over the __mldr_sockpath datagram socket.
            // TODO M5: CPU register setup + jmp to the (slid) entry point.
        }
        Ok(goblin::mach::Mach::Fat(_fat)) => {
            // TODO: honor bprefs, else prefer CPU_TYPE_X86_64 (mldr.c:340-448).
            eprintln!("[mldr-rs] fat Mach-O (slice selection TODO)");
        }
        Err(e) => {
            eprintln!("[mldr-rs] Mach-O parse error: {e}");
            std::process::exit(1);
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
    s
}
