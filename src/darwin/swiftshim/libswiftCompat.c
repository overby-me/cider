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

const char cider_swift_compat[] = "cider swift compat";
