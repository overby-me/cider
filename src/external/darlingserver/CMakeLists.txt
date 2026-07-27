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
# NOTE: NOT the cause of the boot stall -- strace showed the ~30s early-boot delay
# is a specific RPC (semaphore_timedwait_signal, call 62) timing out, identical
# with FAST_EPOLL on or off; general reply delivery is prompt. See
# plan/guest-nix-m1.md.
option(DSERVER_FAST_EPOLL "Skip redundant eventfd epoll re-arms in the event loop" ON)

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

# The C++ host-side daemon (add_executable(darlingserver) + src/*.cpp) has been REMOVED: the Rust
# rewrite (src/external/darlingserver-rs) is now the daemon. This build only produces the shared
# duct-tape static libs (add_subdirectory(duct-tape) above) that the Rust daemon links against,
# plus the generated RPC wrappers and the optional debug tools. See plan/rust-rewrite-eval.md.
