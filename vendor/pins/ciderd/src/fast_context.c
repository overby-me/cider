/*
 * Signal-mask-free drop-in getcontext/setcontext/makecontext for x86_64 and
 * aarch64 System V (Linux/glibc). ciderd's microthreads switch cooperatively on
 * one worker thread with an invariant signal mask, so glibc's per-switch
 * rt_sigprocmask (save/restore uc_sigmask) is pure overhead. These variants
 * swap only the callee-saved registers + SP + PC + callee-saved FP control
 * (MXCSR and x87 CW on x86_64, FPCR and d8-d15 on aarch64), never touching the
 * signal mask.
 *
 * Saved state lives in the glibc ucontext_t's uc_mcontext at fixed offsets; the
 * byte offsets used by the assembly are checked against the real header by
 * _Static_assert below, so a layout mismatch is a build error.
 *
 * The switch routines are naked assembly (they must capture the caller's
 * callee-saved regs before any prologue), written as a file-scope asm block so
 * the whole primitive is one translation unit (no separate .S / ASM language).
 */
#define _GNU_SOURCE
#include <ucontext.h>
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

#if defined(__x86_64__)

/* Offsets of gregs[i] within ucontext_t (uc_mcontext @ 40, gregs[i] @ 40+8i). */
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_R12]) == 72,  "G_R12");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_R13]) == 80,  "G_R13");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_R14]) == 88,  "G_R14");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_R15]) == 96,  "G_R15");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_RDI]) == 104, "G_RDI");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_RSI]) == 112, "G_RSI");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_RBP]) == 120, "G_RBP");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_RBX]) == 128, "G_RBX");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_RSP]) == 160, "G_RSP");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_RIP]) == 168, "G_RIP");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_CSGSFS]) == 184, "G_MXCSR");
_Static_assert(offsetof(ucontext_t, uc_mcontext.gregs[REG_ERR]) == 192, "G_FCW");

__asm__(
"	.text\n"
/* int dserver_fast_getcontext(ucontext_t *ucp)  [rdi=ucp]; setjmp-style save. */
"	.globl dserver_fast_getcontext\n"
"	.type dserver_fast_getcontext,@function\n"
"dserver_fast_getcontext:\n"
"	movq %rbx, 128(%rdi)\n"
"	movq %rbp, 120(%rdi)\n"
"	movq %r12, 72(%rdi)\n"
"	movq %r13, 80(%rdi)\n"
"	movq %r14, 88(%rdi)\n"
"	movq %r15, 96(%rdi)\n"
"	movq (%rsp), %rcx\n"          /* return address -> resume RIP */
"	movq %rcx, 168(%rdi)\n"
"	leaq 8(%rsp), %rcx\n"         /* caller's rsp -> resume RSP */
"	movq %rcx, 160(%rdi)\n"
"	stmxcsr 184(%rdi)\n"
"	fnstcw 192(%rdi)\n"
"	xorl %eax, %eax\n"
"	ret\n"
"	.size dserver_fast_getcontext,.-dserver_fast_getcontext\n"
/* void dserver_fast_setcontext(const ucontext_t *ucp) [rdi=ucp]; restore+jump. */
"	.globl dserver_fast_setcontext\n"
"	.type dserver_fast_setcontext,@function\n"
"dserver_fast_setcontext:\n"
"	ldmxcsr 184(%rdi)\n"
"	fldcw 192(%rdi)\n"
"	movq 128(%rdi), %rbx\n"
"	movq 120(%rdi), %rbp\n"
"	movq 72(%rdi), %r12\n"
"	movq 80(%rdi), %r13\n"
"	movq 88(%rdi), %r14\n"
"	movq 96(%rdi), %r15\n"
"	movq 160(%rdi), %rsp\n"
"	movq 168(%rdi), %rcx\n"       /* target RIP */
"	movq 112(%rdi), %rsi\n"
"	movq 104(%rdi), %rdi\n"       /* restore arg1 last (frees rdi) */
"	jmp *%rcx\n"
"	.size dserver_fast_setcontext,.-dserver_fast_setcontext\n"
/* Trampoline an entry function returns into: r12 still holds uc_link. */
"	.globl dserver_fast_startcontext\n"
"	.type dserver_fast_startcontext,@function\n"
"dserver_fast_startcontext:\n"
"	movq %r12, %rdi\n"
"	testq %rdi, %rdi\n"
"	je 1f\n"
"	call dserver_fast_setcontext\n"
"1:\n"
"	xorl %edi, %edi\n"
"	call _exit@PLT\n"
"	.size dserver_fast_startcontext,.-dserver_fast_startcontext\n"
);

extern void dserver_fast_startcontext(void);

/*
 * Set up *ucp so dserver_fast_setcontext(ucp) begins executing func() on
 * ucp->uc_stack; when func returns, control transfers to ucp->uc_link.
 * ciderd only uses argc == 0; a couple of integer args are supported.
 */
void dserver_fast_makecontext(ucontext_t* ucp, void (*func)(void), int argc, ...) {
	uintptr_t sp = (uintptr_t)ucp->uc_stack.ss_sp + ucp->uc_stack.ss_size;
	sp &= ~(uintptr_t)15;                 /* 16-align the stack top */
	sp -= 8;                              /* trampoline return-address slot */
	*(uintptr_t*)sp = (uintptr_t)dserver_fast_startcontext;
	/* Now (sp % 16) == 8, exactly the ABI's expectation at function entry. */

	ucp->uc_mcontext.gregs[REG_RSP] = (greg_t)sp;
	ucp->uc_mcontext.gregs[REG_RIP] = (greg_t)func;
	/* Smuggle uc_link through r12 (callee-saved -> preserved to func return). */
	ucp->uc_mcontext.gregs[REG_R12] = (greg_t)(uintptr_t)ucp->uc_link;

	ucp->uc_mcontext.gregs[REG_RDI] = 0;
	ucp->uc_mcontext.gregs[REG_RSI] = 0;
	if (argc > 0) {
		va_list ap;
		va_start(ap, argc);
		if (argc >= 1) ucp->uc_mcontext.gregs[REG_RDI] = va_arg(ap, greg_t);
		if (argc >= 2) ucp->uc_mcontext.gregs[REG_RSI] = va_arg(ap, greg_t);
		va_end(ap);
	}

	__asm__ __volatile__("stmxcsr %0" : "=m"(*(uint32_t*)&ucp->uc_mcontext.gregs[REG_CSGSFS]));
	__asm__ __volatile__("fnstcw %0"  : "=m"(*(uint16_t*)&ucp->uc_mcontext.gregs[REG_ERR]));
}

#elif defined(__aarch64__)

/*
 * aarch64 layout (glibc): uc_mcontext @ 176; inside it regs[i] @ +8+8i, sp @
 * +256, pc @ +264, __reserved @ +288. The asm below uses the absolute offsets
 * within ucontext_t. AAPCS64 callee-saved set: x19-x28, x29 (fp); d8-d15 (low
 * halves of v8-v15); FPCR is the only floating-point control state. x30 (lr)
 * is stored so a resumed frame still holds its return address, and pc doubles
 * as the branch target the way RIP does above.
 *
 * The d8-d15 + FPCR save area is OUR OWN layout inside __reserved: the kernel
 * writes an fpsimd_context there when delivering a signal, but these contexts
 * never pass through the kernel, so the space is free for the fast path.
 */
_Static_assert(offsetof(ucontext_t, uc_mcontext) == 176, "MC");
_Static_assert(offsetof(ucontext_t, uc_mcontext.regs[0])  == 184, "X0");
_Static_assert(offsetof(ucontext_t, uc_mcontext.regs[1])  == 192, "X1");
_Static_assert(offsetof(ucontext_t, uc_mcontext.regs[19]) == 336, "X19");
_Static_assert(offsetof(ucontext_t, uc_mcontext.regs[29]) == 416, "X29");
_Static_assert(offsetof(ucontext_t, uc_mcontext.regs[30]) == 424, "X30");
_Static_assert(offsetof(ucontext_t, uc_mcontext.sp)       == 432, "SP");
_Static_assert(offsetof(ucontext_t, uc_mcontext.pc)       == 440, "PC");
_Static_assert(offsetof(ucontext_t, uc_mcontext.__reserved) == 464, "FP_AREA");

__asm__(
"	.text\n"
/* int dserver_fast_getcontext(ucontext_t *ucp)  [x0=ucp]; setjmp-style save. */
"	.globl dserver_fast_getcontext\n"
"	.type dserver_fast_getcontext,@function\n"
"dserver_fast_getcontext:\n"
"	stp x19, x20, [x0, #336]\n"
"	stp x21, x22, [x0, #352]\n"
"	stp x23, x24, [x0, #368]\n"
"	stp x25, x26, [x0, #384]\n"
"	stp x27, x28, [x0, #400]\n"
"	stp x29, x30, [x0, #416]\n"
"	mov x9, sp\n"
"	str x9, [x0, #432]\n"
"	str x30, [x0, #440]\n"        /* return address -> resume PC */
"	add x10, x0, #464\n"          /* stp immediates cap at 504, so base-bump */
"	stp d8, d9,  [x10]\n"
"	stp d10, d11, [x10, #16]\n"
"	stp d12, d13, [x10, #32]\n"
"	stp d14, d15, [x10, #48]\n"
"	mrs x9, fpcr\n"
"	str x9, [x10, #64]\n"
"	mov w0, #0\n"
"	ret\n"
"	.size dserver_fast_getcontext,.-dserver_fast_getcontext\n"
/* void dserver_fast_setcontext(const ucontext_t *ucp) [x0=ucp]; restore+jump. */
"	.globl dserver_fast_setcontext\n"
"	.type dserver_fast_setcontext,@function\n"
"dserver_fast_setcontext:\n"
"	add x10, x0, #464\n"
"	ldr x9, [x10, #64]\n"
"	msr fpcr, x9\n"
"	ldp d8, d9,  [x10]\n"
"	ldp d10, d11, [x10, #16]\n"
"	ldp d12, d13, [x10, #32]\n"
"	ldp d14, d15, [x10, #48]\n"
"	ldp x19, x20, [x0, #336]\n"
"	ldp x21, x22, [x0, #352]\n"
"	ldp x23, x24, [x0, #368]\n"
"	ldp x25, x26, [x0, #384]\n"
"	ldp x27, x28, [x0, #400]\n"
"	ldp x29, x30, [x0, #416]\n"
"	ldr x9, [x0, #432]\n"
"	mov sp, x9\n"
"	ldr x9, [x0, #440]\n"         /* target PC */
"	ldr x1, [x0, #192]\n"
"	ldr x0, [x0, #184]\n"         /* restore arg1 last (frees x0) */
"	br x9\n"
"	.size dserver_fast_setcontext,.-dserver_fast_setcontext\n"
/* Trampoline an entry function returns into: x19 still holds uc_link. */
"	.globl dserver_fast_startcontext\n"
"	.type dserver_fast_startcontext,@function\n"
"dserver_fast_startcontext:\n"
"	mov x0, x19\n"
"	cbz x0, 1f\n"
"	bl dserver_fast_setcontext\n"
"1:\n"
"	mov w0, #0\n"
"	bl _exit\n"
"	.size dserver_fast_startcontext,.-dserver_fast_startcontext\n"
);

extern void dserver_fast_startcontext(void);

/*
 * Set up *ucp so dserver_fast_setcontext(ucp) begins executing func() on
 * ucp->uc_stack; when func returns, control transfers to ucp->uc_link.
 * ciderd only uses argc == 0; a couple of integer args are supported.
 */
void dserver_fast_makecontext(ucontext_t* ucp, void (*func)(void), int argc, ...) {
	uintptr_t sp = (uintptr_t)ucp->uc_stack.ss_sp + ucp->uc_stack.ss_size;
	sp &= ~(uintptr_t)15;                 /* AAPCS64: sp stays 16-aligned, no return slot */

	ucp->uc_mcontext.sp = sp;
	ucp->uc_mcontext.pc = (uintptr_t)func;
	/* func returns through lr -> the trampoline. */
	ucp->uc_mcontext.regs[30] = (uintptr_t)dserver_fast_startcontext;
	/* Smuggle uc_link through x19 (callee-saved -> preserved to func return). */
	ucp->uc_mcontext.regs[19] = (uintptr_t)ucp->uc_link;

	ucp->uc_mcontext.regs[0] = 0;
	ucp->uc_mcontext.regs[1] = 0;
	if (argc > 0) {
		va_list ap;
		va_start(ap, argc);
		if (argc >= 1) ucp->uc_mcontext.regs[0] = va_arg(ap, unsigned long);
		if (argc >= 2) ucp->uc_mcontext.regs[1] = va_arg(ap, unsigned long);
		va_end(ap);
	}

	/* d8-d15 start as zero; FPCR is inherited from the creator, like MXCSR above. */
	uint64_t* fp_area = (uint64_t*)&ucp->uc_mcontext.__reserved[0];
	for (int i = 0; i < 8; i++)
		fp_area[i] = 0;
	uint64_t fpcr;
	__asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
	fp_area[8] = fpcr;
}

#else
#error fast_context: unsupported architecture
#endif
