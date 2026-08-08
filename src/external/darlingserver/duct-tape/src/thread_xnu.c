/* The COPIED-XNU half of thread.c, split out when the glue half moved to Rust (#71).
 *
 * The file marked these regions itself with <copied from="xnu://7195.141.2/...">. #71 is a port
 * of the GLUE, with XNU staying C, so this is where that boundary falls. Nothing here is edited:
 * it is the same text, moved, so a later diff against upstream still reads.
 */
#include <darlingserver/duct-tape/stubs.h>
#include <darlingserver/duct-tape.h>
#include <darlingserver/duct-tape/task.h>
#include <darlingserver/duct-tape/thread.h>
#include <darlingserver/duct-tape/hooks.internal.h>
#include <darlingserver/duct-tape/log.h>
#include <darlingserver/duct-tape/psynch.h>

#include <kern/thread.h>
#include <kern/ipc_tt.h>
#include <kern/policy_internal.h>
#include <mach/thread_act.h>
#include <sys/systm.h>
#include <sys/ux_exception.h>

#include <stdlib.h>

#include <rtsig.h>

/* Two things the split had to carry across, both because a file-local name cannot cross a
 * translation unit boundary. LockTimeOutUsec was a #define sitting just above the copied region
 * and belongs to it. thread_handoff_internal is GLUE that the copied code calls, so it loses its
 * static and is declared here; when thread.c becomes Rust it is Rust that provides the symbol. */
#define LockTimeOutUsec UINT32_MAX
wait_result_t thread_handoff_internal(thread_t thread, thread_continue_t continuation, void* parameter, thread_handoff_option_t option);

// <copied from="xnu://7195.141.2/osfmk/kern/sched_prim.c">

/*
 *	thread_wakeup_prim:
 *
 *	Common routine for thread_wakeup, thread_wakeup_with_result,
 *	and thread_wakeup_one.
 *
 */
kern_return_t
thread_wakeup_prim(
	event_t          event,
	boolean_t        one_thread,
	wait_result_t    result)
{
	if (__improbable(event == NO_EVENT)) {
		panic("%s() called with NO_EVENT", __func__);
	}

	struct waitq *wq = global_eventq(event);

	if (one_thread) {
		return waitq_wakeup64_one(wq, CAST_EVENT64_T(event), result, WAITQ_ALL_PRIORITIES);
	} else {
		return waitq_wakeup64_all(wq, CAST_EVENT64_T(event), result, WAITQ_ALL_PRIORITIES);
	}
}

/*
 * Wakeup a specified thread if and only if it's waiting for this event
 */
kern_return_t
thread_wakeup_thread(
	event_t         event,
	thread_t        thread)
{
	if (__improbable(event == NO_EVENT)) {
		panic("%s() called with NO_EVENT", __func__);
	}

	if (__improbable(thread == THREAD_NULL)) {
		panic("%s() called with THREAD_NULL", __func__);
	}

	struct waitq *wq = global_eventq(event);

	return waitq_wakeup64_thread(wq, CAST_EVENT64_T(event), thread, THREAD_AWAKENED);
}

/*
 *	assert_wait:
 *
 *	Assert that the current thread is about to go to
 *	sleep until the specified event occurs.
 */
wait_result_t
assert_wait(
	event_t                         event,
	wait_interrupt_t        interruptible)
{
	if (__improbable(event == NO_EVENT)) {
		panic("%s() called with NO_EVENT", __func__);
	}

	KERNEL_DEBUG_CONSTANT_IST(KDEBUG_TRACE,
	    MACHDBG_CODE(DBG_MACH_SCHED, MACH_WAIT) | DBG_FUNC_NONE,
	    VM_KERNEL_UNSLIDE_OR_PERM(event), 0, 0, 0, 0);

	struct waitq *waitq;
	waitq = global_eventq(event);
	return waitq_assert_wait64(waitq, CAST_EVENT64_T(event), interruptible, TIMEOUT_WAIT_FOREVER);
}

wait_result_t
assert_wait_timeout(
	event_t                         event,
	wait_interrupt_t        interruptible,
	uint32_t                        interval,
	uint32_t                        scale_factor)
{
	thread_t                        thread = current_thread();
	wait_result_t           wresult;
	uint64_t                        deadline;
	spl_t                           s;

	if (__improbable(event == NO_EVENT)) {
		panic("%s() called with NO_EVENT", __func__);
	}

	struct waitq *waitq;
	waitq = global_eventq(event);

	s = splsched();
	waitq_lock(waitq);

	clock_interval_to_deadline(interval, scale_factor, &deadline);

	KERNEL_DEBUG_CONSTANT_IST(KDEBUG_TRACE,
	    MACHDBG_CODE(DBG_MACH_SCHED, MACH_WAIT) | DBG_FUNC_NONE,
	    VM_KERNEL_UNSLIDE_OR_PERM(event), interruptible, deadline, 0, 0);

	wresult = waitq_assert_wait64_locked(waitq, CAST_EVENT64_T(event),
	    interruptible,
	    TIMEOUT_URGENCY_SYS_NORMAL,
	    deadline, TIMEOUT_NO_LEEWAY,
	    thread);

	waitq_unlock(waitq);
	splx(s);
	return wresult;
}

wait_result_t
assert_wait_deadline(
	event_t                         event,
	wait_interrupt_t        interruptible,
	uint64_t                        deadline)
{
	thread_t                        thread = current_thread();
	wait_result_t           wresult;
	spl_t                           s;

	if (__improbable(event == NO_EVENT)) {
		panic("%s() called with NO_EVENT", __func__);
	}

	struct waitq *waitq;
	waitq = global_eventq(event);

	s = splsched();
	waitq_lock(waitq);

	KERNEL_DEBUG_CONSTANT_IST(KDEBUG_TRACE,
	    MACHDBG_CODE(DBG_MACH_SCHED, MACH_WAIT) | DBG_FUNC_NONE,
	    VM_KERNEL_UNSLIDE_OR_PERM(event), interruptible, deadline, 0, 0);

	wresult = waitq_assert_wait64_locked(waitq, CAST_EVENT64_T(event),
	    interruptible,
	    TIMEOUT_URGENCY_SYS_NORMAL, deadline,
	    TIMEOUT_NO_LEEWAY, thread);
	waitq_unlock(waitq);
	splx(s);
	return wresult;
}

wait_result_t
assert_wait_deadline_with_leeway(
	event_t                         event,
	wait_interrupt_t        interruptible,
	wait_timeout_urgency_t  urgency,
	uint64_t                        deadline,
	uint64_t                        leeway)
{
	thread_t                        thread = current_thread();
	wait_result_t           wresult;
	spl_t                           s;

	if (__improbable(event == NO_EVENT)) {
		panic("%s() called with NO_EVENT", __func__);
	}

	struct waitq *waitq;
	waitq = global_eventq(event);

	s = splsched();
	waitq_lock(waitq);

	KERNEL_DEBUG_CONSTANT_IST(KDEBUG_TRACE,
	    MACHDBG_CODE(DBG_MACH_SCHED, MACH_WAIT) | DBG_FUNC_NONE,
	    VM_KERNEL_UNSLIDE_OR_PERM(event), interruptible, deadline, 0, 0);

	wresult = waitq_assert_wait64_locked(waitq, CAST_EVENT64_T(event),
	    interruptible,
	    urgency, deadline, leeway,
	    thread);
	waitq_unlock(waitq);
	splx(s);
	return wresult;
}

/*
 *	Routine: clear_wait_internal
 *
 *		Clear the wait condition for the specified thread.
 *		Start the thread executing if that is appropriate.
 *	Arguments:
 *		thread		thread to awaken
 *		result		Wakeup result the thread should see
 *	Conditions:
 *		At splsched
 *		the thread is locked.
 *	Returns:
 *		KERN_SUCCESS		thread was rousted out a wait
 *		KERN_FAILURE		thread was waiting but could not be rousted
 *		KERN_NOT_WAITING	thread was not waiting
 */
__private_extern__ kern_return_t
clear_wait_internal(
	thread_t                thread,
	wait_result_t   wresult)
{
	uint32_t        i = LockTimeOutUsec;
	struct waitq *waitq = thread->waitq;

	do {
		if (wresult == THREAD_INTERRUPTED && (thread->state & TH_UNINT)) {
			return KERN_FAILURE;
		}

		if (waitq != NULL) {
			if (!waitq_pull_thread_locked(waitq, thread)) {
				thread_unlock(thread);
				delay(1);
				if (i > 0 && !machine_timeout_suspended()) {
					i--;
				}
				thread_lock(thread);
				if (waitq != thread->waitq) {
					return KERN_NOT_WAITING;
				}
				continue;
			}
		}

		/* TODO: Can we instead assert TH_TERMINATE is not set?  */
		if ((thread->state & (TH_WAIT | TH_TERMINATE)) == TH_WAIT) {
			return thread_go(thread, wresult, WQ_OPTION_NONE);
		} else {
			return KERN_NOT_WAITING;
		}
	} while (i > 0);

	panic("clear_wait_internal: deadlock: thread=%p, wq=%p, cpu=%d\n",
	    thread, waitq, cpu_number());

	return KERN_FAILURE;
}


/*
 *	clear_wait:
 *
 *	Clear the wait condition for the specified thread.  Start the thread
 *	executing if that is appropriate.
 *
 *	parameters:
 *	  thread		thread to awaken
 *	  result		Wakeup result the thread should see
 */
kern_return_t
clear_wait(
	thread_t                thread,
	wait_result_t   result)
{
	kern_return_t ret;
	spl_t           s;

	s = splsched();
	thread_lock(thread);
	ret = clear_wait_internal(thread, result);
	thread_unlock(thread);
	splx(s);
	return ret;
}

/*
 *	Thread wait timer expiration.
 */
void
thread_timer_expire(
	void                    *p0,
	__unused void   *p1)
{
	thread_t                thread = p0;
	spl_t                   s;

	assert_thread_magic(thread);

	s = splsched();
	thread_lock(thread);
	if (--thread->wait_timer_active == 0) {
		if (thread->wait_timer_is_set) {
			thread->wait_timer_is_set = FALSE;
			clear_wait_internal(thread, THREAD_TIMED_OUT);
		}
	}
	thread_unlock(thread);
	splx(s);
}

/*
 *	assert_wait_queue:
 *
 *	Return the global waitq for the specified event
 */
struct waitq *
assert_wait_queue(
	event_t                         event)
{
	return global_eventq(event);
}

// </copied>

// <copied from="xnu://7195.141.2/osfmk/kern/thread.c">

kern_return_t
thread_assign(
	__unused thread_t                       thread,
	__unused processor_set_t        new_pset)
{
	return KERN_FAILURE;
}

/*
 *	thread_assign_default:
 *
 *	Special version of thread_assign for assigning threads to default
 *	processor set.
 */
kern_return_t
thread_assign_default(
	thread_t                thread)
{
	return thread_assign(thread, &pset0);
}

/*
 *	thread_get_assignment
 *
 *	Return current assignment for this thread.
 */
kern_return_t
thread_get_assignment(
	thread_t                thread,
	processor_set_t *pset)
{
	if (thread == NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	*pset = &pset0;

	return KERN_SUCCESS;
}

/*
 *  thread_get_mach_voucher - return a voucher reference for the specified thread voucher
 *
 *  Conditions:  nothing locked
 *
 *  NOTE:       At the moment, there is no distinction between the current and effective
 *		vouchers because we only set them at the thread level currently.
 */
kern_return_t
thread_get_mach_voucher(
	thread_act_t            thread,
	mach_voucher_selector_t __unused which,
	ipc_voucher_t           *voucherp)
{
	ipc_voucher_t           voucher;

	if (THREAD_NULL == thread) {
		return KERN_INVALID_ARGUMENT;
	}

	thread_mtx_lock(thread);
	voucher = thread->ith_voucher;

	if (IPC_VOUCHER_NULL != voucher) {
		ipc_voucher_reference(voucher);
		thread_mtx_unlock(thread);
		*voucherp = voucher;
		return KERN_SUCCESS;
	}

	thread_mtx_unlock(thread);

	*voucherp = IPC_VOUCHER_NULL;
	return KERN_SUCCESS;
}

/*
 *  thread_swap_mach_voucher - swap a voucher reference for the specified thread voucher
 *
 *  Conditions: callers holds a reference on the new and presumed old voucher(s).
 *		nothing locked.
 *
 *  This function is no longer supported.
 */
kern_return_t
thread_swap_mach_voucher(
	__unused thread_t               thread,
	__unused ipc_voucher_t          new_voucher,
	ipc_voucher_t                   *in_out_old_voucher)
{
	/*
	 * Currently this function is only called from a MIG generated
	 * routine which doesn't release the reference on the voucher
	 * addressed by in_out_old_voucher. To avoid leaking this reference,
	 * a call to release it has been added here.
	 */
	ipc_voucher_release(*in_out_old_voucher);
	return KERN_NOT_SUPPORTED;
}

kern_return_t
kernel_thread_start_priority(
	thread_continue_t       continuation,
	void                            *parameter,
	integer_t                       priority,
	thread_t                        *new_thread)
{
	kern_return_t   result;
	thread_t                thread;

	result = kernel_thread_create(continuation, parameter, priority, &thread);
	if (result != KERN_SUCCESS) {
		return result;
	}

	*new_thread = thread;

	thread_mtx_lock(thread);
	thread_start(thread);
	thread_mtx_unlock(thread);

	return result;
}

kern_return_t
kernel_thread_start(
	thread_continue_t       continuation,
	void                            *parameter,
	thread_t                        *new_thread)
{
	return kernel_thread_start_priority(continuation, parameter, -1, new_thread);
}

uint64_t
thread_tid(
	thread_t        thread)
{
	return thread != THREAD_NULL? thread->thread_id: 0;
}

/*
 *	thread_read_deallocate:
 *
 *	Drop a reference on thread read port.
 */
void
thread_read_deallocate(
	thread_read_t                thread_read)
{
	return thread_deallocate((thread_t)thread_read);
}

/*
 *	thread_inspect_deallocate:
 *
 *	Drop a thread inspection reference.
 */
void
thread_inspect_deallocate(
	thread_inspect_t                thread_inspect)
{
	return thread_deallocate((thread_t)thread_inspect);
}

// </copied>

// <copied from="xnu://7195.141.2/osfmk/kern/syscall_subr.c">

void
thread_handoff_parameter(thread_t thread, thread_continue_t continuation,
    void *parameter, thread_handoff_option_t option)
{
	thread_handoff_internal(thread, continuation, parameter, option);
	panic("NULL continuation passed to %s", __func__);
	__builtin_unreachable();
}

wait_result_t
thread_handoff_deallocate(thread_t thread, thread_handoff_option_t option)
{
	return thread_handoff_internal(thread, NULL, NULL, option);
}

// </copied>

// <copied from="xnu://7195.141.2/osfmk/kern/thread_act.c">

/*
 * Internal routine to mark a thread as waiting
 * right after it has been created.  The caller
 * is responsible to call wakeup()/thread_wakeup()
 * or thread_terminate() to get it going.
 *
 * Always called with the thread mutex locked.
 *
 * Task and task_threads mutexes also held
 * (so nobody can set the thread running before
 * this point)
 *
 * Converts TH_UNINT wait to THREAD_INTERRUPTIBLE
 * to allow termination from this point forward.
 */
void
thread_start_in_assert_wait(
	thread_t                        thread,
	event_t             event,
	wait_interrupt_t    interruptible)
{
	struct waitq *waitq = assert_wait_queue(event);
	wait_result_t wait_result;
	spl_t spl;

	spl = splsched();
	waitq_lock(waitq);

	/* clear out startup condition (safe because thread not started yet) */
	thread_lock(thread);
	assert(!thread->started);
	assert((thread->state & (TH_WAIT | TH_UNINT)) == (TH_WAIT | TH_UNINT));
	thread->state &= ~(TH_WAIT | TH_UNINT);
	thread_unlock(thread);

	/* assert wait interruptibly forever */
	wait_result = waitq_assert_wait64_locked(waitq, CAST_EVENT64_T(event),
	    interruptible,
	    TIMEOUT_URGENCY_SYS_NORMAL,
	    TIMEOUT_WAIT_FOREVER,
	    TIMEOUT_NO_LEEWAY,
	    thread);
	assert(wait_result == THREAD_WAITING);

	/* mark thread started while we still hold the waitq lock */
	thread_lock(thread);
	thread->started = TRUE;
	thread_unlock(thread);

	waitq_unlock(waitq);
	splx(spl);
}

void
thread_start(
	thread_t                        thread)
{
	clear_wait(thread, THREAD_AWAKENED);
	thread->started = TRUE;
}

kern_return_t
thread_get_state_to_user(
	thread_t                thread,
	int                                             flavor,
	thread_state_t                  state,                  /* pointer to OUT array */
	mach_msg_type_number_t  *state_count)   /*IN/OUT*/
{
	return thread_get_state_internal(thread, flavor, state, state_count, TRUE);
}

kern_return_t
thread_suspend(thread_t thread)
{
	kern_return_t result = KERN_SUCCESS;

	if (thread == THREAD_NULL || thread->task == kernel_task) {
		return KERN_INVALID_ARGUMENT;
	}

	thread_mtx_lock(thread);

	if (thread->active) {
		if (thread->user_stop_count++ == 0) {
			thread_hold(thread);
		}
	} else {
		result = KERN_TERMINATED;
	}

	thread_mtx_unlock(thread);

	if (thread != current_thread() && result == KERN_SUCCESS) {
		thread_wait(thread, FALSE);
	}

	return result;
}

kern_return_t
thread_resume(thread_t thread)
{
	kern_return_t result = KERN_SUCCESS;

	if (thread == THREAD_NULL || thread->task == kernel_task) {
		return KERN_INVALID_ARGUMENT;
	}

	thread_mtx_lock(thread);

	if (thread->active) {
		if (thread->user_stop_count > 0) {
			if (--thread->user_stop_count == 0) {
				thread_release(thread);
			}
		} else {
			result = KERN_FAILURE;
		}
	} else {
		result = KERN_TERMINATED;
	}

	thread_mtx_unlock(thread);

	return result;
}

// </copied>

// <copied from="xnu://7195.141.2/bsd/uxkern/ux_exception.c">

/*
 * Translate Mach exceptions to UNIX signals.
 *
 * ux_exception translates a mach exception, code and subcode to
 * a signal.  Calls machine_exception (machine dependent)
 * to attempt translation first.
 */
#ifdef __DARLING__
int
#else
static int
#endif
ux_exception(int                        exception,
    mach_exception_code_t      code,
    mach_exception_subcode_t   subcode)
{
	int machine_signal = 0;

#ifndef __DARLING__
	/* Try machine-dependent translation first. */
	if ((machine_signal = machine_exception(exception, code, subcode)) != 0) {
		return machine_signal;
	}
#endif

	switch (exception) {
	case EXC_BAD_ACCESS:
		if (code == KERN_INVALID_ADDRESS) {
			return SIGSEGV;
		} else {
			return SIGBUS;
		}

	case EXC_BAD_INSTRUCTION:
		return SIGILL;

	case EXC_ARITHMETIC:
		return SIGFPE;

#ifndef __DARLING__
	case EXC_EMULATION:
		return SIGEMT;
#endif

	case EXC_SOFTWARE:
		switch (code) {
		case EXC_UNIX_BAD_SYSCALL:
			return SIGSYS;
		case EXC_UNIX_BAD_PIPE:
			return SIGPIPE;
		case EXC_UNIX_ABORT:
			return SIGABRT;
		case EXC_SOFT_SIGNAL:
			return SIGKILL;
		}
		break;

	case EXC_BREAKPOINT:
		return SIGTRAP;
	}

	return 0;
}

// </copied>
