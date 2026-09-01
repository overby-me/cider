/*
 * FoundationModels: THE SYMBOLS AN APPLICATION REACHES FOR, counted with llvm-nm rather than objdump.
 *
 * COUNTING THIS WRONG COST A ROUND OF STUBS. llvm-objdump --bind lists classic binds only, and
 * --lazy-bind adds the lazy ones, but twelve of iTerm2's thirty one binaries use CHAINED FIXUPS,
 * whose imports appear in neither. So the first count said CryptoKit needed three symbols when it
 * needs 11. llvm-nm --undefined-only reads the symbol table and sees them all.
 *
 * 18 symbol(s) here, as placeholders that name themselves when reached: each carries its id in an
 * unmappable address so a fault says WHICH one was wanted. Shape, not behaviour.
 */

#include <stdint.h>

#define CIDER_STUB_POISON_BASE ((uintptr_t) 0x57B00000ull)

#define CIDER_STUB_SYMBOL(id, mangled)                                                             \
    __attribute__((visibility("default"))) const uintptr_t cider_stub_##id __asm__(mangled) =      \
            CIDER_STUB_POISON_BASE + (id) * 0x100

CIDER_STUB_SYMBOL(1, "_$s16FoundationModels17GenerationOptionsV12SamplingModeVMa");
CIDER_STUB_SYMBOL(2, "_$s16FoundationModels17GenerationOptionsV12SamplingModeVMn");
CIDER_STUB_SYMBOL(3, "_$s16FoundationModels17GenerationOptionsV8sampling11temperature21maximumResponseTokensA2C12SamplingModeVSg_SdSgSiSgtcfC");
CIDER_STUB_SYMBOL(4, "_$s16FoundationModels17GenerationOptionsVMa");
CIDER_STUB_SYMBOL(5, "_$s16FoundationModels19SystemLanguageModelC12AvailabilityO17UnavailableReasonO13modelNotReadyyA2GmFWC");
CIDER_STUB_SYMBOL(6, "_$s16FoundationModels19SystemLanguageModelC12AvailabilityO17UnavailableReasonO17deviceNotEligibleyA2GmFWC");
CIDER_STUB_SYMBOL(7, "_$s16FoundationModels19SystemLanguageModelC12AvailabilityO17UnavailableReasonO27appleIntelligenceNotEnabledyA2GmFWC");
CIDER_STUB_SYMBOL(8, "_$s16FoundationModels19SystemLanguageModelC12AvailabilityO17UnavailableReasonOMa");
CIDER_STUB_SYMBOL(9, "_$s16FoundationModels19SystemLanguageModelC12AvailabilityOMa");
CIDER_STUB_SYMBOL(10, "_$s16FoundationModels19SystemLanguageModelC12availabilityAC12AvailabilityOvg");
CIDER_STUB_SYMBOL(11, "_$s16FoundationModels19SystemLanguageModelC7defaultACvgZ");
CIDER_STUB_SYMBOL(12, "_$s16FoundationModels19SystemLanguageModelCMa");
CIDER_STUB_SYMBOL(13, "_$s16FoundationModels20LanguageModelSessionC5model5tools12instructionsAcA06SystemcD0C_SayAA4Tool_pGSSSgtcfC");
CIDER_STUB_SYMBOL(14, "_$s16FoundationModels20LanguageModelSessionC7respond2to7optionsAC8ResponseVy_SSGSS_AA17GenerationOptionsVtYaKF");
CIDER_STUB_SYMBOL(15, "_$s16FoundationModels20LanguageModelSessionC7respond2to7optionsAC8ResponseVy_SSGSS_AA17GenerationOptionsVtYaKFTu");
CIDER_STUB_SYMBOL(16, "_$s16FoundationModels20LanguageModelSessionC8ResponseV7contentxvg");
CIDER_STUB_SYMBOL(17, "_$s16FoundationModels20LanguageModelSessionC8ResponseVMn");
CIDER_STUB_SYMBOL(18, "_$s16FoundationModels20LanguageModelSessionCMa");

const char cider_stub_module_FoundationModels[] = "cider stub FoundationModels";
