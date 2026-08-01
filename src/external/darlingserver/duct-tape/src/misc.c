#include <darlingserver/duct-tape.h>
#include <darlingserver/duct-tape/hooks.internal.h>
#include <darlingserver/duct-tape/log.h>

#include <kern/waitq.h>
#include <kern/clock.h>
#include <kern/turnstile.h>
#include <kern/thread_call.h>
#include <ipc/ipc_object.h>
#include <ipc/ipc_port.h>
#include <kern/host.h>

#include <sys/types.h>

char version[] = "Darling 11.5";

#if __x86_64__ || __i386__
	// <copied from="xnu://7195.141.2/osfmk/i386/pcb.c"
	unsigned int _MachineStateCount[] = {
		[x86_THREAD_STATE32]            = x86_THREAD_STATE32_COUNT,
		[x86_THREAD_STATE64]            = x86_THREAD_STATE64_COUNT,
		[x86_THREAD_FULL_STATE64]       = x86_THREAD_FULL_STATE64_COUNT,
		[x86_THREAD_STATE]              = x86_THREAD_STATE_COUNT,
		[x86_FLOAT_STATE32]             = x86_FLOAT_STATE32_COUNT,
		[x86_FLOAT_STATE64]             = x86_FLOAT_STATE64_COUNT,
		[x86_FLOAT_STATE]               = x86_FLOAT_STATE_COUNT,
		[x86_EXCEPTION_STATE32]         = x86_EXCEPTION_STATE32_COUNT,
		[x86_EXCEPTION_STATE64]         = x86_EXCEPTION_STATE64_COUNT,
		[x86_EXCEPTION_STATE]           = x86_EXCEPTION_STATE_COUNT,
		[x86_DEBUG_STATE32]             = x86_DEBUG_STATE32_COUNT,
		[x86_DEBUG_STATE64]             = x86_DEBUG_STATE64_COUNT,
		[x86_DEBUG_STATE]               = x86_DEBUG_STATE_COUNT,
		[x86_AVX_STATE32]               = x86_AVX_STATE32_COUNT,
		[x86_AVX_STATE64]               = x86_AVX_STATE64_COUNT,
		[x86_AVX_STATE]                 = x86_AVX_STATE_COUNT,
		[x86_AVX512_STATE32]            = x86_AVX512_STATE32_COUNT,
		[x86_AVX512_STATE64]            = x86_AVX512_STATE64_COUNT,
		[x86_AVX512_STATE]              = x86_AVX512_STATE_COUNT,
		[x86_PAGEIN_STATE]              = x86_PAGEIN_STATE_COUNT
	};
	// </copied>
#else
	#error _MachineStateCount not defined on this architecture
#endif

int vsnprintf(char* buffer, size_t buffer_size, const char* format, va_list args);
ssize_t getrandom(void* buf, size_t buflen, unsigned int flags);


void dtape_logv(dtape_log_level_t level, const char* format, va_list args) {
	char message[4096];
	vsnprintf(message, sizeof(message), format, args);
	dtape_hooks->log(level, message);
};

void dtape_log(dtape_log_level_t level, const char* format, ...) {
	va_list args;
	va_start(args, format);
	dtape_logv(level, format, args);
	va_end(args);
};


void read_frandom(void* buffer, unsigned int numBytes) {
	getrandom(buffer, numBytes, 0);
};

void kprintf(const char* fmt, ...) {
	va_list args;
	va_start(args, fmt);
	dtape_logv(dtape_log_level_info, fmt, args);
	va_end(args);
};

int scnprintf(char* buffer, size_t buffer_size, const char* format, ...) {
	va_list args;
	va_start(args, format);
	int code = vsnprintf(buffer, buffer_size, format, args);
	va_end(args);
	if (code < 0) {
		return code;
	} else {
		return strnlen(buffer, buffer_size);
	}
};

void (ipc_kmsg_trace_send)(ipc_kmsg_t kmsg, mach_msg_option_t option) {
	pid_t dest_pid = -1;
	ipc_port_t dest = kmsg->ikm_header->msgh_remote_port;

	dest_pid = ipc_port_get_receiver_task(dest, NULL);

	// The msgh_id is the MIG routine number, which is what actually identifies the
	// operation. Without it every message in the log looks alike and a stalled
	// request cannot be told from a healthy one (task #47).
	// For a COMPLEX message, also report the descriptor count and the first descriptor's
	// type. Port descriptors copy out entirely inside the daemon; OOL descriptors have to
	// map memory INTO the guest, which is a very different (and much more failure-prone)
	// path. Telling them apart from a log is the difference between a guess and a fact.
	int ndesc = -1, dtype = -1;
	if (kmsg->ikm_header->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		mach_msg_body_t* body = (mach_msg_body_t*)(kmsg->ikm_header + 1);
		ndesc = body->msgh_descriptor_count;
		if (ndesc > 0) {
			dtype = ((mach_msg_type_descriptor_t*)(body + 1))->type;
		}
	}

	dtape_log_debug("sending kmsg %p to pid %d id=%d size=%u bits=0x%x remote=%p local=%p ndesc=%d dtype=%d",
		kmsg, dest_pid,
		kmsg->ikm_header->msgh_id,
		kmsg->ikm_header->msgh_size,
		kmsg->ikm_header->msgh_bits,
		kmsg->ikm_header->msgh_remote_port,
		kmsg->ikm_header->msgh_local_port,
		ndesc, dtype);
};

void Assert(const char* file, int line, const char* expression) {
	panic("%s:%d Assertion failed: %s", file, line, expression);
};

unsigned int waitq_held(struct waitq* wq) {
	return wq->dtape_waitq_interlock.dtape_interlock.dtape_interlock.dtape_mutex.dtape_owner == (uintptr_t)current_thread();
};

#if __x86_64__

//
// <copied from="xnu://7195.141.2/osfmk/x86_64/loose_ends.c">
//

/*
 * Find last bit set in bit string.
 */
int
fls(unsigned int mask)
{
	if (mask == 0) {
		return 0;
	}

	return (sizeof(mask) << 3) - __builtin_clz(mask);
}

//
// </copied>
//

#endif
