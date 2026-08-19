#ifndef _MLDR_ARM__TYPES_SHIM_H_
#define _MLDR_ARM__TYPES_SHIM_H_

// The arm twin of i386/_types.h (aarch64 port, task A4). A host (Linux) compile that reads
// <mach-o/loader.h> on arm64 dispatches through mach/arm/vm_types.h to <arm/_types.h>, and
// the SDK's real one would drag Darwin's type surface in on top of glibc's. One typedef is
// the whole of what such a compile is allowed to see.
typedef unsigned int __darwin_natural_t;

#endif // _MLDR_ARM__TYPES_SHIM_H_
