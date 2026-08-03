//! Prints `<key> <size> <align>` for every RPC message struct. Diffed against the
//! C probe when the structs landed, proving the Rust wire structs are
//! byte-identical to the C the clients use. The probe script is retired.
fn main() {
    darling::rpc_wire::print_sizes();
}
