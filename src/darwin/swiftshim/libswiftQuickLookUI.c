/*
 * libswiftQuickLookUI: A SWIFT OVERLAY THIS PORT DOES NOT HAVE, sized by what an application binds.
 *
 * The 44 Swift overlays in the prefix are prebuilt Apple binaries from a pin. These ten are not in
 * that pin and are not in any application bundle either, and dyld will not start a process whose
 * library is missing however little it uses. iTerm2 binds 0 symbol(s) from this one EAGERLY,
 * which is what has to exist; anything lazy only matters when it is called.
 *
 * PLACEHOLDERS THAT NAME THEMSELVES, the device CombineSymbols.c uses: zero is invisible in a crash
 * because every null looks alike, so each carries its own id in an unmappable address and the
 * faulting address says WHICH symbol was reached. These are shape, not behaviour.
 */

#include <stdint.h>

#define CIDER_SHIM_POISON_BASE ((uintptr_t) 0x5417F00000ull)

#define CIDER_SHIM_SYMBOL(id, mangled)                                                             \
    __attribute__((visibility("default"))) const uintptr_t cider_shim_##id __asm__(mangled) =      \
            CIDER_SHIM_POISON_BASE + (id) * 0x100

/* Nothing is bound eagerly: this library exists only so dyld can finish. */
const char cider_shim_libswiftQuickLookUI[] = "cider shim libswiftQuickLookUI";
