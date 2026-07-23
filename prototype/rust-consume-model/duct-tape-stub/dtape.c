#include "dtape.h"
/* Real duct-tape wraps ~750k lines of vendored XNU (osfmk/bsd). This stub just
 * proves the separately-built-C-project -> FFI -> Rust-daemon link path. */
uint32_t dtape_init(uint32_t nthreads) {
	return nthreads * 2 + 1;
}
