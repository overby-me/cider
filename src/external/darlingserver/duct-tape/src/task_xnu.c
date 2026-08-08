/* The COPIED-XNU half of task.c, split out when the glue half moved to Rust (#71).
 *
 * task.c was 1,766 lines of which only about 763 were Darling glue; the rest is verbatim XNU,
 * and the file marked it itself with <copied from="xnu://7195.141.2/..."> for osfmk/kern/
 * task_policy.c, osfmk/kern/task.c and osfmk/kern/zalloc.c. #71 is a port of the GLUE, with XNU
 * staying C, so this is where that boundary falls for this file. Nothing here is edited: it is
 * the same text, moved, so a later diff against upstream still reads.
 */
#include "darlingserver/rpc.h"
#include "mach/kern_return.h"
#include "mach/task_info.h"
#include <darlingserver/duct-tape/stubs.h>
#include <darlingserver/duct-tape.h>
#include <darlingserver/duct-tape/task.h>
#include <darlingserver/duct-tape/memory.h>
#include <darlingserver/duct-tape/psynch.h>
#include <darlingserver/duct-tape/hooks.internal.h>
#include <darlingserver/duct-tape/log.h>

#include <kern/task.h>
#include <kern/ipc_tt.h>
#include <kern/policy_internal.h>
#include <ipc/ipc_importance.h>
#include <kern/restartable.h>
#include <kern/sync_sema.h>
#include <mach/mach_traps.h>
#include <mach/mach_port.h>
#include <ipc/ipc_hash.h>

#include <stdlib.h>
// <copied from="xnu://7195.141.2/osfmk/kern/task_policy.c">

/*
 * Check if this task should donate importance.
 *
 * May be called without taking the task lock. In that case, donor status can change
 * so you must check only once for each donation event.
 */
boolean_t
task_is_importance_donor(task_t task)
{
	if (task->task_imp_base == IIT_NULL) {
		return FALSE;
	}
	return ipc_importance_task_is_donor(task->task_imp_base);
}

/*
 *      task_policy
 *
 *	Set scheduling policy and parameters, both base and limit, for
 *	the given task. Policy must be a policy which is enabled for the
 *	processor set. Change contained threads if requested.
 */
kern_return_t
task_policy(
	__unused task_t                 task,
	__unused policy_t                       policy_id,
	__unused policy_base_t          base,
	__unused mach_msg_type_number_t count,
	__unused boolean_t                      set_limit,
	__unused boolean_t                      change)
{
	return KERN_FAILURE;
}

/*
 * Query the status of the task's donor mark.
 */
boolean_t
task_is_marked_importance_donor(task_t task)
{
	if (task->task_imp_base == IIT_NULL) {
		return FALSE;
	}
	return ipc_importance_task_is_marked_donor(task->task_imp_base);
}

/*
 * Query the status of the task's live donor and donor mark.
 */
boolean_t
task_is_marked_live_importance_donor(task_t task)
{
	if (task->task_imp_base == IIT_NULL) {
		return FALSE;
	}
	return ipc_importance_task_is_marked_live_donor(task->task_imp_base);
}

/*
 * Query the task's receiver mark.
 */
boolean_t
task_is_marked_importance_receiver(task_t task)
{
	if (task->task_imp_base == IIT_NULL) {
		return FALSE;
	}
	return ipc_importance_task_is_marked_receiver(task->task_imp_base);
}

/*
 * This routine may be called without holding task lock
 * since the value of de-nap receiver can never be unset.
 */
boolean_t
task_is_importance_denap_receiver(task_t task)
{
	if (task->task_imp_base == IIT_NULL) {
		return FALSE;
	}
	return ipc_importance_task_is_denap_receiver(task->task_imp_base);
}

/*
 * Query the task's de-nap receiver mark.
 */
boolean_t
task_is_marked_importance_denap_receiver(task_t task)
{
	if (task->task_imp_base == IIT_NULL) {
		return FALSE;
	}
	return ipc_importance_task_is_marked_denap_receiver(task->task_imp_base);
}

void
task_importance_init_from_parent(task_t new_task, task_t parent_task)
{
#if IMPORTANCE_INHERITANCE
	ipc_importance_task_t new_task_imp = IIT_NULL;

	new_task->task_imp_base = NULL;
	if (!parent_task) {
		return;
	}

	if (task_is_marked_importance_donor(parent_task)) {
		new_task_imp = ipc_importance_for_task(new_task, FALSE);
		assert(IIT_NULL != new_task_imp);
		ipc_importance_task_mark_donor(new_task_imp, TRUE);
	}
	if (task_is_marked_live_importance_donor(parent_task)) {
		if (IIT_NULL == new_task_imp) {
			new_task_imp = ipc_importance_for_task(new_task, FALSE);
		}
		assert(IIT_NULL != new_task_imp);
		ipc_importance_task_mark_live_donor(new_task_imp, TRUE);
	}
	/* Do not inherit 'receiver' on fork, vfexec or true spawn */
	if (task_is_exec_copy(new_task) &&
	    task_is_marked_importance_receiver(parent_task)) {
		if (IIT_NULL == new_task_imp) {
			new_task_imp = ipc_importance_for_task(new_task, FALSE);
		}
		assert(IIT_NULL != new_task_imp);
		ipc_importance_task_mark_receiver(new_task_imp, TRUE);
	}
	if (task_is_marked_importance_denap_receiver(parent_task)) {
		if (IIT_NULL == new_task_imp) {
			new_task_imp = ipc_importance_for_task(new_task, FALSE);
		}
		assert(IIT_NULL != new_task_imp);
		ipc_importance_task_mark_denap_receiver(new_task_imp, TRUE);
	}
	if (IIT_NULL != new_task_imp) {
		assert(new_task->task_imp_base == new_task_imp);
		ipc_importance_task_release(new_task_imp);
	}
#endif /* IMPORTANCE_INHERITANCE */
}

// </copied>

// <copied from="xnu://7195.141.2/osfmk/kern/task.c">

boolean_t
task_get_filter_msg_flag(
	task_t task)
{
	uint32_t flags = 0;

	if (!task) {
		return false;
	}

	flags = os_atomic_load(&task->t_flags, relaxed);
	return (flags & TF_FILTER_MSG) ? TRUE : FALSE;
}

/*
 *	task_assign:
 *
 *	Change the assigned processor set for the task
 */
kern_return_t
task_assign(
	__unused task_t         task,
	__unused processor_set_t        new_pset,
	__unused boolean_t      assign_threads)
{
	return KERN_FAILURE;
}

/*
 *	task_assign_default:
 *
 *	Version of task_assign to assign to default processor set.
 */
kern_return_t
task_assign_default(
	task_t          task,
	boolean_t       assign_threads)
{
	return task_assign(task, &pset0, assign_threads);
}

kern_return_t
task_create(
	task_t                          parent_task,
	__unused ledger_port_array_t    ledger_ports,
	__unused mach_msg_type_number_t num_ledger_ports,
	__unused boolean_t              inherit_memory,
	__unused task_t                 *child_task)    /* OUT */
{
	if (parent_task == TASK_NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	/*
	 * No longer supported: too many calls assume that a task has a valid
	 * process attached.
	 */
	return KERN_FAILURE;
}

kern_return_t
task_get_dyld_image_infos(__unused task_t task,
    __unused dyld_kernel_image_info_array_t * dyld_images,
    __unused mach_msg_type_number_t * dyld_imagesCnt)
{
	return KERN_NOT_SUPPORTED;
}

kern_return_t
task_get_exc_guard_behavior(
	task_t task,
	task_exc_guard_behavior_t *behaviorp)
{
	if (task == TASK_NULL) {
		return KERN_INVALID_TASK;
	}
	*behaviorp = task->task_exc_guard;
	return KERN_SUCCESS;
}

/* Placeholders for the task set/get voucher interfaces */
kern_return_t
task_get_mach_voucher(
	task_t                  task,
	mach_voucher_selector_t __unused which,
	ipc_voucher_t           *voucher)
{
	if (TASK_NULL == task) {
		return KERN_INVALID_TASK;
	}

	*voucher = NULL;
	return KERN_SUCCESS;
}

kern_return_t
task_set_mach_voucher(
	task_t                  task,
	ipc_voucher_t           __unused voucher)
{
	if (TASK_NULL == task) {
		return KERN_INVALID_TASK;
	}

	return KERN_SUCCESS;
}

kern_return_t
task_swap_mach_voucher(
	__unused task_t         task,
	__unused ipc_voucher_t  new_voucher,
	ipc_voucher_t          *in_out_old_voucher)
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

/*
 *	task_inspect_deallocate:
 *
 *	Drop a task inspection reference.
 */
void
task_inspect_deallocate(
	task_inspect_t          task_inspect)
{
	return task_deallocate((task_t)task_inspect);
}

kern_return_t
task_register_dyld_set_dyld_state(__unused task_t task,
    __unused uint8_t dyld_state)
{
	return KERN_NOT_SUPPORTED;
}

kern_return_t
task_register_dyld_get_process_state(__unused task_t task,
    __unused dyld_kernel_process_info_t * dyld_process_state)
{
	return KERN_NOT_SUPPORTED;
}

/*
 *	task_set_policy
 *
 *	Set scheduling policy and parameters, both base and limit, for
 *	the given task. Policy can be any policy implemented by the
 *	processor set, whether enabled or not. Change contained threads
 *	if requested.
 */
kern_return_t
task_set_policy(
	__unused task_t                 task,
	__unused processor_set_t                pset,
	__unused policy_t                       policy_id,
	__unused policy_base_t          base,
	__unused mach_msg_type_number_t base_count,
	__unused policy_limit_t         limit,
	__unused mach_msg_type_number_t limit_count,
	__unused boolean_t                      change)
{
	return KERN_FAILURE;
}

kern_return_t
task_set_ras_pc(
	__unused task_t task,
	__unused vm_offset_t    pc,
	__unused vm_offset_t    endpc)
{
	return KERN_FAILURE;
}

/*
 * This routine finds a thread in a task by its unique id
 * Returns a referenced thread or THREAD_NULL if the thread was not found
 *
 * TODO: This is super inefficient - it's an O(threads in task) list walk!
 *       We should make a tid hash, or transition all tid clients to thread ports
 *
 * Precondition: No locks held (will take task lock)
 */
thread_t
task_findtid(task_t task, uint64_t tid)
{
	thread_t self           = current_thread();
	thread_t found_thread   = THREAD_NULL;
	thread_t iter_thread    = THREAD_NULL;

	/* Short-circuit the lookup if we're looking up ourselves */
	if (tid == self->thread_id || tid == TID_NULL) {
		assert(self->task == task);

		thread_reference(self);

		return self;
	}

	task_lock(task);

	queue_iterate(&task->threads, iter_thread, thread_t, task_threads) {
		if (iter_thread->thread_id == tid) {
			found_thread = iter_thread;
			thread_reference(found_thread);
			break;
		}
	}

	task_unlock(task);

	return found_thread;
}

/*
 * task_info_from_user
 *
 * When calling task_info from user space,
 * this function will be executed as mig server side
 * instead of calling directly into task_info.
 * This gives the possibility to perform more security
 * checks on task_port.
 *
 * In the case of TASK_DYLD_INFO, we require the more
 * privileged task_read_port not the less-privileged task_name_port.
 *
 */
kern_return_t
task_info_from_user(
	mach_port_t             task_port,
	task_flavor_t           flavor,
	task_info_t             task_info_out,
	mach_msg_type_number_t  *task_info_count)
{
	task_t task;
	kern_return_t ret;

	if (flavor == TASK_DYLD_INFO) {
		task = convert_port_to_task_read(task_port);
	} else {
		task = convert_port_to_task_name(task_port);
	}

	ret = task_info(task, flavor, task_info_out, task_info_count);

	task_deallocate(task);

	return ret;
}

static kern_return_t
task_threads_internal(
	task_t                      task,
	thread_act_array_t         *threads_out,
	mach_msg_type_number_t     *count,
	mach_thread_flavor_t        flavor)
{
	mach_msg_type_number_t  actual;
	thread_t                                *thread_list;
	thread_t                                thread;
	vm_size_t                               size, size_needed;
	void                                    *addr;
	unsigned int                    i, j;

	size = 0; addr = NULL;

	if (task == TASK_NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	assert(flavor <= THREAD_FLAVOR_INSPECT);

	for (;;) {
		task_lock(task);
		if (!task->active) {
			task_unlock(task);

			if (size != 0) {
				kfree(addr, size);
			}

			return KERN_FAILURE;
		}

		actual = task->thread_count;

		/* do we have the memory we need? */
		size_needed = actual * sizeof(mach_port_t);
		if (size_needed <= size) {
			break;
		}

		/* unlock the task and allocate more memory */
		task_unlock(task);

		if (size != 0) {
			kfree(addr, size);
		}

		assert(size_needed > 0);
		size = size_needed;

		addr = kalloc(size);
		if (addr == 0) {
			return KERN_RESOURCE_SHORTAGE;
		}
	}

	/* OK, have memory and the task is locked & active */
	thread_list = (thread_t *)addr;

	i = j = 0;

	for (thread = (thread_t)queue_first(&task->threads); i < actual;
	    ++i, thread = (thread_t)queue_next(&thread->task_threads)) {
		thread_reference_internal(thread);
		thread_list[j++] = thread;
	}

	assert(queue_end(&task->threads, (queue_entry_t)thread));

	actual = j;
	size_needed = actual * sizeof(mach_port_t);

	/* can unlock task now that we've got the thread refs */
	task_unlock(task);

	if (actual == 0) {
		/* no threads, so return null pointer and deallocate memory */

		*threads_out = NULL;
		*count = 0;

		if (size != 0) {
			kfree(addr, size);
		}
	} else {
		/* if we allocated too much, must copy */

		if (size_needed < size) {
			void *newaddr;

			newaddr = kalloc(size_needed);
			if (newaddr == 0) {
				for (i = 0; i < actual; ++i) {
					thread_deallocate(thread_list[i]);
				}
				kfree(addr, size);
				return KERN_RESOURCE_SHORTAGE;
			}

			bcopy(addr, newaddr, size_needed);
			kfree(addr, size);
			thread_list = (thread_t *)newaddr;
		}

		*threads_out = thread_list;
		*count = actual;

		/* do the conversion that Mig should handle */

		switch (flavor) {
		case THREAD_FLAVOR_CONTROL:
			if (task == current_task()) {
				for (i = 0; i < actual; ++i) {
					((ipc_port_t *) thread_list)[i] = convert_thread_to_port_pinned(thread_list[i]);
				}
			} else {
				for (i = 0; i < actual; ++i) {
					((ipc_port_t *) thread_list)[i] = convert_thread_to_port(thread_list[i]);
				}
			}
			break;
		case THREAD_FLAVOR_READ:
			for (i = 0; i < actual; ++i) {
				((ipc_port_t *) thread_list)[i] = convert_thread_read_to_port(thread_list[i]);
			}
			break;
		case THREAD_FLAVOR_INSPECT:
			for (i = 0; i < actual; ++i) {
				((ipc_port_t *) thread_list)[i] = convert_thread_inspect_to_port(thread_list[i]);
			}
			break;
		}
	}

	return KERN_SUCCESS;
}

kern_return_t
task_threads_from_user(
	mach_port_t                 port,
	thread_act_array_t         *threads_out,
	mach_msg_type_number_t     *count)
{
	ipc_kobject_type_t kotype;
	kern_return_t kr;

	task_t task = convert_port_to_task_check_type(port, &kotype, TASK_FLAVOR_INSPECT, FALSE);

	if (task == TASK_NULL) {
		return KERN_INVALID_ARGUMENT;
	}

	switch (kotype) {
	case IKOT_TASK_CONTROL:
		kr = task_threads_internal(task, threads_out, count, THREAD_FLAVOR_CONTROL);
		break;
	case IKOT_TASK_READ:
		kr = task_threads_internal(task, threads_out, count, THREAD_FLAVOR_READ);
		break;
	case IKOT_TASK_INSPECT:
		kr = task_threads_internal(task, threads_out, count, THREAD_FLAVOR_INSPECT);
		break;
	default:
		panic("strange kobject type");
		break;
	}

	task_deallocate(task);
	return kr;
}

/*
 *	task_release_locked:
 *
 *	Release a kernel hold on a task.
 *
 *      CONDITIONS: the task is locked and active
 */
void
task_release_locked(
	task_t          task)
{
	thread_t        thread;

	assert(task->active);
	assert(task->suspend_count > 0);

	if (--task->suspend_count > 0) {
		return;
	}

#ifndef __DARLING__
	if (task->bsd_info) {
		workq_proc_resumed(task->bsd_info);
	}
#endif // __DARLING__

	queue_iterate(&task->threads, thread, thread_t, task_threads) {
		thread_mtx_lock(thread);
		thread_release(thread);
		thread_mtx_unlock(thread);
	}
}

/*
 *	task_hold_locked:
 *
 *	Suspend execution of the specified task.
 *	This is a recursive-style suspension of the task, a count of
 *	suspends is maintained.
 *
 *	CONDITIONS: the task is locked and active.
 */
void
task_hold_locked(
	task_t          task)
{
	thread_t        thread;

	assert(task->active);

	if (task->suspend_count++ > 0) {
		return;
	}

#ifndef __DARLING__
	if (task->bsd_info) {
		workq_proc_suspended(task->bsd_info);
	}
#endif // __DARLING__

	/*
	 *	Iterate through all the threads and hold them.
	 */
	queue_iterate(&task->threads, thread, thread_t, task_threads) {
		thread_mtx_lock(thread);
		thread_hold(thread);
		thread_mtx_unlock(thread);
	}
}

#define TASK_HOLD_NORMAL        0
#define TASK_HOLD_PIDSUSPEND    1
#define TASK_HOLD_LEGACY        2
#define TASK_HOLD_LEGACY_ALL    3

static kern_return_t
place_task_hold(
	task_t task,
	int mode)
{
	if (!task->active && !task_is_a_corpse(task)) {
		return KERN_FAILURE;
	}

	/* Return success for corpse task */
	if (task_is_a_corpse(task)) {
		return KERN_SUCCESS;
	}

	KDBG_RELEASE(MACHDBG_CODE(DBG_MACH_IPC, MACH_TASK_SUSPEND),
	    task_pid(task),
	    task->thread_count > 0 ?((thread_t)queue_first(&task->threads))->thread_id : 0,
	    task->user_stop_count, task->user_stop_count + 1);

#if MACH_ASSERT
	current_task()->suspends_outstanding++;
#endif

	if (mode == TASK_HOLD_LEGACY) {
		task->legacy_stop_count++;
	}

	if (task->user_stop_count++ > 0) {
		/*
		 *	If the stop count was positive, the task is
		 *	already stopped and we can exit.
		 */
		return KERN_SUCCESS;
	}

	/*
	 * Put a kernel-level hold on the threads in the task (all
	 * user-level task suspensions added together represent a
	 * single kernel-level hold).  We then wait for the threads
	 * to stop executing user code.
	 */
	task_hold_locked(task);
	task_wait_locked(task, FALSE);

	return KERN_SUCCESS;
}

static kern_return_t
release_task_hold(
	task_t          task,
	int                     mode)
{
	boolean_t release = FALSE;

	if (!task->active && !task_is_a_corpse(task)) {
		return KERN_FAILURE;
	}

	/* Return success for corpse task */
	if (task_is_a_corpse(task)) {
		return KERN_SUCCESS;
	}

	if (mode == TASK_HOLD_PIDSUSPEND) {
		if (task->pidsuspended == FALSE) {
			return KERN_FAILURE;
		}
		task->pidsuspended = FALSE;
	}

	if (task->user_stop_count > (task->pidsuspended ? 1 : 0)) {
		KERNEL_DEBUG_CONSTANT_IST(KDEBUG_TRACE,
		    MACHDBG_CODE(DBG_MACH_IPC, MACH_TASK_RESUME) | DBG_FUNC_NONE,
		    task_pid(task), ((thread_t)queue_first(&task->threads))->thread_id,
		    task->user_stop_count, mode, task->legacy_stop_count);

#if MACH_ASSERT
		/*
		 * This is obviously not robust; if we suspend one task and then resume a different one,
		 * we'll fly under the radar. This is only meant to catch the common case of a crashed
		 * or buggy suspender.
		 */
		current_task()->suspends_outstanding--;
#endif

		if (mode == TASK_HOLD_LEGACY_ALL) {
			if (task->legacy_stop_count >= task->user_stop_count) {
				task->user_stop_count = 0;
				release = TRUE;
			} else {
				task->user_stop_count -= task->legacy_stop_count;
			}
			task->legacy_stop_count = 0;
		} else {
			if (mode == TASK_HOLD_LEGACY && task->legacy_stop_count > 0) {
				task->legacy_stop_count--;
			}
			if (--task->user_stop_count == 0) {
				release = TRUE;
			}
		}
	} else {
		return KERN_FAILURE;
	}

	/*
	 *	Release the task if necessary.
	 */
	if (release) {
		task_release_locked(task);
	}

	return KERN_SUCCESS;
}

/*
 *	task_suspend:
 *
 *	Implement an (old-fashioned) user-level suspension on a task.
 *
 *	Because the user isn't expecting to have to manage a suspension
 *	token, we'll track it for him in the kernel in the form of a naked
 *	send right to the task's resume port.  All such send rights
 *	account for a single suspension against the task (unlike task_suspend2()
 *	where each caller gets a unique suspension count represented by a
 *	unique send-once right).
 *
 * Conditions:
 *      The caller holds a reference to the task
 */
kern_return_t
task_suspend(
	task_t          task)
{
	kern_return_t                   kr;
	mach_port_t                     port;
	mach_port_name_t                name;

	if (task == TASK_NULL || task == kernel_task) {
		return KERN_INVALID_ARGUMENT;
	}

	task_lock(task);

	/*
	 * place a legacy hold on the task.
	 */
	kr = place_task_hold(task, TASK_HOLD_LEGACY);
	if (kr != KERN_SUCCESS) {
		task_unlock(task);
		return kr;
	}

	/*
	 * Claim a send right on the task resume port, and request a no-senders
	 * notification on that port (if none outstanding).
	 */
	(void)ipc_kobject_make_send_lazy_alloc_port((ipc_port_t *) &task->itk_resume,
	    (ipc_kobject_t)task, IKOT_TASK_RESUME, IPC_KOBJECT_ALLOC_NONE, true,
	    OS_PTRAUTH_DISCRIMINATOR("task.itk_resume"));
	port = task->itk_resume;
	task_unlock(task);

	/*
	 * Copyout the send right into the calling task's IPC space.  It won't know it is there,
	 * but we'll look it up when calling a traditional resume.  Any IPC operations that
	 * deallocate the send right will auto-release the suspension.
	 */
	if (IP_VALID(port)) {
		kr = ipc_object_copyout(current_space(), ip_to_object(port),
		    MACH_MSG_TYPE_MOVE_SEND, IPC_OBJECT_COPYOUT_FLAGS_NONE,
		    NULL, NULL, &name);
	} else {
		kr = KERN_SUCCESS;
	}
	if (kr != KERN_SUCCESS) {
#ifndef __DARLING__
		printf("warning: %s(%d) failed to copyout suspension "
		    "token for pid %d with error: %d\n",
		    proc_name_address(current_task()->bsd_info),
		    proc_pid(current_task()->bsd_info),
		    task_pid(task), kr);
#endif // __DARLING__
	}

	return kr;
}

/*
 *	task_resume:
 *		Release a user hold on a task.
 *
 * Conditions:
 *		The caller holds a reference to the task
 */
kern_return_t
task_resume(
	task_t  task)
{
	kern_return_t    kr;
	mach_port_name_t resume_port_name;
	ipc_entry_t              resume_port_entry;
	ipc_space_t              space = current_task()->itk_space;

	if (task == TASK_NULL || task == kernel_task) {
		return KERN_INVALID_ARGUMENT;
	}

	/* release a legacy task hold */
	task_lock(task);
	kr = release_task_hold(task, TASK_HOLD_LEGACY);
	task_unlock(task);

	is_write_lock(space);
	if (is_active(space) && IP_VALID(task->itk_resume) &&
	    ipc_hash_lookup(space, ip_to_object(task->itk_resume), &resume_port_name, &resume_port_entry) == TRUE) {
		/*
		 * We found a suspension token in the caller's IPC space. Release a send right to indicate that
		 * we are holding one less legacy hold on the task from this caller.  If the release failed,
		 * go ahead and drop all the rights, as someone either already released our holds or the task
		 * is gone.
		 */
		if (kr == KERN_SUCCESS) {
			ipc_right_dealloc(space, resume_port_name, resume_port_entry);
		} else {
			ipc_right_destroy(space, resume_port_name, resume_port_entry, FALSE, 0);
		}
		/* space unlocked */
	} else {
		is_write_unlock(space);
		if (kr == KERN_SUCCESS) {
#ifndef __DARLING__
			printf("warning: %s(%d) performed out-of-band resume on pid %d\n",
			    proc_name_address(current_task()->bsd_info), proc_pid(current_task()->bsd_info),
			    task_pid(task));
#endif // __DARLING__
		}
	}

	return kr;
}

/*
 * Suspend the target task.
 * Making/holding a token/reference/port is the callers responsibility.
 */
kern_return_t
task_suspend_internal(task_t task)
{
	kern_return_t    kr;

	if (task == TASK_NULL || task == kernel_task) {
		return KERN_INVALID_ARGUMENT;
	}

	task_lock(task);
	kr = place_task_hold(task, TASK_HOLD_NORMAL);
	task_unlock(task);
	return kr;
}

/*
 * Suspend the target task, and return a suspension token. The token
 * represents a reference on the suspended task.
 */
kern_return_t
task_suspend2(
	task_t                  task,
	task_suspension_token_t *suspend_token)
{
	kern_return_t    kr;

	kr = task_suspend_internal(task);
	if (kr != KERN_SUCCESS) {
		*suspend_token = TASK_NULL;
		return kr;
	}

	/*
	 * Take a reference on the target task and return that to the caller
	 * as a "suspension token," which can be converted into an SO right to
	 * the now-suspended task's resume port.
	 */
	task_reference_internal(task);
	*suspend_token = task;

	return KERN_SUCCESS;
}

/*
 * Resume the task
 * (reference/token/port management is caller's responsibility).
 */
kern_return_t
task_resume_internal(
	task_suspension_token_t         task)
{
	kern_return_t kr;

	if (task == TASK_NULL || task == kernel_task) {
		return KERN_INVALID_ARGUMENT;
	}

	task_lock(task);
	kr = release_task_hold(task, TASK_HOLD_NORMAL);
	task_unlock(task);
	return kr;
}

/*
 * Resume the task using a suspension token. Consumes the token's ref.
 */
kern_return_t
task_resume2(
	task_suspension_token_t         task)
{
	kern_return_t kr;

	kr = task_resume_internal(task);
	task_suspension_token_deallocate(task);

	return kr;
}

/*
 *	task_read_deallocate:
 *
 *	Drop a reference on task read port.
 */
void
task_read_deallocate(
	task_read_t          task_read)
{
	return task_deallocate((task_t)task_read);
}

// </copied>

// <copied from="xnu://7195.141.2/osfmk/kern/zalloc.c">

kern_return_t
task_zone_info(
	__unused task_t                                 task,
	__unused mach_zone_name_array_t *namesp,
	__unused mach_msg_type_number_t *namesCntp,
	__unused task_zone_info_array_t *infop,
	__unused mach_msg_type_number_t *infoCntp)
{
	return KERN_FAILURE;
}

// </copied>
