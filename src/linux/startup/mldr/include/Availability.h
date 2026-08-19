#ifndef _MLDR_AVAILABILITY_SHIM_H_
#define _MLDR_AVAILABILITY_SHIM_H_

// A host-safe stub (aarch64 port, task A4). The arm mach/arm/vm_types.h pulls <Availability.h>
// where the i386 one does not; a host Mach-O reader has no use for Darwin's availability
// macros and must not pull the SDK's real header (which drags in the whole platform version
// apparatus). vm_types.h references none of its macros, so an empty stub is enough.

#endif // _MLDR_AVAILABILITY_SHIM_H_
