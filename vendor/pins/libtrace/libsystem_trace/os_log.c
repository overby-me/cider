/*
 * Copyright (c) 2019 PureDarwin Project
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <xpc/xpc.h>
#include "os_log_s.h"
#include "libtrace_assert.h"
#include <asl.h>
#include <dlfcn.h>
#include <os/log.h>
#import <os/object_private.h>

#ifdef os_log_create
#undef os_log_create
#endif

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

OS_OBJECT_OBJC_CLASS_DECL(os_log);

struct os_log_s _os_log_disabled = {
	.isa = NULL,
	.ref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
	.xref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
	.magic = OS_LOG_DISABLED_MAGIC,
	.subsystem = "",
	.category = ""
};

struct os_log_s _os_log_default = {
	.isa = NULL,
	.ref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
	.xref_cnt = _OS_OBJECT_GLOBAL_REFCNT,
	.magic = OS_LOG_DEFAULT_MAGIC,
	.subsystem = "",
	.category = ""
};

static asl_object_t get_client() {
	static asl_object_t client = NULL;
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		client = asl_open(NULL, "org.puredarwin.os_log", 0);
	});
	return client;
};

os_log_t os_log_create(const char *subsystem, const char *category) {
	libtrace_precondition(subsystem != NULL, "subsystem cannot be NULL");
	libtrace_precondition(category != NULL, "category cannot be NULL");

	os_log_t value = (os_log_t)_os_object_alloc(&OS_OBJECT_CLASS_SYMBOL(os_log), sizeof(struct os_log_s));
	value->magic = OS_LOG_MAGIC;
	value->subsystem = strdup(subsystem);
	value->category = strdup(category);
	return value;
}

bool os_log_type_enabled(os_log_t log, os_log_type_t type) {
	if (log == NULL) return false;
	if (log->magic == OS_LOG_DISABLED_MAGIC) return false;

	return true;
}

__XNU_PRIVATE_EXTERN
char *os_log_decode_buffer(const char *formatString, uint8_t *buffer, uint32_t bufferSize);
__XNU_PRIVATE_EXTERN
const char *os_log_buffer_to_hex_string(const uint8_t *buffer, uint32_t buffer_size);

void
_os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) {
	libtrace_precondition(log != NULL, "os_log_t cannot be NULL");
	if (log->magic == OS_LOG_DISABLED_MAGIC) return;
	libtrace_precondition(log->magic == OS_LOG_DEFAULT_MAGIC || log->magic == OS_LOG_MAGIC, "Invalid os_log_t pointer parameter passed to _os_log_impl()");
	libtrace_precondition(type >= OS_LOG_TYPE_DEFAULT && type <= OS_LOG_TYPE_FAULT, "Invalid os_log_type_t parameter passed to _os_log_impl()");

	/*
	 * A CALL WHOSE ARGUMENTS CANNOT BE TRUSTED, REFUSED HERE RATHER THAN IN EVERY CONSUMER.
	 *
	 * iA Writer arrives with size=4292804464, which is -2162832 in a uint32_t, and the format
	 * pointer is no better: the decoder died on an unmapped page, and so did a strlen of the format
	 * once the decoder was skipped. Clamping the length would not help, because the decoder walks
	 * the buffer by the FORMAT STRING rather than by the size.
	 *
	 * So when the size is outside os_log's own 1024 byte maximum for one entry, NOTHING from this
	 * call is read, not even the format. The entry still goes out, saying that much, because a log
	 * call must never be able to kill the process it is describing.
	 *
	 * The return address names the caller, which the arguments cannot.
	 */
	bool argumentsReadable = (buf != NULL && size <= 1024);

	if (!argumentsReadable) {
		static bool reported = false;

		if (!reported) {
			void *caller = __builtin_return_address(0);
			Dl_info info;

			reported = true;
			if (dladdr(caller, &info) != 0 && info.dli_sname != NULL) {
				fprintf(stderr, "libtrace: os_log arguments unreadable (buf=%p size=%u) from %s + %ld"
						" in %s\n", buf, size, info.dli_sname,
						(long) ((char *) caller - (char *) info.dli_saddr),
						info.dli_fname ? info.dli_fname : "?");
			} else {
				fprintf(stderr, "libtrace: os_log arguments unreadable (buf=%p size=%u) from %p\n",
						buf, size, caller);
			}
			fflush(stderr);
		}
	}

	aslmsg message = asl_new(ASL_TYPE_MSG);
	asl_set(message, "os_log(3)", "TRUE");

	const char *subsystem = log->subsystem;
	if (strlen(subsystem) == 0) subsystem = "(default)";
	const char *category = log->category;
	if (strlen(category) == 0) category = "(default)";

	asl_set(message, "Subsystem", subsystem);
	asl_set(message, "Category", category);

	const char *buffer_hex = argumentsReadable ? os_log_buffer_to_hex_string(buf, size) : strdup("");
	asl_set(message, "HexBuffer", buffer_hex);

	int level;
	switch (type) {
		case OS_LOG_TYPE_DEBUG:
			level = ASL_LEVEL_DEBUG;
			break;

		case OS_LOG_TYPE_INFO:
		case OS_LOG_TYPE_DEFAULT:
			level = ASL_LEVEL_INFO;
			break;

		case OS_LOG_TYPE_ERROR:
			level = ASL_LEVEL_ERR;
			break;

		case OS_LOG_TYPE_FAULT:
			level = ASL_LEVEL_ALERT;
			break;

		default:
			libtrace_assert(false, "Invalid os_log_type_t not caught by precondition");
	}

	char *decodedBuffer = argumentsReadable ? os_log_decode_buffer(format, buf, size)
	                                        : strdup("(os_log arguments unreadable)");

	/*
	 * LOGGING MUST NOT BLOCK THE CALLER, and here it did.
	 *
	 * asl_log sends to the logging service and waits for it. With no syslogd running the send goes
	 * to a port nobody reads and never returns, so a single os_log call stops the thread that made
	 * it forever. iTerm2 hung exactly there, inside -[NSXPCConnection _sendInvocation...], with its
	 * main thread in mach_msg_overwrite underneath syslog and vsnprintf, before its first window.
	 *
	 * On macOS os_log never blocks its caller: the entry goes into a buffer and a daemon drains it.
	 * A serial queue is the same shape. If the service is absent the queue backs up and the entries
	 * are lost, which is what "no logging daemon" should cost, rather than the process.
	 */
	static dispatch_queue_t queue = NULL;
	static dispatch_once_t queueToken;
	dispatch_once(&queueToken, ^{
		queue = dispatch_queue_create("org.cider.os_log", DISPATCH_QUEUE_SERIAL);
	});

	aslmsg owned = message;
	char *text = decodedBuffer;
	const char *hex = buffer_hex;
	int sendLevel = level;

	dispatch_async(queue, ^{
		asl_log(get_client(), owned, sendLevel, "%s", text);
		asl_release(owned);
		free(text);
		free((void *)hex);
	});
}

// os_log_error()/os_log_debug() expand to these type-fixed entry points instead of
// _os_log_impl; they differ from it only in being NOT_TAIL_CALLED, so a backtrace keeps
// the caller's frame.
//
// THEY TAKE THE TYPE TOO, and that argument is not redundant even though the entry point
// implies it: it occupies a register. Declared without it, every later argument arrived one
// slot early, so format held OS_LOG_TYPE_ERROR and size held half of the buffer pointer.
// iA Writer's Sparkle logs through this path and the run died first in the buffer decoder
// and then in a strlen of the "format", with size=4292804464.
void
_os_log_error_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) {
	_os_log_impl(dso, log, type, format, buf, size);
}

void
_os_log_debug_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) {
	_os_log_impl(dso, log, type, format, buf, size);
}

#pragma mark Legacy Functions

os_log_t _os_log_create(void *dso __unused, const char *subsystem, const char *category) {
	return os_log_create(subsystem, category);
}

bool os_log_is_enabled(os_log_t log) {
	return true;
}

bool os_log_is_debug_enabled(os_log_t log) {
	return os_log_type_enabled(log, OS_LOG_TYPE_DEBUG);
}
