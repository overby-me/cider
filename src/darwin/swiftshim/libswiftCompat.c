/*
 * THE ENTRY POINTS A NEWER SWIFT EXPECTS AND THIS PREFIX'S STANDARD LIBRARY DOES NOT HAVE.
 *
 * The Swift standard library here is a prebuilt binary. Applications built for a newer macOS ask it
 * for entry points added after it was made, and a TWO LEVEL NAMESPACE means the symbol has to be in
 * THAT dylib: a shim beside it is never consulted. One missing symbol stopped two applications:
 *
 *     Symbol not found: _$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0...
 *       Referenced from: .../iTermSwiftPackages.framework          (iTerm2)
 *       Referenced from: .../Valet_..._PackageProduct              (iA Writer)
 *       Expected in: /usr/lib/swift/libswiftCore.dylib
 *
 * So the loader learned a last resort: when a two level lookup has ALREADY failed, and only then, it
 * consults one named image, CIDER_COMPAT_LIBRARY. That is not a flat namespace. It is a single
 * library whose contents are auditable, and nothing that resolves normally ever reaches it.
 *
 * Insert it with DYLD_INSERT_LIBRARIES: nothing links it, so nothing would load it otherwise.
 */

#include <stdbool.h>
#include <stddef.h>
#include <dlfcn.h>
#include <stdint.h>

/*
 * _stdlib_isOSVersionAtLeastOrVariantVersion(major, minor, patch, variantMajor, variantMinor,
 * variantPatch) -> Bool
 *
 * TRUE IS THE COHERENT ANSWER HERE, and it is a policy choice of the same kind as the AppKit version
 * constant. Both applications refuse to run at all below their own minimum macOS, so telling them
 * the system is OLDER than the version they already require would be answering a question nobody
 * asked. The variant version is the Catalyst one and is not a distinct platform here.
 */
bool cider_stdlib_is_os_version_at_least_or_variant_version(
        uintptr_t major, uintptr_t minor, uintptr_t patch,
        uintptr_t variantMajor, uintptr_t variantMinor, uintptr_t variantPatch)
        __asm__("_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF");

bool cider_stdlib_is_os_version_at_least_or_variant_version(
        uintptr_t major, uintptr_t minor, uintptr_t patch,
        uintptr_t variantMajor, uintptr_t variantMinor, uintptr_t variantPatch)
{
    (void) major;
    (void) minor;
    (void) patch;
    (void) variantMajor;
    (void) variantMinor;
    (void) variantPatch;
    return true;
}

/*
 * swift_willThrowTypedImpl(value, type, errorConformance)
 *
 * The runtime hook Swift 6 calls on the way out of a typed throw. It exists for a debugger to break
 * on, and the runtime's own version does nothing else, so doing nothing is the whole behaviour and
 * not a shortcut: the throw itself is compiled into the caller and does not depend on this at all.
 *
 * Missing, it is fatal rather than degraded, because it is called through a LAZY stub: iA Writer
 * loaded, ran, and died at the first typed throw with
 *
 *     dyld: lazy symbol binding failed: Symbol not found: _swift_willThrowTypedImpl
 */
void swift_willThrowTypedImpl(void *value, const void *type, const void *errorConformance);

void swift_willThrowTypedImpl(void *value, const void *type, const void *errorConformance)
{
    (void) value;
    (void) type;
    (void) errorConformance;
}

/*
 * swift_isUniquelyReferenced_nonNull_bridgeObject(bridgeObject) -> Bool
 *
 * THE SAME FUNCTION UNDER ITS OLDER NAME, not a stub. The runtime here exports
 * swift_isUniquelyReferencedNonObjC_nonNull_bridgeObject, which is what this was called before the
 * ObjC-aware and native variants were unified; a binary built against a newer stdlib asks for the
 * new name and dyld stops. iTerm2's BetterFontPicker, built for 12.4, does exactly that.
 *
 * dlsym rather than a link-time reference, so that the compat library keeps loading in a prefix
 * whose runtime does not have it either. FALSE IS THE SAFE ANSWER if it is missing: the caller
 * copies its buffer instead of mutating in place, which costs a copy and cannot corrupt anything.
 * Answering true would hand a caller permission to write into storage somebody else holds.
 */
bool swift_isUniquelyReferenced_nonNull_bridgeObject(uintptr_t bridgeObject);

bool swift_isUniquelyReferenced_nonNull_bridgeObject(uintptr_t bridgeObject)
{
    static bool (*real)(uintptr_t) = NULL;
    static bool looked = false;

    if (!looked) {
        looked = true;
        real = (bool (*)(uintptr_t)) dlsym(RTLD_DEFAULT,
                "swift_isUniquelyReferencedNonObjC_nonNull_bridgeObject");
    }
    return real != NULL ? real(bridgeObject) : false;
}

/*
 * swift_task_deinitOnExecutor(object, work, executor, flags)
 *
 * The entry point a Swift 5.9 compiler emits for the deinit of an actor or of an isolated class: it
 * runs the deinit body on the actor's executor rather than wherever the last release happened.
 *
 * iA Writer's main binary imports this and NOTHING in the prefix exports it, not even the
 * libswift_Concurrency it carries in its own bundle, because that copy predates the entry point.
 *
 * RUNNING THE WORK HERE IS THE RUNTIME'S OWN FAST PATH, not a shortcut: the real implementation
 * calls it directly when the caller is already on the target executor, and only enqueues otherwise.
 * What is lost is the hop, so a deinit that would have been serialised onto another actor runs on
 * the releasing thread instead. Doing nothing at all would leak every actor and skip every deinit.
 */
void swift_task_deinitOnExecutor(void *object, void (*work)(void *), void *executor,
                                 uintptr_t flags);

void swift_task_deinitOnExecutor(void *object, void (*work)(void *), void *executor,
                                 uintptr_t flags)
{
    (void) executor;
    (void) flags;
    if (work != NULL)
        work(object);
}

const char cider_swift_compat[] = "cider swift compat";

