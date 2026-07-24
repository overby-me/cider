project(darlingserver)

cmake_minimum_required(VERSION 3.13)

option(DSERVER_TOOLS "Build darlingserver tools (for debugging)" OFF)
option(DSERVER_ASAN "Build darlingserver with ASAN" OFF)
option(DSERVER_UBSAN "Build darlingserver with UBSAN" OFF)
# Signal-mask-free microthread context switching (x86_64): drops glibc's
# per-switch rt_sigprocmask, which is pure overhead here since the microthreads
# run with an invariant signal mask. Behaviour is otherwise identical to glibc
# ucontext (validated). Set OFF to fall back to glibc get/set/makecontext.
option(DSERVER_FAST_CONTEXT "Signal-mask-free microthread context switch (x86_64)" ON)
# P2: memoize the event loop's _wakeupFD arming so it skips a redundant
# EPOLL_CTL_MOD on every iteration (same armed states, fewer syscalls).
# DISABLED: the memoized _wakeupArmedEvents drifts out of sync with the kernel's
# EPOLLONESHOT auto-disarm, so it intermittently skips a *needed* re-arm of the
# reply-wakeup eventfd. The worker's "reply ready" signal is then missed and the
# reply is not sent until the ~30s dtape timer fires -- each early-boot RPC stalls
# ~30s, so the container exceeds darling.c's 120s shellspawn budget and boot fails
# (intermittently: a boot whose replies happen to fire fast still finishes). See
# plan/guest-nix-m1.md (strace shows the 30s reply-delivery gap). Unconditional
# re-arm (OFF) self-corrects the drift every iteration.
option(DSERVER_FAST_EPOLL "Skip redundant eventfd epoll re-arms in the event loop" OFF)

if (DSERVER_TOOLS)
	add_subdirectory(tools)
endif()

if (DSERVER_ASAN)
	add_compile_definitions(
		DSERVER_ASAN=1
	)
else()
	add_compile_definitions(
		DSERVER_ASAN=0
	)
endif()

if (DSERVER_UBSAN)
	add_compile_definitions(
		DSERVER_UBSAN=1
	)
else()
	add_compile_definitions(
		DSERVER_UBSAN=0
	)
endif()

set(dserver_sanitizers "")
if (DSERVER_ASAN)
	if (NOT (dserver_sanitizers STREQUAL ""))
		set(dserver_sanitizers "${dserver_sanitizers},")
	endif()
	set(dserver_sanitizers "${dserver_sanitizers}address")
endif()
if (DSERVER_UBSAN)
	if (NOT (dserver_sanitizers STREQUAL ""))
		set(dserver_sanitizers "${dserver_sanitizers},")
	endif()
	set(dserver_sanitizers "${dserver_sanitizers}undefined")
endif()

option(DSERVER_EXTENDED_DEBUG "Build darlingserver with extended debugging support" OFF)

if (DSERVER_EXTENDED_DEBUG)
	add_compile_definitions(
		DSERVER_EXTENDED_DEBUG=1
	)
else()
	add_compile_definitions(
		DSERVER_EXTENDED_DEBUG=0
	)
endif()

option(DSERVER_SINGLE_THREADED "Only use a single thread per workqueue in darlingserver" ON)

if (DSERVER_SINGLE_THREADED)
	add_compile_definitions(
		DSERVER_SINGLE_THREADED=1
	)
else()
	add_compile_definitions(
		DSERVER_SINGLE_THREADED=0
	)
endif()

add_subdirectory(duct-tape)

set(DARLINGSERVER_INIT_PROCESS "/sbin/launchd" CACHE STRING "The init process darlingserver should execute (default is \"/sbin/launchd\")")
set(DARLINGSERVER_XDG_USER_DIR_CMD "xdg-user-dir" CACHE STRING "The xdg-user-dir binary darlingserver should execute (default is \"xdg-user-dir\")")

include_directories(
	include
	internal-include
	${CMAKE_CURRENT_BINARY_DIR}/include
	${CMAKE_CURRENT_BINARY_DIR}/internal-include
	${CMAKE_BINARY_DIR}/src/startup # for `rtsig.h`
)

add_custom_command(
	OUTPUT
		${CMAKE_CURRENT_BINARY_DIR}/include/darlingserver/rpc.h
		${CMAKE_CURRENT_BINARY_DIR}/internal-include/darlingserver/rpc.internal.h
		${CMAKE_CURRENT_BINARY_DIR}/src/rpc.c
	COMMAND
		${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate-rpc-wrappers.py
		${CMAKE_CURRENT_BINARY_DIR}/include/darlingserver/rpc.h
		${CMAKE_CURRENT_BINARY_DIR}/internal-include/darlingserver/rpc.internal.h
		${CMAKE_CURRENT_BINARY_DIR}/src/rpc.c
		\"../include/darlingserver/rpc.h\"
	VERBATIM
	MAIN_DEPENDENCY
		${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate-rpc-wrappers.py
)

add_custom_target(generate_dserver_rpc_wrappers
	ALL
	DEPENDS
		${CMAKE_CURRENT_BINARY_DIR}/include/darlingserver/rpc.h
		${CMAKE_CURRENT_BINARY_DIR}/internal-include/darlingserver/rpc.internal.h
		${CMAKE_CURRENT_BINARY_DIR}/src/rpc.c
)

add_executable(darlingserver
	src/darlingserver.cpp
	src/server.cpp
	src/message.cpp
	src/call.cpp
	src/registry.cpp
	src/logging.cpp
	src/process.cpp
	src/thread.cpp
	src/utility.cpp
	src/kqchan.cpp
	src/async-writer.cpp
	src/stack-pool.cpp
)

add_dependencies(darlingserver
	generate_dserver_rpc_wrappers
	rtsig_h
)

target_link_libraries(darlingserver PRIVATE
	darlingserver_duct_tape
)

if (DSERVER_FAST_CONTEXT AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
	target_sources(darlingserver PRIVATE src/fast_context.c)
	target_compile_definitions(darlingserver PRIVATE DSERVER_FAST_CONTEXT=1)
endif()

if (DSERVER_FAST_EPOLL)
	target_compile_definitions(darlingserver PRIVATE DSERVER_FAST_EPOLL=1)
endif()

target_compile_options(darlingserver PRIVATE
	-pthread
	-std=c++17
)
target_link_options(darlingserver PRIVATE
	-pthread
	-Wl,--gc-sections
)

if (DSERVER_ASAN OR DSERVER_UBSAN)
	target_compile_options(darlingserver PRIVATE
		-fsanitize=${dserver_sanitizers}
		-fsanitize-recover=all
		-fno-omit-frame-pointer
		-g
		-Og
	)
	target_link_options(darlingserver PRIVATE
		-fsanitize=${dserver_sanitizers}
		-fsanitize-recover=all
	)
endif()

if (DSERVER_EXTENDED_DEBUG)
	target_compile_options(darlingserver PRIVATE
		-fno-omit-frame-pointer
	)
endif()

install(TARGETS darlingserver DESTINATION bin)

#file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/${DARLING_SDK_RELATIVE_PATH}/usr/include/darlingserver")
#create_symlink(
#	"${DARLING_ROOT_RELATIVE_TO_SDK}/../../../src/darlingserver/include/darlingserver/rpc.h"
#	"${CMAKE_BINARY_DIR}/${DARLING_SDK_RELATIVE_PATH}/usr/include/darlingserver/rpc.h"
#)

if (NOT "${DARLINGSERVER_INIT_PROCESS}" STREQUAL "")
	target_compile_definitions(darlingserver PRIVATE
		DARLINGSERVER_INIT_PROCESS="${DARLINGSERVER_INIT_PROCESS}"
	)
endif()

if (NOT "${DARLINGSERVER_XDG_USER_DIR_CMD}" STREQUAL "")
	target_compile_definitions(darlingserver PRIVATE
		DARLINGSERVER_XDG_USER_DIR_CMD="${DARLINGSERVER_XDG_USER_DIR_CMD}"
	)
endif()
