/*
 * libswiftUniformTypeIdentifiers: THE SYMBOLS AN APPLICATION REACHES FOR, counted with llvm-nm rather than objdump.
 *
 * COUNTING THIS WRONG COST A ROUND OF STUBS. llvm-objdump --bind lists classic binds only, and
 * --lazy-bind adds the lazy ones, but twelve of iTerm2's thirty one binaries use CHAINED FIXUPS,
 * whose imports appear in neither. So the first count said CryptoKit needed three symbols when it
 * needs 11. llvm-nm --undefined-only reads the symbol table and sees them all.
 *
 * 17 symbol(s) here, as placeholders that name themselves when reached: each carries its id in an
 * unmappable address so a fault says WHICH one was wanted. Shape, not behaviour.
 */

#include <stdint.h>

#define CIDER_STUB_POISON_BASE ((uintptr_t) 0x57B00000ull)

#define CIDER_STUB_SYMBOL(id, mangled)                                                             \
    __attribute__((visibility("default"))) const uintptr_t cider_stub_##id __asm__(mangled) =      \
            CIDER_STUB_POISON_BASE + (id) * 0x100

CIDER_STUB_SYMBOL(1, "_$s22UniformTypeIdentifiers6UTTypeV04mimeB012conformingToACSgSS_ACtcfC");
CIDER_STUB_SYMBOL(2, "_$s22UniformTypeIdentifiers6UTTypeV11applicationACvgZ");
CIDER_STUB_SYMBOL(3, "_$s22UniformTypeIdentifiers6UTTypeV13utf8PlainTextACvgZ");
CIDER_STUB_SYMBOL(4, "_$s22UniformTypeIdentifiers6UTTypeV14unixExecutableACvgZ");
CIDER_STUB_SYMBOL(5, "_$s22UniformTypeIdentifiers6UTTypeV17applicationBundleACvgZ");
CIDER_STUB_SYMBOL(6, "_$s22UniformTypeIdentifiers6UTTypeV17filenameExtension12conformingToACSgSS_ACtcfC");
CIDER_STUB_SYMBOL(7, "_$s22UniformTypeIdentifiers6UTTypeV17preferredMIMETypeSSSgvg");
CIDER_STUB_SYMBOL(8, "_$s22UniformTypeIdentifiers6UTTypeV19_bridgeToObjectiveCSoABCyF");
CIDER_STUB_SYMBOL(9, "_$s22UniformTypeIdentifiers6UTTypeV3rtfACvgZ");
CIDER_STUB_SYMBOL(10, "_$s22UniformTypeIdentifiers6UTTypeV4dataACvgZ");
CIDER_STUB_SYMBOL(11, "_$s22UniformTypeIdentifiers6UTTypeV6bundleACvgZ");
CIDER_STUB_SYMBOL(12, "_$s22UniformTypeIdentifiers6UTTypeV6folderACvgZ");
CIDER_STUB_SYMBOL(13, "_$s22UniformTypeIdentifiers6UTTypeV8conforms2toSbAC_tF");
CIDER_STUB_SYMBOL(14, "_$s22UniformTypeIdentifiers6UTTypeV9plainTextACvgZ");
CIDER_STUB_SYMBOL(15, "_$s22UniformTypeIdentifiers6UTTypeVMa");
CIDER_STUB_SYMBOL(16, "_$s22UniformTypeIdentifiers6UTTypeVMn");
CIDER_STUB_SYMBOL(17, "_$s22UniformTypeIdentifiers6UTTypeVyACSgSScfC");

const char cider_stub_module_libswiftUniformTypeIdentifiers[] = "cider stub libswiftUniformTypeIdentifiers";
