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

#include <ctype.h>
#include <errno.h>
#include "os_log_s.h"
#include "libtrace_assert.h"
#include "libsbuf.h"
#include <wchar.h>
#import <Foundation/NSString.h>
#import <objc/runtime.h>

// disable os_log privacy by default for debug builds
#ifndef OS_LOG_PRIVACY
	#ifdef NDEBUG
		#define OS_LOG_PRIVACY 1
	#else
		#define OS_LOG_PRIVACY 0
	#endif
#endif

static bool contains_attribute(char *allAttributes, char *desired) {
	if (strcmp(allAttributes, desired) == 0) return true;

	char *needle = strstr(allAttributes, desired);
	if (needle == NULL) return false;

	if (needle != allAttributes) {
		// The "if" check on the above line is to avoid underflowing the buffer,
		// in case the desired attribute is located at the very start of allAttributes.
		char *comma = needle - 1;
		if (*comma != ',') return false;
	}

	char *end = needle + strlen(desired);
	if (*end == '\0' || *end == ',') return true;

	return false;
}

typedef enum {
	privacy_setting_unset = 0,
	privacy_setting_private = 1,
	privacy_setting_public = 2
} privacy_setting_t;

OS_ENUM(os_log_buffer_item_type, uint8_t,
	os_log_buffer_item_type_scalar = 0,
	os_log_buffer_item_type_count,
	os_log_buffer_item_type_string,
	os_log_buffer_item_type_pointer,
	os_log_buffer_item_type_objc,
	os_log_buffer_item_type_wide_string,
	os_log_buffer_item_type_errno,
);

static bool readScalar(void* buffer, uint8_t length, uint64_t* outScalar) {
	if (length == 1) {
		*outScalar = *(uint8_t*)buffer;
	} else if (length == 2) {
		*outScalar = *(uint16_t*)buffer;
	} else if (length == 4) {
		*outScalar = *(uint32_t*)buffer;
	} else if (length == 8) {
		*outScalar = *(uint64_t*)buffer;
	} else {
		return false;
	}
	return true;
};

__XNU_PRIVATE_EXTERN
char *os_log_decode_buffer(const char *formatString, uint8_t *buffer, uint32_t bufferSize) {
	uint32_t bufferIndex = 0;
	// uint8_t summaryByte = buffer[bufferIndex]; // not actually used, hence commented out
	bufferIndex++;

	uint8_t argsSeen = 0;
	uint8_t argCount = buffer[bufferIndex];
	bufferIndex++;

	struct sbuf *sbuf = sbuf_new_auto();
	size_t formatIndex = 0;

	while (formatString[formatIndex] != '\0') {
		if (formatString[formatIndex] != '%') {
			sbuf_putc(sbuf, formatString[formatIndex]);
			formatIndex++;
			continue;
		}

		libtrace_assert(formatString[formatIndex] == '%', "next char not % (this shouldn't happen)");
		formatIndex++;

		os_log_buffer_item_type_t itemType = buffer[bufferIndex] >> 4;
		privacy_setting_t privacy = buffer[bufferIndex] & 0x0f;
		++bufferIndex;

		uint8_t itemSize = buffer[bufferIndex];
		++bufferIndex;

		libtrace_assert(argsSeen < argCount, "Too many format specifiers in os_log string (expected %d)", argCount);

		if (formatString[formatIndex] == '{') {
			// just skip it; the buffer will tell us if it's public or private or unspecified
			formatString = strchr(formatString + formatIndex, '}') + 1;
		}

		// skip these, for now
		// TODO: implement these
		while (
			formatString[formatIndex] == '-'    ||
			formatString[formatIndex] == '+'    ||
			formatString[formatIndex] == ' '    ||
			formatString[formatIndex] == '#'    ||
			formatString[formatIndex] == '0'    ||
			formatString[formatIndex] == '.'    ||
			formatString[formatIndex] == '*'    ||
			isnumber(formatString[formatIndex])
		) {
			formatIndex++;
		}

		// skip the length specifiers (the buffer already includes this information)
		if (formatString[formatIndex] == 'h') {
			++formatIndex;
			if (formatString[formatIndex] == 'h') {
				++formatIndex;
			}
		} else if (formatString[formatIndex] == 'l') {
			++formatIndex;
			if (formatString[formatIndex] == 'l') {
				++formatIndex;
			}
		} else if (formatString[formatIndex] == 'j') {
			++formatIndex;
		} else if (formatString[formatIndex] == 'z') {
			++formatIndex;
		} else if (formatString[formatIndex] == 't') {
			++formatIndex;
		} else if (formatString[formatIndex] == 'L') {
			++formatIndex;
		} else if (formatString[formatIndex] == 'q') {
			++formatIndex;
		}

		char* formattedArgument = NULL;
		bool formattedArgumentNeedsFree = true;
		size_t formattedArgumentLength = SIZE_MAX;

		if (formatString[formatIndex] == 's') {
			uint64_t maxLength = SIZE_MAX;
			uint64_t pointer = 0;

			if (itemType == os_log_buffer_item_type_count) {
				libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, &maxLength), "failed to read maximum string length from buffer");
				bufferIndex += itemSize;
				itemType = buffer[bufferIndex] >> 4;
				privacy = buffer[bufferIndex] & 0x0f;
				++bufferIndex;
				itemSize = buffer[bufferIndex];
				++bufferIndex;
			}

			libtrace_assert(itemType == os_log_buffer_item_type_string, "expected buffer item to be a string");
			libtrace_assert(itemSize == sizeof(const char*), "expected pointer size to match platform pointer length");

			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, &pointer), "failed to read string pointer from buffer");
			bufferIndex += itemSize;

			formattedArgument = (char*)pointer;
			formattedArgumentNeedsFree = false;
			formattedArgumentLength = (size_t)maxLength;

			if (privacy == privacy_setting_unset) privacy = privacy_setting_private;
		} else if (formatString[formatIndex] == 'S') {
			uint64_t maxLength = UINT64_MAX;
			uint64_t pointer = 0;
			const wchar_t* wideArgument = NULL;
			mbstate_t state = {0};

			if (itemType == os_log_buffer_item_type_count) {
				libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, &maxLength), "failed to read maximum string length from buffer");
				bufferIndex += itemSize;
				itemType = buffer[bufferIndex] >> 4;
				privacy = buffer[bufferIndex] & 0x0f;
				++bufferIndex;
				itemSize = buffer[bufferIndex];
				++bufferIndex;
			}

			libtrace_assert(itemType == os_log_buffer_item_type_string, "expected buffer item to be a string");
			libtrace_assert(itemSize == sizeof(const wchar_t*), "expected pointer size to match platform pointer length");

			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, &pointer), "failed to read string pointer from buffer");
			bufferIndex += itemSize;

			// technically, this is wrong; the output string will be a multi-byte string of whatever locale the system is currently using
			// but we're kinda stuck with it because the input string *does* need to be in the current locale :/
			// i wonder how Apple handles these in their libtrace...

			wideArgument = (const wchar_t*)pointer;
			formattedArgumentLength = wcsnrtombs(NULL, &wideArgument, maxLength, 0, &state);
			libtrace_assert(formattedArgumentLength != (size_t)-1, "wide character string argument cannot be converted to multi-byte string");
			formattedArgument = calloc(formattedArgumentLength + 1, sizeof(char));

			memset(&state, 0, sizeof(state));
			wideArgument = (const wchar_t*)pointer;
			libtrace_assert(wcsnrtombs(formattedArgument, &wideArgument, maxLength, formattedArgumentLength, &state) == formattedArgumentLength, "wide character string argument cannot be converted to multi-byte string");

			if (privacy == privacy_setting_unset) privacy = privacy_setting_private;
		} else if (formatString[formatIndex] == 'P') {
			uint64_t length = 0;
			uint64_t pointer = 0;

			libtrace_assert(itemType == os_log_buffer_item_type_count, "expected buffer item to be a count");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, &length), "failed to read maximum data length from buffer");
			bufferIndex += itemSize;
			itemType = buffer[bufferIndex] >> 4;
			privacy = buffer[bufferIndex] & 0x0f;
			++bufferIndex;
			itemSize = buffer[bufferIndex];
			++bufferIndex;

			libtrace_assert(itemType == os_log_buffer_item_type_pointer, "expected buffer item to be a pointer");
			libtrace_assert(itemSize == sizeof(const void*), "expected pointer size to match platform pointer length");

			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, &pointer), "failed to read pointer from buffer");
			bufferIndex += itemSize;

			struct sbuf *dataHex = sbuf_new_auto();
			sbuf_putc(dataHex, '<');

			for (uint64_t i = 0; i < length; i++) {
				sbuf_printf(dataHex, "%02x", ((const char*)pointer)[i]);
			}

			sbuf_putc(dataHex, '>');
			formattedArgument = strdup(sbuf_data(dataHex));
			sbuf_delete(dataHex);

			if (privacy == privacy_setting_unset) privacy = privacy_setting_private;
		} else if (formatString[formatIndex] == '@') {
			uint64_t integer;
			id object = nil;
			NSString* description = nil;

			libtrace_assert(itemType == os_log_buffer_item_type_objc, "expected buffer item to be an object pointer");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, (uint64_t*)&integer), "failed to read object pointer from buffer");
			bufferIndex += itemSize;

			object = (id)integer;

			@autoreleasepool {
				description = [object description];

				if (description) {
					formattedArgument = strdup(description.UTF8String);
				} else {
					asprintf(&formattedArgument, "<%s: %p>", object_getClassName(object), object);
				}
			}

			if (privacy == privacy_setting_unset) privacy = privacy_setting_private;
		} else if (formatString[formatIndex] == 'm') {
			libtrace_assert(itemType == os_log_buffer_item_type_errno, "expected buffer item to be a request for errno");
			libtrace_assert(itemSize == 0, "expected item size to be 0");

			formattedArgument = strdup(strerror(errno));

			if (privacy == privacy_setting_unset) privacy = privacy_setting_public;
		} else if (formatString[formatIndex] == 'c') {
			uint64_t integer;
			char character;

			libtrace_assert(itemType == os_log_buffer_item_type_scalar, "expected buffer item to be a scalar");
			libtrace_assert(itemSize == 1, "expected item size to be 1");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, (uint64_t*)&integer), "failed to read scalar from buffer");
			bufferIndex += itemSize;

			character = (char)integer;
			asprintf(&formattedArgument, "%c", character);

			if (privacy == privacy_setting_unset) privacy = privacy_setting_public;
		} else if (formatString[formatIndex] == 'd' || formatString[formatIndex] == 'i') {
			int64_t integer;

			libtrace_assert(itemType == os_log_buffer_item_type_scalar, "expected buffer item to be a scalar");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, (uint64_t*)&integer), "failed to read scalar from buffer");
			bufferIndex += itemSize;

			asprintf(&formattedArgument, "%lld", integer);

			if (privacy == privacy_setting_unset) privacy = privacy_setting_public;
		} else if (formatString[formatIndex] == 'u' || formatString[formatIndex] == 'o' || formatString[formatIndex] == 'x' || formatString[formatIndex] == 'X') {
			uint64_t integer;
			char format[] = { '%', 'l', 'l', formatString[formatIndex], '\0' };

			libtrace_assert(itemType == os_log_buffer_item_type_scalar, "expected buffer item to be a scalar");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, (uint64_t*)&integer), "failed to read scalar from buffer");
			bufferIndex += itemSize;

			asprintf(&formattedArgument, format, integer);

			if (privacy == privacy_setting_unset) privacy = privacy_setting_public;
		} else if (formatString[formatIndex] == 'p') {
			uint64_t integer;
			void* pointer = NULL;

			libtrace_assert(itemType == os_log_buffer_item_type_scalar, "expected buffer item to be a scalar");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, (uint64_t*)&integer), "failed to read scalar from buffer");
			bufferIndex += itemSize;

			pointer = (void*)integer;
			asprintf(&formattedArgument, "%p", pointer);

			if (privacy == privacy_setting_unset) privacy = privacy_setting_private;
		} else if (formatString[formatIndex] == 'f' || formatString[formatIndex] == 'F' || formatString[formatIndex] == 'e' || formatString[formatIndex] == 'E' || formatString[formatIndex] == 'g' || formatString[formatIndex] == 'G' || formatString[formatIndex] == 'a' || formatString[formatIndex] == 'A') {
			double decimal;
			char format[] = { '%', formatString[formatIndex], '\0' };

			libtrace_assert(itemType == os_log_buffer_item_type_scalar, "expected buffer item to be a scalar");
			libtrace_assert(readScalar(&buffer[bufferIndex], itemSize, (uint64_t*)&decimal), "failed to read scalar from buffer");
			bufferIndex += itemSize;

			asprintf(&formattedArgument, format, decimal);

			if (privacy == privacy_setting_unset) privacy = privacy_setting_public;
		} else {
			asprintf(&formattedArgument, "<missing formatter for %%%c>", formatString[formatIndex]);

			// skip the item in the buffer
			bufferIndex += itemSize;

			libtrace_assert(false, "Unknown format argument %%%c in os_log() call", formatString[formatIndex]);
		}

		++formatIndex;

		formattedArgumentLength = strnlen(formattedArgument, formattedArgumentLength);

#if OS_LOG_PRIVACY
		if (privacy == privacy_setting_public) {
#endif
			sbuf_bcat(sbuf, formattedArgument, formattedArgumentLength * sizeof(char));
#if OS_LOG_PRIVACY
		} else {
			sbuf_cat(sbuf, "<private>");
		}
#endif

		if (formattedArgumentNeedsFree) {
			free(formattedArgument);
		}

		argsSeen++;
	}

	char *retval = strdup(sbuf_data(sbuf));
	sbuf_delete(sbuf);
	return retval;
}

__XNU_PRIVATE_EXTERN
const char *os_log_buffer_to_hex_string(const uint8_t *buffer, uint32_t buffer_size) {
	struct sbuf *sbuf = sbuf_new_auto();
	while (buffer_size-- != 0) {
		sbuf_printf(sbuf, "%02X", buffer[0]);
		buffer++;
	}

	const char *retval = strdup(sbuf_data(sbuf));
	sbuf_delete(sbuf);
	return retval;
}
