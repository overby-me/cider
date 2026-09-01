#if defined(__x86_64__)

.macro trampoline_enter
pushq %rbp
movq %rsp, %rbp

# Align the stack
andq $$~15, %rsp
# There's an odd number of pushq's below
subq $$8, %rsp

# Re-push possible 7th and 8th arg
movq 40(%rbp), %r11
pushq %r11
movq 32(%rbp), %r11
pushq %r11

# Push args from 1st to 6th
pushq %r9
pushq %r8
pushq %rcx
pushq %rdx
pushq %rsi
pushq %rdi
pushq %rax

# Pass the syscall num and the pointer
# to the on-stack buffer as arguments
movq %rax, %rdi
leaq 8(%rsp), %rsi
.endmacro

.macro trampoline_leave
# Read back the registers
popq %rax
popq %rdi
popq %rsi
popq %rdx
popq %rcx
popq %r8
popq %r9
leave
ret
.endmacro

#elif defined(__i386__)

.macro trampoline_enter
pushl %ebp
movl %esp, %ebp

# align the stack
andl $$~15, %esp

#define copy_arg(off) \
	movl 16+off(%ebp), %ecx ;\
	movl %ecx, -56+off(%esp)

// copy the arguments (same as in syscalls-table.S and cider_mach_syscall.S)
copy_arg(0)
copy_arg(4)
copy_arg(8)
copy_arg(12)
copy_arg(16)
copy_arg(20)
copy_arg(24)
copy_arg(28)
copy_arg(32)
copy_arg(36)
copy_arg(40)
copy_arg(44)
copy_arg(48)
copy_arg(52)

# make space on the stack now for the arguments we just copied
subl $$56, %esp

# push the address of the argument area as the second argument
pushl %esp

# push the call number or return value as the first argument
pushl %eax
.endmacro

.macro trampoline_leave
# restore eax (i.e. the call number or return value)
popl %eax
leave
ret
.endmacro

#endif

#if defined(__x86_64__) || defined(__i386__)

.private_extern _cider_mach_syscall_entry_trampoline
_cider_mach_syscall_entry_trampoline:
	trampoline_enter
	call _cider_mach_syscall_entry_print
	trampoline_leave

.private_extern _cider_mach_syscall_exit_trampoline
_cider_mach_syscall_exit_trampoline:
	trampoline_enter
	call _cider_mach_syscall_exit_print
	trampoline_leave

.private_extern _cider_bsd_syscall_entry_trampoline
_cider_bsd_syscall_entry_trampoline:
	trampoline_enter
	call _cider_bsd_syscall_entry_print
	trampoline_leave

.private_extern _cider_bsd_syscall_exit_trampoline
_cider_bsd_syscall_exit_trampoline:
	trampoline_enter
	call _cider_bsd_syscall_exit_print
	trampoline_leave

#elif defined(__arm64__) || defined(__aarch64__)

// ARM64. Save the syscall argument registers x0-x7 and the syscall number x16 around the
// print call, then restore them so the traced call continues untouched. The entry handlers
// take (int nr, void* args[]) -- nr is the number in x16, args points at the saved x0-x7 --
// while the exit handlers take (uintptr_t retval), which arm64 returns in x0. That split is
// why entry and exit set up the first argument differently (on x86 rax was both).
.macro tramp_save
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	sub sp, sp, #80
	stp x0, x1, [sp, #0]
	stp x2, x3, [sp, #16]
	stp x4, x5, [sp, #32]
	stp x6, x7, [sp, #48]
	str x16, [sp, #64]
.endmacro

.macro tramp_restore
	ldp x0, x1, [sp, #0]
	ldp x2, x3, [sp, #16]
	ldp x4, x5, [sp, #32]
	ldp x6, x7, [sp, #48]
	ldr x16, [sp, #64]
	add sp, sp, #80
	ldp x29, x30, [sp], #16
	ret
.endmacro

.private_extern _cider_mach_syscall_entry_trampoline
_cider_mach_syscall_entry_trampoline:
	tramp_save
	mov x0, x16        // arg1 = syscall number
	mov x1, sp         // arg2 = pointer to saved x0-x7
	bl _cider_mach_syscall_entry_print
	tramp_restore

.private_extern _cider_mach_syscall_exit_trampoline
_cider_mach_syscall_exit_trampoline:
	tramp_save         // x0 already holds the return value -> arg1
	bl _cider_mach_syscall_exit_print
	tramp_restore

.private_extern _cider_bsd_syscall_entry_trampoline
_cider_bsd_syscall_entry_trampoline:
	tramp_save
	mov x0, x16        // arg1 = syscall number
	mov x1, sp         // arg2 = pointer to saved x0-x7
	bl _cider_bsd_syscall_entry_print
	tramp_restore

.private_extern _cider_bsd_syscall_exit_trampoline
_cider_bsd_syscall_exit_trampoline:
	tramp_save         // x0 already holds the return value -> arg1
	bl _cider_bsd_syscall_exit_print
	tramp_restore

#endif
