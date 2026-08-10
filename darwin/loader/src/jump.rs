// mldr M5b: the final stack switch + jump into dyld (linux/startup/mldr/mldr.c:912-943).
// Load the guest stack into %rsp, zero %rbp, and jmp to the (slid) entry point. This never
// returns -- it abandons the Rust runtime's stack -- so every mapping, the start stack, the
// commpage, and the checkin must be complete before this is called.
pub unsafe fn jump_to_entry(entry: u64, sp: u64) -> ! {
    core::arch::asm!(
        "mov rsp, {sp}",
        "xor rbp, rbp",
        "jmp {entry}",
        sp = in(reg) sp,
        entry = in(reg) entry,
        options(noreturn),
    );
}
