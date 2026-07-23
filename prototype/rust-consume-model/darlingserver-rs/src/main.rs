// Minimal darlingserver shell. The real daemon runs the epoll + RPC + microthread
// scheduler loop; here we just FFI into the prebuilt C duct-tape to prove the
// consume-a-separately-built-project link path end to end.
extern "C" {
    fn dtape_init(nthreads: u32) -> u32;
}

fn main() {
    let n = unsafe { dtape_init(8) };
    println!("darlingserver-rs: linked prebuilt duct-tape, dtape_init(8) = {n}");
    // real: enter the RPC/scheduler loop here.
}
