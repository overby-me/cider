project(libsystem_trace)

include_directories(
	${CMAKE_CURRENT_SOURCE_DIR}/libsbuf
	${CMAKE_CURRENT_SOURCE_DIR}/include
)

include(darling_static_lib)

set(system_trace_sources
	libsystem_trace/libtrace_assert.c
	libsystem_trace/os_log.c
	libsystem_trace/os_activity.m
	libsystem_trace/stubs.c
	libsystem_trace/unpack_buffer.m
	libsystem_trace/classes.m
	libsystem_trace/init.c
	libsbuf/libsbuf.c
)

set(DYLIB_INSTALL_NAME "/usr/lib/system/libsystem_trace.dylib")
add_circular(system_trace FAT
	SOURCES
		${system_trace_sources}
	SIBLINGS
		platform system_kernel system_c system_malloc system_asl system_duct libdispatch_shared system_dyld system_blocks
	UPWARD
		objc
)

add_darling_static_library(system_trace_static FAT SOURCES $<TARGET_OBJECTS:system_trace_obj>)

install(TARGETS system_trace DESTINATION libexec/darling/usr/lib/system)
install(FILES libsystem_trace/org.puredarwin.os_log.asl DESTINATION libexec/darling/private/etc/asl)
