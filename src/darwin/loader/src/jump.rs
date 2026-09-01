// mldr M5b: the final stack switch + jump into dyld (src/linux/startup/mldr/mldr.c:912-943).
// Load the guest stack into %rsp, zero %rbp, and jmp to the (slid) entry point. This never
// returns -- it abandons the Rust runtime's stack -- so every mapping, the start stack, the
// commpage, and the checkin must be complete before this is called.
pub unsafe fn jump_to_entry(entry: u64, sp: u64) -> ! {
    #[cfg(target_arch = "x86_64")]
    core::arch::asm!(
        "mov rsp, {sp}",
        "xor rbp, rbp",
        "jmp {entry}",
        sp = in(reg) sp,
        entry = in(reg) entry,
        options(noreturn),
    );
    // arm64 (aarch64 port, task A17): load the guest stack into sp, zero the frame pointer,
    // and branch to the entry. `mov sp, xN` is the only way to write sp on arm64.
    #[cfg(target_arch = "aarch64")]
    core::arch::asm!(
        "mov sp, {sp}",
        "mov x29, xzr",
        "br {entry}",
        sp = in(reg) sp,
        entry = in(reg) entry,
        options(noreturn),
    );
}
