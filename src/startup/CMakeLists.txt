project(rtsig-gen)

cmake_minimum_required(VERSION 3.13)

if(COMMAND cmake_policy)
	cmake_policy(SET CMP0003 NEW)
	cmake_policy(SET CMP0005 NEW)
endif(COMMAND cmake_policy)

enable_language(C)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu11")
add_definitions(-D_GNU_SOURCE)

# rtsig is a build-HOST probe: it compiles and runs on the Linux build machine to
# emit rtsig.h (LINUX_SIGRTMIN/LINUX_SIGRTMAX), which the xnu emulation layer
# (emulation/emulation_dyld), the darlingserver duct-tape, and the darlingserver
# tools include via ${CMAKE_BINARY_DIR}/src/startup. It is NOT the launcher/loader
# -- those were ported to Rust (launcher + loader, tasks #64/#65) and
# deleted in task #67. rtsig.c was removed with them by mistake (it is shared
# codegen, not part of the launcher/loader), so only this target is restored here.
add_executable(rtsig rtsig.c)
add_custom_command(OUTPUT rtsig.h DEPENDS rtsig
	COMMAND ${CMAKE_CURRENT_BINARY_DIR}/rtsig rtsig.h
	COMMENT "Determining available RT signals")
add_custom_target(rtsig_h DEPENDS rtsig.h)
