/*
 * Exercises the ucontext primitives in the shapes ciderd's thread.cpp
 * uses them (branching on GLOBAL flags across a switch, never on locals — locals
 * are not preserved across getcontext/setcontext, by design). Compile once
 * against glibc (reference) and once with -DUSE_FAST; outputs must match.
 * Hard caps guard against runaway if a switch misbehaves.
 */
#define _GNU_SOURCE
#include <ucontext.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef USE_FAST
extern int  dserver_fast_getcontext(ucontext_t*);
extern void dserver_fast_setcontext(const ucontext_t*);
extern void dserver_fast_makecontext(ucontext_t*, void (*)(void), int, ...);
#define GET  dserver_fast_getcontext
#define SET  dserver_fast_setcontext
#define MAKE dserver_fast_makecontext
#else
#define GET  getcontext
#define SET  setcontext
#define MAKE makecontext
#endif

static ucontext_t topCtx;        /* like thread_local backToThreadTopContext */
static ucontext_t resumeCtx;     /* like Thread::_resumeContext */
static char wstack[256 * 1024] __attribute__((aligned(16)));

/* ---- Test A: setjmp-style resume loop driven by a global flag ------------- */
static volatile int aReturning;
static volatile int aCount;
static void testA(void) {
	aReturning = 0;
	aCount = 0;
	GET(&topCtx);
	if (aReturning) {
		printf("A resumed, count=%d\n", aCount);
		if (aCount >= 3)
			return;
	}
	aReturning = 1;
	if (++aCount > 10) { printf("A RUNAWAY\n"); return; }
	printf("A pass %d\n", aCount);
	SET(&topCtx);
}

/* ---- Test B: makecontext on a new stack, return via uc_link --------------- */
static volatile long bAccum;
static volatile int  bDone;
static void workerB(void) {
	volatile long x = 0;
	for (int i = 1; i <= 5; ++i) x += i;   /* callee-saved churn on fresh stack */
	bAccum = x;                            /* expect 15 */
	printf("B worker ran, x=%ld\n", x);
	/* fall off the end -> uc_link (topCtx) */
}
static void testB(void) {
	bAccum = 0;
	bDone = 0;
	GET(&topCtx);
	if (bDone) {
		printf("B back in main, accum=%ld\n", bAccum);
		return;
	}
	bDone = 1;
	GET(&resumeCtx);
	resumeCtx.uc_stack.ss_sp = wstack;
	resumeCtx.uc_stack.ss_size = sizeof(wstack);
	resumeCtx.uc_link = &topCtx;
	MAKE(&resumeCtx, workerB, 0);
	SET(&resumeCtx);
	printf("B UNREACHABLE\n");
}

/* ---- Test C: cooperative yield/resume, mimicking suspend()/doWork() -------- */
static ucontext_t cTop;          /* scheduler top (per "worker thread") */
static ucontext_t cResume;       /* worker's saved resume point */
static char cstack[256 * 1024] __attribute__((aligned(16)));
static volatile int  cReturningToTop;
static volatile int  cWorkerStarted;
static volatile int  cWorkerDone;
static volatile int  cSuspended;
static volatile int  cStep;
static volatile long cAccum;

static void workerC(void) {
	for (cStep = 1; cStep <= 3; ++cStep) {
		cAccum += cStep * 10;
		printf("C worker step %d, accum=%ld\n", cStep, cAccum);
		/* suspend(): save resume point; if still suspended, yield to scheduler
		 * (the scheduler clears cSuspended right before resuming us). */
		cSuspended = 1;
		GET(&cResume);
		if (cSuspended)
			SET(&cTop);
	}
	cWorkerDone = 1;
	printf("C worker done, accum=%ld\n", cAccum);
	SET(&cTop);
}

static void testC(void) {
	cReturningToTop = 0;
	cWorkerStarted = 0;
	cWorkerDone = 0;
	cAccum = 0;
	int guard = 0;
	for (;;) {
		if (++guard > 50) { printf("C RUNAWAY\n"); return; }
		cReturningToTop = 0;
		GET(&cTop);
		if (cReturningToTop) {
			if (cWorkerDone) {
				printf("C scheduler: worker done\n");
				return;
			}
			printf("C scheduler: worker suspended at step %d\n", cStep);
		}
		cReturningToTop = 1;
		if (!cWorkerStarted) {
			cWorkerStarted = 1;
			GET(&cResume);
			cResume.uc_stack.ss_sp = cstack;
			cResume.uc_stack.ss_size = sizeof(cstack);
			cResume.uc_link = &cTop;
			MAKE(&cResume, workerC, 0);
			SET(&cResume);
		} else {
			cSuspended = 0;  /* clear before resuming the worker */
			SET(&cResume);   /* resume suspended worker where it yielded */
		}
	}
}

int main(void) {
	printf("== A ==\n"); testA();
	printf("== B ==\n"); testB();
	printf("== C ==\n"); testC();
	printf("== END ==\n");
	return 0;
}
