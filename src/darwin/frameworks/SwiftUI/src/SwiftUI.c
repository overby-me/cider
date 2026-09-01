/*
 * A FRAMEWORK THAT EXISTS SO DYLD CAN FINISH, and nothing more than iTerm2 asks of it.
 *
 * dyld refuses to start a process whose LIBRARY is missing, whatever it does or does not use from
 * it, so an application that merely links SwiftUI cannot run without one. What iTerm2 actually
 * binds from this framework was counted with llvm-objdump across --bind, --lazy-bind and
 * --weak-bind: 99 symbols, of which 58 are bound EAGERLY and none
 * is weak, so every one of them has to exist or dyld stops the process.
 */

#include <stdint.h>

/*
 * PLACEHOLDERS THAT NAME THEMSELVES WHEN REACHED, the same device CombineSymbols.c uses and for the
 * same reason. Zero is invisible in a crash: a null metadata pointer faults at "address minus eight"
 * and every one of these looks alike. Each carries its own id in an unmappable address instead, so
 * the faulting address says WHICH symbol the application reached for first.
 *
 * These are SHAPE, not behaviour. Anything that really reads one will fail, and where it fails is
 * the measurement that says what to build next. That is exactly how the Combine work proceeded.
 */
#define CIDER_SWIFTUI_POISON_BASE ((uintptr_t) 0x5F1F00000ull)

#define CIDER_SWIFTUI_SYMBOL(id, mangled)                                                          \
    __attribute__((visibility("default"))) const uintptr_t cider_swiftui_##id __asm__(mangled) =    \
            CIDER_SWIFTUI_POISON_BASE + (id) * 0x100

CIDER_SWIFTUI_SYMBOL(1, "_$s4Body7SwiftUI4ViewPTl");
CIDER_SWIFTUI_SYMBOL(2, "_$s7SwiftUI10_ShapeViewVMn");
CIDER_SWIFTUI_SYMBOL(3, "_$s7SwiftUI11StrokeStyleVN");
CIDER_SWIFTUI_SYMBOL(4, "_$s7SwiftUI11_ClipEffectVMn");
CIDER_SWIFTUI_SYMBOL(5, "_$s7SwiftUI12_FrameLayoutVMn");
CIDER_SWIFTUI_SYMBOL(6, "_$s7SwiftUI13NSHostingViewCMn");
CIDER_SWIFTUI_SYMBOL(7, "_$s7SwiftUI13_HStackLayoutVMn");
CIDER_SWIFTUI_SYMBOL(8, "_$s7SwiftUI13_StrokedShapeVMn");
CIDER_SWIFTUI_SYMBOL(9, "_$s7SwiftUI13_VStackLayoutVMn");
CIDER_SWIFTUI_SYMBOL(10, "_$s7SwiftUI13_VariadicViewO4TreeVMn");
CIDER_SWIFTUI_SYMBOL(11, "_$s7SwiftUI14GeometryReaderVMn");
CIDER_SWIFTUI_SYMBOL(12, "_$s7SwiftUI14GeometryReaderVyxGAA4ViewAAMc");
CIDER_SWIFTUI_SYMBOL(13, "_$s7SwiftUI14_PaddingLayoutVAA12ViewModifierAAWP");
CIDER_SWIFTUI_SYMBOL(14, "_$s7SwiftUI14_PaddingLayoutVMn");
CIDER_SWIFTUI_SYMBOL(15, "_$s7SwiftUI15ModifiedContentVMn");
CIDER_SWIFTUI_SYMBOL(16, "_$s7SwiftUI15ModifiedContentVyxq_GAA4ViewA2aERzAA0E8ModifierR_rlMc");
CIDER_SWIFTUI_SYMBOL(17, "_$s7SwiftUI16RoundedRectangleVMn");
CIDER_SWIFTUI_SYMBOL(18, "_$s7SwiftUI16_OverlayModifierVMn");
CIDER_SWIFTUI_SYMBOL(19, "_$s7SwiftUI17EnvironmentValuesV15foregroundColorAA0F0VSgvg");
CIDER_SWIFTUI_SYMBOL(20, "_$s7SwiftUI17EnvironmentValuesV15foregroundColorAA0F0VSgvpMV");
CIDER_SWIFTUI_SYMBOL(21, "_$s7SwiftUI17EnvironmentValuesV4fontAA4FontVSgvg");
CIDER_SWIFTUI_SYMBOL(22, "_$s7SwiftUI17EnvironmentValuesV4fontAA4FontVSgvpMV");
CIDER_SWIFTUI_SYMBOL(23, "_$s7SwiftUI17EnvironmentValuesVMn");
CIDER_SWIFTUI_SYMBOL(24, "_$s7SwiftUI18RoundedCornerStyleO10continuousyA2CmFWC");
CIDER_SWIFTUI_SYMBOL(25, "_$s7SwiftUI19_BackgroundModifierVMn");
CIDER_SWIFTUI_SYMBOL(26, "_$s7SwiftUI19_ConditionalContentV7StorageOMn");
CIDER_SWIFTUI_SYMBOL(27, "_$s7SwiftUI19_ConditionalContentVMn");
CIDER_SWIFTUI_SYMBOL(28, "_$s7SwiftUI19_ConditionalContentVyxq_GAA4ViewA2aERzAaER_rlMc");
CIDER_SWIFTUI_SYMBOL(29, "_$s7SwiftUI24_BackgroundStyleModifierVMn");
CIDER_SWIFTUI_SYMBOL(30, "_$s7SwiftUI30_EnvironmentKeyWritingModifierVMn");
CIDER_SWIFTUI_SYMBOL(31, "_$s7SwiftUI4FontVMn");
CIDER_SWIFTUI_SYMBOL(32, "_$s7SwiftUI4TextVAA4ViewAAWP");
CIDER_SWIFTUI_SYMBOL(33, "_$s7SwiftUI4TextVMn");
CIDER_SWIFTUI_SYMBOL(34, "_$s7SwiftUI4ViewMp");
CIDER_SWIFTUI_SYMBOL(35, "_$s7SwiftUI4ViewP05_makeC04view6inputsAA01_C7OutputsVAA11_GraphValueVyxG_AA01_C6InputsVtFZTq");
CIDER_SWIFTUI_SYMBOL(36, "_$s7SwiftUI4ViewP05_makeC4List4view6inputsAA01_cE7OutputsVAA11_GraphValueVyxG_AA01_cE6InputsVtFZTq");
CIDER_SWIFTUI_SYMBOL(37, "_$s7SwiftUI4ViewP14_viewListCount6inputsSiSgAA01_ceF6InputsV_tFZTq");
CIDER_SWIFTUI_SYMBOL(38, "_$s7SwiftUI4ViewP4BodyAC_AaBTn");
CIDER_SWIFTUI_SYMBOL(39, "_$s7SwiftUI4ViewP4body4BodyQzvgTq");
CIDER_SWIFTUI_SYMBOL(40, "_$s7SwiftUI5ColorVAA10ShapeStyleAAMc");
CIDER_SWIFTUI_SYMBOL(41, "_$s7SwiftUI5ColorVMn");
CIDER_SWIFTUI_SYMBOL(42, "_$s7SwiftUI5ColorVN");
CIDER_SWIFTUI_SYMBOL(43, "_$s7SwiftUI5GroupVMn");
CIDER_SWIFTUI_SYMBOL(44, "_$s7SwiftUI5GroupVyxGAA4ViewA2aERzlMc");
CIDER_SWIFTUI_SYMBOL(45, "_$s7SwiftUI5StateVMn");
CIDER_SWIFTUI_SYMBOL(46, "_$s7SwiftUI6HStackVMn");
CIDER_SWIFTUI_SYMBOL(47, "_$s7SwiftUI6SpacerVMn");
CIDER_SWIFTUI_SYMBOL(48, "_$s7SwiftUI6VStackVMn");
CIDER_SWIFTUI_SYMBOL(49, "_$s7SwiftUI6VStackVyxGAA4ViewAAMc");
CIDER_SWIFTUI_SYMBOL(50, "_$s7SwiftUI7AnyViewVAA0D0AAWP");
CIDER_SWIFTUI_SYMBOL(51, "_$s7SwiftUI7AnyViewVMn");
CIDER_SWIFTUI_SYMBOL(52, "_$s7SwiftUI7AnyViewVN");
CIDER_SWIFTUI_SYMBOL(53, "_$s7SwiftUI7ForEachVMn");
CIDER_SWIFTUI_SYMBOL(54, "_$s7SwiftUI9EmptyViewVMn");
CIDER_SWIFTUI_SYMBOL(55, "_$s7SwiftUI9TupleViewVMn");
CIDER_SWIFTUI_SYMBOL(56, "_$sSd7SwiftUI18_FormatSpecifiableAAWP");
CIDER_SWIFTUI_SYMBOL(57, "_$sSi7SwiftUI18_FormatSpecifiableAAWP");
CIDER_SWIFTUI_SYMBOL(58, "_$sxSg7SwiftUI4ViewA2bCRzlMc");
