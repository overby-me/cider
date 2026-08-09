/*
 * Signal-mask-free drop-in getcontext/setcontext/makecontext for x86_64 System V
 * (Linux/glibc). ciderd's microthreads switch cooperatively on one worker
 * thread with an invariant signal mask, so glibc's per-switch rt_sigprocmask
 * (save/restore uc_sigmask) is pure overhead. These variants swap only the
 * callee-saved registers + RSP + RIP + callee-saved FP control (MXCSR, x87 CW),
 * never touching the signal mask.
 *
 * Saved state lives in the glibc ucontext_t's uc_mcontext.gregs[] at the REG_*
 * indices; the byte offsets used by the assembly are checked against the real
 * header by _Static_assert below, so a layout mismatch is a build error.
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
