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

task_t kernel_task = NULL;

void dtape_task_init(void) {
	// this will assign to kernel_task
	dserver_rpc_architecture_t arch = dserver_rpc_architecture_invalid;

#if __x86_64__
	arch = dserver_rpc_architecture_x86_64;
#elif __i386__
	arch = dserver_rpc_architecture_i386;
#elif __aarch64__
	arch = dserver_rpc_architecture_arm64;
#elif __arm__
	arch = dserver_rpc_architecture_arm32;
#else
	#error Unknown architecture
#endif

	if (!dtape_task_create(NULL, 0, NULL, arch)) {
		panic("Failed to create kernel task");
	}
};

dtape_task_t* dtape_task_create(dtape_task_t* parent_task, uint32_t nsid, void* context, dserver_rpc_architecture_t architecture) {
	if (parent_task == NULL && nsid == 0 && kernel_task) {
		dtape_task_t* task = dtape_task_for_xnu_task(kernel_task);

		// don't acquire an additional reference;
		// the managing Task instance acquires ownership of the kernel task
		//task_reference(kernel_task);

		if (task->context) {
			panic("The kernel task already has a context");
		} else {
			task->context = context;
		}
		return task;
	}

	dtape_task_t* task = malloc(sizeof(dtape_task_t));
	if (!task) {
		return NULL;
	}

	task->context = context;
	task->saved_pid = nsid;
	task->architecture = architecture;
	task->has_sigexc = false;
	task->dyld_info_addr = 0;
	task->dyld_info_length = 0;
	task->p_ident.eid = dtape_hooks->task_eternal_id(context);
	dtape_mutex_init(&task->dyld_info_lock);
	dtape_condvar_init(&task->dyld_info_condvar);
	memset(&task->xnu_task, 0, sizeof(task->xnu_task));

	// this next section uses code adapted from XNU's task_create_internal() in osfmk/kern/task.c

	os_ref_init(&task->xnu_task.ref_count, NULL);

	lck_mtx_init(&task->xnu_task.lock, LCK_GRP_NULL, LCK_ATTR_NULL);
	queue_init(&task->xnu_task.threads);

	task->xnu_task.active = true;

	task->xnu_task.map = dtape_vm_map_create(task);

	queue_init(&task->xnu_task.semaphore_list);

#ifdef __DARLING__
	/*
	 * Task #47: a task created with NO parent takes ipc_task_init's parent==TASK_NULL
	 * branch, which sets itk_bootstrap = IP_NULL. It can then never inherit launchd's
	 * bootstrap port, and its first service lookup goes to MACH_PORT_NULL.
	 */
	dtape_log_debug("dtape_task_create: nsid=%u parent=%p parent_bootstrap=%p", nsid,
	    parent_task, parent_task ? parent_task->xnu_task.itk_bootstrap : NULL);
#endif
	ipc_task_init(&task->xnu_task, parent_task ? &parent_task->xnu_task : NULL);

	if (parent_task) {
		task_importance_init_from_parent(&task->xnu_task, &parent_task->xnu_task);
	}

	// this is a hack to force all tasks to have an IPC importance structure associated with them
	// since i'm not sure where it's normally acquired in XNU.
	// (this is necessary ipc_importance_send() needs the task to have a valid `task_imp_base`)
	if (task->xnu_task.task_imp_base == IIT_NULL) {
		ipc_importance_task_t imp = ipc_importance_for_task(&task->xnu_task, false);
		// the new IPC importance structure has 2 references:
		//   * one that the task gets,
		//   * and another one that we (the caller) get
		// we don't actually want a reference; we only want the task to have one.
		ipc_importance_task_release(imp);
	}

	if (parent_task != NULL) {
		task->xnu_task.sec_token = parent_task->xnu_task.sec_token;
		task->xnu_task.audit_token = parent_task->xnu_task.audit_token;
	} else {
		task->xnu_task.sec_token = KERNEL_SECURITY_TOKEN;
		task->xnu_task.audit_token = KERNEL_AUDIT_TOKEN;
	}

	task->xnu_task.audit_token.val[5] = task->saved_pid;

	if (architecture == dserver_rpc_architecture_x86_64 || architecture == dserver_rpc_architecture_arm64) {
		task_set_64Bit_addr(&task->xnu_task);
		task_set_64Bit_data(&task->xnu_task);
	}

	ipc_task_enable(&task->xnu_task);

	dtape_psynch_task_init(task);

	if (parent_task == NULL && nsid == 0) {
		if (kernel_task) {
			panic("Another kernel task has been created");
		}

		kernel_task = &task->xnu_task;
	}

	return task;
};

void dtape_task_destroy(dtape_task_t* task) {
	dtape_log_debug("%d: task being destroyed", task->saved_pid);

	dtape_psynch_task_destroy(task);

	// this next section uses code adapted from XNU's task_deallocate() in osfmk/kern/task.c

	task_lock(&task->xnu_task);
	task->xnu_task.active = false;
	ipc_task_disable(&task->xnu_task);
	task_unlock(&task->xnu_task);

	semaphore_destroy_all(&task->xnu_task);

	ipc_space_terminate(task->xnu_task.itk_space);

	ipc_task_terminate(&task->xnu_task);

	dtape_vm_map_destroy(task->xnu_task.map);

	is_release(task->xnu_task.itk_space);

	lck_mtx_destroy(&task->xnu_task.lock, LCK_GRP_NULL);

	dtape_hooks->task_context_dispose(task->context);

	free(task);
};

void dtape_task_uidgid(dtape_task_t* task, int new_uid, int new_gid, int* old_uid, int* old_gid) {
	task_lock(&task->xnu_task);
	if (old_uid) {
		*old_uid = task->xnu_task.audit_token.val[1];
	}
	if (old_gid) {
		*old_gid = task->xnu_task.audit_token.val[2];
	}
	if (new_uid >= 0) {
		task->xnu_task.audit_token.val[1] = new_uid;
	}
	if (new_gid >= 0) {
		task->xnu_task.audit_token.val[2] = new_gid;
	}
	task_unlock(&task->xnu_task);
};

void dtape_task_retain(dtape_task_t* task) {
	task_reference(&task->xnu_task);
};

void dtape_task_release(dtape_task_t* task) {
	task_deallocate(&task->xnu_task);
};

void dtape_task_dying(dtape_task_t* task) {
	// nothing for now
};

void dtape_task_set_dyld_info(dtape_task_t* task, uint64_t address, uint64_t length) {
	dtape_mutex_lock(&task->dyld_info_lock);
	dtape_log_debug("setting dyld info to %llu bytes at %llx", length, address);
	task->dyld_info_addr = address;
	task->dyld_info_length = length;
	dtape_mutex_unlock(&task->dyld_info_lock);
	dtape_condvar_signal(&task->dyld_info_condvar, SIZE_MAX);
};

void dtape_task_set_sigexc_enabled(dtape_task_t* task, bool enabled) {
	// FIXME: we should probably have a lock for this
	task->has_sigexc = enabled;
};

bool dtape_task_try_resume(dtape_task_t* task) {
	if (task->xnu_task.user_stop_count) {
		dtape_log_debug("sigexc target task is stopped (%d), resuming", task->xnu_task.user_stop_count);
		return task_resume(&task->xnu_task) == KERN_SUCCESS;
	}
	return false;
};

void task_deallocate(task_t xtask) {
	dtape_task_t* task = dtape_task_for_xnu_task(xtask);
	os_ref_count_t count = os_ref_release(&xtask->ref_count);
	if (count > 0) {
		// IPC importance info might be holding the last reference on the task
		if (count == 1) {
			if (IIT_NULL != task->xnu_task.task_imp_base) {
				ipc_importance_disconnect_task(&task->xnu_task);
			}
		}
		return;
	}
	dtape_task_destroy(task);
};

int pid_from_task(task_t xtask) {
	dtape_task_t* task = dtape_task_for_xnu_task(xtask);
	return task->saved_pid;
};

int proc_get_effective_task_policy(task_t task, int flavor) {
	dtape_stub();
	if (flavor == TASK_POLICY_ROLE) {
		return TASK_UNSPECIFIED;
	} else {
		panic("Unimplemented proc_get_effective_task_policy flavor: %d", flavor);
	}
};

int task_pid(task_t task) {
	return pid_from_task(task);
};

void task_policy_update_complete_unlocked(task_t task, task_pend_token_t pend_token) {
	dtape_stub();
};

void task_port_notify(mach_msg_header_t* msg) {
	dtape_stub();
};

void task_port_with_flavor_notify(mach_msg_header_t* msg) {
	dtape_stub();
};

boolean_t task_suspension_notify(mach_msg_header_t* request_header) {
	dtape_stub();
	return FALSE;
};

void task_update_boost_locked(task_t task, boolean_t boost_active, task_pend_token_t pend_token) {
	dtape_stub();
};

void task_watchport_elem_deallocate(struct task_watchport_elem* watchport_elem) {
	dtape_stub();
};

kern_return_t task_create_suid_cred(task_t task, suid_cred_path_t path, suid_cred_uid_t uid, suid_cred_t* sc_p) {
	dtape_stub_unsafe();
};

kern_return_t task_dyld_process_info_notify_deregister(task_t task, mach_port_name_t rcv_name) {
	dtape_stub_unsafe();
};

kern_return_t task_dyld_process_info_notify_register(task_t task, ipc_port_t sright) {
	dtape_stub_unsafe();
};

kern_return_t task_generate_corpse(task_t task, ipc_port_t* corpse_task_port) {
	dtape_stub_unsafe();
};

kern_return_t task_get_assignment(task_t task, processor_set_t* pset) {
	dtape_stub_unsafe();
};

kern_return_t task_get_state(task_t  task, int flavor, thread_state_t state, mach_msg_type_number_t* state_count) {
	dtape_stub_unsafe();
};

kern_return_t task_info(task_t xtask, task_flavor_t flavor, task_info_t task_info_out, mach_msg_type_number_t* task_info_count) {
	dtape_task_t* task = dtape_task_for_xnu_task(xtask);

	switch (flavor) {
		case TASK_BASIC_INFO_32:
		case TASK_BASIC_INFO_64:
		case MACH_TASK_BASIC_INFO: {
			uint64_t utimeus;
			uint64_t stimeus;
			dtape_memory_info_t mem_info;

			dtape_hooks->task_get_memory_info(task->context, &mem_info);

			dtape_log_debug("%s: TODO: fetch utimeus and stimeus somehow", __FUNCTION__);
			utimeus = 0;
			stimeus = 0;

			if (flavor == TASK_BASIC_INFO_32) {
				struct task_basic_info_32* info = (void*)task_info_out;

				if (*task_info_count < TASK_BASIC_INFO_32_COUNT) {
					return KERN_INVALID_ARGUMENT;
				}

				*task_info_count = TASK_BASIC_INFO_32_COUNT;

				info->suspend_count = task->xnu_task.user_stop_count;
				info->virtual_size = mem_info.virtual_size;
				info->resident_size = mem_info.resident_size;
				info->user_time.seconds = utimeus / USEC_PER_SEC;
				info->user_time.microseconds = utimeus % USEC_PER_SEC;
				info->system_time.seconds = stimeus / USEC_PER_SEC;
				info->system_time.microseconds = stimeus % USEC_PER_SEC;
				info->policy = 0;
			} else if (flavor == TASK_BASIC_INFO_64) {
				struct task_basic_info_64* info = (void*)task_info_out;

				if (*task_info_count < TASK_BASIC_INFO_64_COUNT) {
					return KERN_INVALID_ARGUMENT;
				}

				*task_info_count = TASK_BASIC_INFO_64_COUNT;

				info->suspend_count = task->xnu_task.user_stop_count;
				info->virtual_size = mem_info.virtual_size;
				info->resident_size = mem_info.resident_size;
				info->user_time.seconds = utimeus / USEC_PER_SEC;
				info->user_time.microseconds = utimeus % USEC_PER_SEC;
				info->system_time.seconds = stimeus / USEC_PER_SEC;
				info->system_time.microseconds = stimeus % USEC_PER_SEC;
				info->policy = 0;
			} else {
				struct mach_task_basic_info* info = (void*)task_info_out;

				if (*task_info_count < MACH_TASK_BASIC_INFO_COUNT) {
					return KERN_INVALID_ARGUMENT;
				}

				*task_info_count = MACH_TASK_BASIC_INFO_COUNT;

				info->suspend_count = task->xnu_task.user_stop_count;
				info->virtual_size = mem_info.virtual_size;
				info->resident_size = mem_info.resident_size;
				info->user_time.seconds = utimeus / USEC_PER_SEC;
				info->user_time.microseconds = utimeus % USEC_PER_SEC;
				info->system_time.seconds = stimeus / USEC_PER_SEC;
				info->system_time.microseconds = stimeus % USEC_PER_SEC;
				info->policy = 0;
			}

			return KERN_SUCCESS;
		};

		case TASK_THREAD_TIMES_INFO: {
			task_thread_times_info_data_t* info = (task_thread_times_info_data_t*)task_info_out;

			if (*task_info_count < TASK_THREAD_TIMES_INFO_COUNT) {
				return KERN_INVALID_ARGUMENT;
			}
			*task_info_count = TASK_THREAD_TIMES_INFO_COUNT;

			dtape_log_debug("%s: TODO: fetch utimeus and stimeus somehow", __FUNCTION__);
			uint64_t utimeus = 0;
			uint64_t stimeus = 0;

			info->user_time.seconds = utimeus / USEC_PER_SEC;
			info->user_time.microseconds = utimeus % USEC_PER_SEC;
			info->system_time.seconds = stimeus / USEC_PER_SEC;
			info->system_time.microseconds = stimeus % USEC_PER_SEC;

			return KERN_SUCCESS;
		};

		case TASK_DYLD_INFO: {
			task_dyld_info_t info = (task_dyld_info_t)task_info_out;

			/*
			* We added the format field to TASK_DYLD_INFO output.  For
			* temporary backward compatibility, accept the fact that
			* clients may ask for the old version - distinquished by the
			* size of the expected result structure.
			*/
#define TASK_LEGACY_DYLD_INFO_COUNT \
			offsetof(struct task_dyld_info, all_image_info_format)/sizeof(natural_t)

			if (*task_info_count < TASK_LEGACY_DYLD_INFO_COUNT) {
				return KERN_INVALID_ARGUMENT;
			}

			// DARLING:
			// This call may block, waiting for Darling to provide this information
			// shortly after startup.

			dtape_log_debug("going to read dyld info for task %p (%d)", task, task->saved_pid);

			dtape_mutex_lock(&task->dyld_info_lock);

			while (task->dyld_info_addr == 0 && task->dyld_info_length == 0) {
				dtape_log_debug("going to wait for dyld info for task %p (%d)", task, task->saved_pid);
				dtape_condvar_wait(&task->dyld_info_condvar, &task->dyld_info_lock);
				dtape_log_debug("awoken from dyld info wait for task %p (%d)", task, task->saved_pid);
			}

			info->all_image_info_addr = task->dyld_info_addr;
			info->all_image_info_size = task->dyld_info_length;

			dtape_mutex_unlock(&task->dyld_info_lock);

			dtape_log_debug("got dyld info for task %p (%d): %llu bytes at %llx", task, task->saved_pid, info->all_image_info_addr, info->all_image_info_size);

			/* only set format on output for those expecting it */
			if (*task_info_count >= TASK_DYLD_INFO_COUNT) {
				info->all_image_info_format = task_has_64Bit_addr(xtask) ? TASK_DYLD_ALL_IMAGE_INFO_64 : TASK_DYLD_ALL_IMAGE_INFO_32 ;
				*task_info_count = TASK_DYLD_INFO_COUNT;
			} else {
				*task_info_count = TASK_LEGACY_DYLD_INFO_COUNT;
			}

			return KERN_SUCCESS;
		};

		case TASK_AUDIT_TOKEN: {
			audit_token_t   *audit_token_p;

			if (*task_info_count < TASK_AUDIT_TOKEN_COUNT) {
				return KERN_INVALID_ARGUMENT;
			}

			audit_token_p = (audit_token_t *) task_info_out;
			*audit_token_p = task->xnu_task.audit_token;
			*task_info_count = TASK_AUDIT_TOKEN_COUNT;

			return KERN_SUCCESS;
		};

		case TASK_VM_INFO: {
			task_vm_info_t info = (task_vm_info_t)task_info_out;
			mach_msg_type_number_t orig_info_count = *task_info_count;

			if (orig_info_count < TASK_VM_INFO_REV0_COUNT) {
				return KERN_INVALID_ARGUMENT;
			}

			memset(info, 0, orig_info_count * sizeof(natural_t));

			dtape_memory_info_t meminfo;
			dtape_hooks->task_get_memory_info(task->context, &meminfo);

			info->page_size = meminfo.page_size;
			info->resident_size = meminfo.resident_size;
			info->resident_size_peak = meminfo.resident_size;
			info->virtual_size = meminfo.virtual_size;

			// TODO: fill in other stuff

			*task_info_count = TASK_VM_INFO_REV0_COUNT;

			if (orig_info_count >= TASK_VM_INFO_REV1_COUNT) {

				*task_info_count = TASK_VM_INFO_REV1_COUNT;

				if (orig_info_count >= TASK_VM_INFO_REV2_COUNT) {

					*task_info_count = TASK_VM_INFO_REV2_COUNT;

					if (orig_info_count >= TASK_VM_INFO_REV3_COUNT) {

						*task_info_count = TASK_VM_INFO_REV3_COUNT;

						if (orig_info_count >= TASK_VM_INFO_REV4_COUNT) {

							*task_info_count = TASK_VM_INFO_REV4_COUNT;

							if (orig_info_count >= TASK_VM_INFO_REV5_COUNT) {
								*task_info_count = TASK_VM_INFO_REV5_COUNT;
							}
						}
					}
				}
			}

			return KERN_SUCCESS;
		};

		case TASK_FLAGS_INFO: {
			task_flags_info_t info = (task_flags_info_t)task_info_out;
			mach_msg_type_number_t orig_info_count = *task_info_count;

			if (orig_info_count < TASK_FLAGS_INFO_COUNT) {
				return KERN_INVALID_ARGUMENT;
			}

			info->flags = 0;

			if (task->architecture == dserver_rpc_architecture_x86_64 || task->architecture == dserver_rpc_architecture_arm64) {
				info->flags = TF_LP64 | TF_64B_DATA;
			}

			return KERN_SUCCESS;
		};

		default:
			dtape_stub_unsafe("unimplemented flavor");
	}
};

kern_return_t task_inspect(task_inspect_t task_insp, task_inspect_flavor_t flavor, task_inspect_info_t info_out, mach_msg_type_number_t* size_in_out) {
	dtape_stub_safe();
	return KERN_FAILURE;
};

bool task_is_driver(task_t task) {
	dtape_stub_safe();
	return false;
};

kern_return_t task_map_corpse_info(task_t task, task_t corpse_task, vm_address_t* kcd_addr_begin, uint32_t* kcd_size) {
	dtape_stub_unsafe();
};

kern_return_t task_map_corpse_info_64(task_t task, task_t corpse_task, mach_vm_address_t* kcd_addr_begin, mach_vm_size_t* kcd_size) {
	dtape_stub_unsafe();
};

void task_name_deallocate(task_name_t task_name) {
	dtape_stub_unsafe();
};

kern_return_t task_policy_get(task_t task, task_policy_flavor_t flavor, task_policy_t policy_info, mach_msg_type_number_t* count, boolean_t* get_default) {
	dtape_stub_unsafe();
};

void task_policy_get_deallocate(task_policy_get_t task_policy_get) {
	dtape_stub_unsafe();
};

kern_return_t task_policy_set(task_t task, task_policy_flavor_t flavor, task_policy_t policy_info, mach_msg_type_number_t count) {
	dtape_stub_safe();
	return KERN_SUCCESS;
};

void task_policy_set_deallocate(task_policy_set_t task_policy_set) {
	return task_deallocate((task_t)task_policy_set);
};

kern_return_t task_purgable_info(task_t task, task_purgable_info_t* stats) {
	dtape_stub_unsafe();
};

kern_return_t task_register_dyld_image_infos(task_t task, dyld_kernel_image_info_array_t infos_copy, mach_msg_type_number_t infos_len) {
	dtape_stub_unsafe();
};

kern_return_t task_register_dyld_shared_cache_image_info(task_t task, dyld_kernel_image_info_t cache_img, boolean_t no_cache, boolean_t private_cache) {
	dtape_stub_unsafe();
};

kern_return_t task_restartable_ranges_register(task_t task, task_restartable_range_t* ranges, mach_msg_type_number_t count) {
	dtape_stub_unsafe();
};

kern_return_t task_restartable_ranges_synchronize(task_t task) {
	dtape_stub_unsafe();
};

kern_return_t task_set_exc_guard_behavior(task_t task, task_exc_guard_behavior_t behavior) {
	dtape_stub_unsafe();
};

kern_return_t task_set_info(task_t task, task_flavor_t flavor, task_info_t task_info_in, mach_msg_type_number_t task_info_count) {
	dtape_stub_unsafe();
};

kern_return_t task_set_phys_footprint_limit(task_t task, int new_limit_mb, int* old_limit_mb) {
	dtape_stub_unsafe();
};

kern_return_t task_set_state(task_t task, int flavor, thread_state_t state, mach_msg_type_number_t state_count) {
	dtape_stub_unsafe();
};

void task_suspension_token_deallocate(task_suspension_token_t token) {
	dtape_stub_unsafe();
};

kern_return_t task_terminate(task_t task) {
	dtape_stub_unsafe();
};

kern_return_t task_unregister_dyld_image_infos(task_t task, dyld_kernel_image_info_array_t infos_copy, mach_msg_type_number_t infos_len) {
	dtape_stub_unsafe();
};

static kern_return_t task_for_pid_internal(mach_port_name_t target_tport, int pid, uintptr_t t, bool task_name) {
	kern_return_t kr = KERN_FAILURE;
	task_t receiving_task = TASK_NULL;
	dtape_task_t* looked_up_task = NULL;
	ipc_port_t right = IPC_PORT_NULL;
	mach_port_name_t out_name = MACH_PORT_NULL;

	receiving_task = port_name_to_task(target_tport);
	if (receiving_task == TASK_NULL) {
		goto out;
	}

	looked_up_task = dtape_hooks->task_lookup(pid, true, true);
	if (!looked_up_task) {
		goto out;
	}

	if (task_name) {
		right = convert_task_name_to_port(&looked_up_task->xnu_task);
	} else {
		if (&looked_up_task->xnu_task == current_task()) {
			right = convert_task_to_port_pinned(&looked_up_task->xnu_task);
		} else {
			right = convert_task_to_port(&looked_up_task->xnu_task);
		}
	}

	// consumed by convert_task{,_name}_to_port{,_pinned}
	looked_up_task = NULL;

	if (right == IPC_PORT_NULL) {
		goto out;
	}

	out_name = ipc_port_copyout_send(right, receiving_task->itk_space);

	// consumed by ipc_port_copyout_send
	right = IPC_PORT_NULL;

	if (!MACH_PORT_VALID(out_name)) {
		goto out;
	}

	if (copyout(&out_name, t, sizeof(out_name))) {
		goto out;
	}

	// consumed by copyout
	out_name = MACH_PORT_NULL;

	kr = KERN_SUCCESS;

out:
	if (MACH_PORT_VALID(out_name)) {
		mach_port_deallocate(receiving_task->itk_space, out_name);
	}
	if (right != IPC_PORT_NULL) {
		ipc_port_release_send(right);
	}
	if (looked_up_task) {
		dtape_task_release(looked_up_task);
	}
	if (receiving_task != TASK_NULL) {
		task_deallocate(receiving_task);
	}
	return kr;
};

kern_return_t task_for_pid(struct task_for_pid_args* args) {
	return task_for_pid_internal(args->target_tport, args->pid, args->t, false);
};

kern_return_t task_name_for_pid(struct task_name_for_pid_args* args) {
	return task_for_pid_internal(args->target_tport, args->pid, args->t, true);
};

kern_return_t pid_for_task(struct pid_for_task_args* args) {
	kern_return_t kr = KERN_FAILURE;
	task_t converted_task = TASK_NULL;
	int pid = -1;

	converted_task = port_name_to_task_name(args->t);
	if (converted_task == TASK_NULL) {
		goto out;
	}

	pid = task_pid(converted_task);

	if (pid < 0) {
		goto out;
	}

	if (copyout(&pid, args->pid, sizeof(pid))) {
		goto out;
	}

	kr = KERN_SUCCESS;

out:
	if (converted_task != TASK_NULL) {
		task_deallocate(converted_task);
	}
	return kr;
};

boolean_t task_is_exec_copy(task_t task) {
	dtape_stub_safe();
	return FALSE;
};

void task_wait_locked(task_t task, boolean_t until_not_runnable) {
	// this was stubbed in the LKM, so it should be safe to stub here
	dtape_stub_safe();
};

//
// for task_ident.c
//

void* proc_find_ident(struct proc_ident const *i) {
	return dtape_hooks->task_lookup_eternal(i->eid, true);
};

int proc_rele(void* p) {
	dtape_task_release(p);
	return 0;
};

task_t proc_task(void* p) {
	return &((dtape_task_t*)p)->xnu_task;
};

struct proc_ident proc_ident(void* p) {
	return ((dtape_task_t*)p)->p_ident;
};

//
// end for task_ident.c
//

