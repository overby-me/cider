#ifndef DTAPE_H
#define DTAPE_H
#include <stdint.h>
/* Stand-in for a duct-tape (XNU emulation) entry point the Rust daemon calls
 * over FFI. In the real thing this initializes Mach ports/tasks/threads. */
uint32_t dtape_init(uint32_t nthreads);
#endif
