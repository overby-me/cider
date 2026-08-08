/* bindgen entry point for darlingserver.
 *
 * TWO SURFACES, one generated file, because rust_library takes a single out_dir.
 *
 * (1) THE HOOKS CONTRACT. The 36-field callback vtable the daemon implements, plus its
 * types. hooks.h is a self-contained SOURCE header -- it pulls only duct-tape/types.h
 * (stdint/stdbool) and libsimple/lock.h -- so this half needs no build, just two source
 * include dirs.
 *
 * (2) THE INTERNAL STRUCTS THE PORTED GLUE NEEDS (#71). duct-tape glue files are moving to
 * Rust one at a time, and they manipulate duct-tape's own structs: semaphore.c walks
 * owning_task->xnu_task, so Rust needs the offset of xnu_task inside struct dtape_task,
 * which embeds the whole XNU struct task. Generating that is the entire point -- an offset
 * transcribed by hand is an offset that drifts silently the next time the struct gains a
 * field.
 *
 * This half is NOT self-contained, and that is why it was left out until now. It reaches
 * internal-include, the XNU header roots, and two GENERATED trees: darlingserver/rpc.h
 * (the RPC wrapper generator, via duct-tape.h's DSERVER_DTAPE_DECLS) and the MIG output for
 * mach/task.h, where semaphore_create and semaphore_destroy are actually declared -- XNU's
 * kern/sync_sema.h declares only semaphore_destroy_all. linux/server/BUCK wires all of them
 * as include_dirs; build.rs mirrors it for the cargo path.
 *
 * The XNU giants (task, thread, ipc_*, vm_*, lck_*, ...) are marked opaque, so only their
 * SIZE crosses. Measured: that keeps the added surface to 21 items and about 3 KB, and the
 * pre-existing 62 items come out byte for byte identical apart from dtape_semaphore itself,
 * which is the point -- it was an empty placeholder before and is now the real struct.
 */
#include <darlingserver/duct-tape/hooks.h>

/* (2) internal structs + the XNU entry points the ported glue calls.
 *
 * task.h is listed even though semaphore.h already names dtape_task_t, because it only
 * FORWARD-DECLARES it: without this line dtape_task binds as an opaque [u8; 0] and the
 * xnu_task offset -- the one thing this half exists to provide -- is not there at all.
 */
#include <darlingserver/duct-tape/semaphore.h>
#include <darlingserver/duct-tape/task.h>
/* condvar.c walks back from a queue link to the containing dtape_thread, so the port needs
 * the offsets of mutex_link and of the embedded XNU thread. */
#include <darlingserver/duct-tape/thread.h>
#include <darlingserver/duct-tape/condvar.h>
#include <mach/task.h>
#include <mach/semaphore.h>
