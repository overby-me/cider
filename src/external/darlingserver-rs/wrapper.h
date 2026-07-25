/* bindgen entry point for darlingserver-rs.
 *
 * The dtape hooks contract (the 36-field callback vtable the daemon implements)
 * plus its types are self-contained SOURCE headers -- hooks.h pulls only
 * duct-tape/types.h (stdint/stdbool) and libsimple/lock.h. So bindgen needs no
 * build, just the two source include dirs (wired in build.rs):
 *   src/external/darlingserver/duct-tape/include
 *   src/libsimple/include
 *
 * duct-tape.h itself is intentionally NOT included here: it uses the generated
 * DSERVER_DTAPE_DECLS macro (from the RPC-wrapper generator), so we hand-declare
 * the handful of dtape_* entry points the daemon calls (see src/main.rs) rather
 * than drag the whole generated-header tree into bindgen.
 */
#include <darlingserver/duct-tape/hooks.h>
