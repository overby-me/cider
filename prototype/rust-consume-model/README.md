# rust-consume-model (prototype)

End-to-end proof of the build model for porting Darling's host components to Rust:
**each project builds separately; a Rust `build.rs` only *consumes* the prebuilt
projects (link-time); a separate assembly step stages them into the darling
prefix.** Rationale and the full component ranking are in
[`plan/rust-rewrite-eval.md`](../../plan/rust-rewrite-eval.md).

## What it shows

Three independent, separately-cached derivations (`proto.nix`):

1. **`duct-tape-stub/`** -- a C project built **on its own** into `libdtape.a`.
   Stands in for the real duct-tape (which wraps ~750k lines of vendored XNU).
2. **`darlingserver-rs/`** -- a cargo crate. Its **`build.rs` only consumes**
   project 1: it points the linker at the prebuilt `libdtape.a` (`DUCT_TAPE_LIB`)
   and never builds it. `src/main.rs` FFI-calls `dtape_init`.
3. **assembly** -- a `runCommand` that **stages** the built daemon (and, in the
   real thing, the nix-ninja-built macOS dylibs) into `libexec/darling/...`. This
   is where dylibs land -- *not* in `build.rs`.

## Run it

```sh
nix build --impure -f proto.nix darling --print-out-paths
ds=$(nix build --impure -f proto.nix darlingserver --print-out-paths --no-link)
$ds/bin/darlingserver
# -> darlingserver-rs: linked prebuilt duct-tape, dtape_init(8) = 17
```

The `17` (= `8*2+1`) confirms the Rust daemon linked and called into the
separately-built C project through `build.rs`.

## From skeleton to the real thing

Structure stays identical; three substitutions:

1. **stub -> real duct-tape**: swap project 1's `runCommand` for the actual C
   duct-tape build (its own derivation), keep the same `DUCT_TAPE_LIB` wiring, add
   `bindgen` over its headers.
2. **RPC bindings**: extend `src/external/darlingserver/scripts/generate-rpc-wrappers.py`
   to emit Rust (server) alongside C (clients); `main.rs` gains the epoll/RPC loop.
3. **assembly stages real dylibs**: replace `README.staging` with the
   nix-ninja-built `libSystem.B.dylib` + frameworks (the reconstruct-and-install
   output from `plan/nix-ninja-primary.md`).

Only the Linux **host** components (darlingserver, mldr, launcher) are candidates;
the macOS ABI layer (libSystem, frameworks) stays C -- see the eval doc.
