//! Prints `<key> <size> <align>` for every RPC message struct. Diffed against the
//! C probe by scripts/rpc-wire-parity.sh to prove the Rust wire structs are
//! byte-identical to the C the clients use.
fn main() {
    darling::rpc_wire::print_sizes();
}
