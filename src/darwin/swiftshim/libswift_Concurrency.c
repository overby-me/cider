/*
 * libswift_Concurrency: A SWIFT OVERLAY THIS PORT DOES NOT HAVE, sized by what an application binds.
 *
 * The 44 Swift overlays in the prefix are prebuilt Apple binaries from a pin. These ten are not in
 * that pin and are not in any application bundle either, and dyld will not start a process whose
 * library is missing however little it uses. iTerm2 binds 19 symbol(s) from this one EAGERLY,
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

CIDER_SHIM_SYMBOL(1, "_$sScA15unownedExecutorScevgTq");
CIDER_SHIM_SYMBOL(2, "_$sScAMp");
CIDER_SHIM_SYMBOL(3, "_$sScEMa");
CIDER_SHIM_SYMBOL(4, "_$sScEs5ErrorsMc");
CIDER_SHIM_SYMBOL(5, "_$sScG22awaitAllRemainingTasksyyYaFTu");
CIDER_SHIM_SYMBOL(6, "_$sScMMa");
CIDER_SHIM_SYMBOL(7, "_$sScMScAsMc");
CIDER_SHIM_SYMBOL(8, "_$sScT5valuexvgTu");
CIDER_SHIM_SYMBOL(9, "_$sScTss5NeverORszABRs_rlE5sleep11nanosecondsys6UInt64V_tYaKFZTu");
CIDER_SHIM_SYMBOL(10, "_$sScg22awaitAllRemainingTasksyyYaFTu");
CIDER_SHIM_SYMBOL(11, "_$sScs12ContinuationV11YieldResultOMn");
CIDER_SHIM_SYMBOL(12, "_$sScs12ContinuationV15BufferingPolicyO9unboundedyADyxq___GAFms5ErrorR_r0_lFWC");
CIDER_SHIM_SYMBOL(13, "_$sScs12ContinuationV15BufferingPolicyOMn");
CIDER_SHIM_SYMBOL(14, "_$sScs12ContinuationVMn");
CIDER_SHIM_SYMBOL(15, "_$sScs8IteratorV4nextxSgyYaKFTu");
CIDER_SHIM_SYMBOL(16, "_$sScs8IteratorVMn");
CIDER_SHIM_SYMBOL(17, "_$ss9TaskLocalCMn");
CIDER_SHIM_SYMBOL(18, "_$ss9TaskLocalCMo");
CIDER_SHIM_SYMBOL(19, "_swift_deletedAsyncMethodErrorTu");
const char cider_shim_libswift_Concurrency[] = "cider shim libswift_Concurrency";

/*
 * THIS SHIM IS NOT BUILT, and the file is kept only to say why.
 *
 * A stub can stand in for a framework whose symbols an application merely REFERENCES. It cannot
 * stand in for a runtime library whose functions are CALLED: libswift_Concurrency implements actors,
 * and swift_defaultActor_initialize runs every time one is created. Mapping this shim into the
 * prefix shadowed the REAL copy that iA Writer ships inside its own bundle, and turned a working
 * launch into
 *
 *     dyld: Symbol not found: _swift_defaultActor_initialize
 *       Referenced from: .../AccountCore.framework
 *       Expected in: /usr/lib/swift/libswift_Concurrency.dylib
 *
 * iTerm2 needs a real one too. The answer is a real Swift concurrency runtime in the prefix, not a
 * stub, and until there is one this file stays out of the build.
 */
