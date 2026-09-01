/*
 * CryptoKit: THE SYMBOLS AN APPLICATION REACHES FOR, counted with llvm-nm rather than objdump.
 *
 * COUNTING THIS WRONG COST A ROUND OF STUBS. llvm-objdump --bind lists classic binds only, and
 * --lazy-bind adds the lazy ones, but twelve of iTerm2's thirty one binaries use CHAINED FIXUPS,
 * whose imports appear in neither. So the first count said CryptoKit needed three symbols when it
 * needs 11. llvm-nm --undefined-only reads the symbol table and sees them all.
 *
 * 8 symbol(s) here, as placeholders that name themselves when reached: each carries its id in an
 * unmappable address so a fault says WHICH one was wanted. Shape, not behaviour.
 */

#include <stdint.h>

#define CIDER_STUB_POISON_BASE ((uintptr_t) 0x57B00000ull)

#define CIDER_STUB_SYMBOL(id, mangled)                                                             \
    __attribute__((visibility("default"))) const uintptr_t cider_stub_##id __asm__(mangled) =      \
            CIDER_STUB_POISON_BASE + (id) * 0x100

CIDER_STUB_SYMBOL(1, "_$s9CryptoKit12HashFunctionP6update13bufferPointerySW_tFTj");
CIDER_STUB_SYMBOL(2, "_$s9CryptoKit12HashFunctionP8finalize6DigestQzyFTj");
CIDER_STUB_SYMBOL(3, "_$s9CryptoKit12HashFunctionPxycfCTj");
CIDER_STUB_SYMBOL(4, "_$s9CryptoKit12SHA256DigestVMa");
CIDER_STUB_SYMBOL(5, "_$s9CryptoKit12SHA256DigestVMn");
CIDER_STUB_SYMBOL(6, "_$s9CryptoKit12SHA256DigestVSTAAMc");
CIDER_STUB_SYMBOL(7, "_$s9CryptoKit6SHA256VAA12HashFunctionAAMc");
CIDER_STUB_SYMBOL(8, "_$s9CryptoKit6SHA256VMa");

const char cider_stub_module_CryptoKit[] = "cider stub CryptoKit";
