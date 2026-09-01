/*
 * SwiftUI: THE SYMBOLS AN APPLICATION REACHES FOR, counted with llvm-nm rather than objdump.
 *
 * COUNTING THIS WRONG COST A ROUND OF STUBS. llvm-objdump --bind lists classic binds only, and
 * --lazy-bind adds the lazy ones, but twelve of iTerm2's thirty one binaries use CHAINED FIXUPS,
 * whose imports appear in neither. So the first count said CryptoKit needed three symbols when it
 * needs 11. llvm-nm --undefined-only reads the symbol table and sees them all.
 *
 * 101 symbol(s) here, as placeholders that name themselves when reached: each carries its id in an
 * unmappable address so a fault says WHICH one was wanted. Shape, not behaviour.
 */

#include <stdint.h>

#define CIDER_STUB_POISON_BASE ((uintptr_t) 0x57B00000ull)

#define CIDER_STUB_SYMBOL(id, mangled)                                                             \
    __attribute__((visibility("default"))) const uintptr_t cider_stub_##id __asm__(mangled) =      \
            CIDER_STUB_POISON_BASE + (id) * 0x100

CIDER_STUB_SYMBOL(1, "_$s7SwiftUI10EdgeInsetsV4_allAC12CoreGraphics7CGFloatV_tcfC");
CIDER_STUB_SYMBOL(2, "_$s7SwiftUI10_ShapeViewVMn");
CIDER_STUB_SYMBOL(3, "_$s7SwiftUI11StrokeStyleV9lineWidth0E3Cap0E4Join10miterLimit4dash0K5PhaseAC12CoreGraphics7CGFloatV_So06CGLineG0VSo0pH0VALSayALGALtcfC");
CIDER_STUB_SYMBOL(4, "_$s7SwiftUI11StrokeStyleVN");
CIDER_STUB_SYMBOL(5, "_$s7SwiftUI11_ClipEffectVMn");
CIDER_STUB_SYMBOL(6, "_$s7SwiftUI12_FrameLayoutV5width6height9alignmentAC12CoreGraphics7CGFloatVSg_AjA9AlignmentVtcfC");
CIDER_STUB_SYMBOL(7, "_$s7SwiftUI12_FrameLayoutVMn");
CIDER_STUB_SYMBOL(8, "_$s7SwiftUI13GeometryProxyV4sizeSo6CGSizeVvg");
CIDER_STUB_SYMBOL(9, "_$s7SwiftUI13NSHostingViewC04rootD0ACyxGx_tcfc");
CIDER_STUB_SYMBOL(10, "_$s7SwiftUI13NSHostingViewCMn");
CIDER_STUB_SYMBOL(11, "_$s7SwiftUI13_HStackLayoutVMn");
CIDER_STUB_SYMBOL(12, "_$s7SwiftUI13_StrokedShapeVMn");
CIDER_STUB_SYMBOL(13, "_$s7SwiftUI13_VStackLayoutVMn");
CIDER_STUB_SYMBOL(14, "_$s7SwiftUI13_VariadicViewO4TreeVMn");
CIDER_STUB_SYMBOL(15, "_$s7SwiftUI14GeometryReaderVMn");
CIDER_STUB_SYMBOL(16, "_$s7SwiftUI14GeometryReaderVyxGAA4ViewAAMc");
CIDER_STUB_SYMBOL(17, "_$s7SwiftUI14_PaddingLayoutVAA12ViewModifierAAWP");
CIDER_STUB_SYMBOL(18, "_$s7SwiftUI14_PaddingLayoutVMn");
CIDER_STUB_SYMBOL(19, "_$s7SwiftUI15ModifiedContentVMn");
CIDER_STUB_SYMBOL(20, "_$s7SwiftUI15ModifiedContentVyxq_GAA4ViewA2aERzAA0E8ModifierR_rlMc");
CIDER_STUB_SYMBOL(21, "_$s7SwiftUI15StrokeShapeViewVMn");
CIDER_STUB_SYMBOL(22, "_$s7SwiftUI16RoundedRectangleVMa");
CIDER_STUB_SYMBOL(23, "_$s7SwiftUI16RoundedRectangleVMn");
CIDER_STUB_SYMBOL(24, "_$s7SwiftUI16_OverlayModifierVMn");
CIDER_STUB_SYMBOL(25, "_$s7SwiftUI17EnvironmentValuesV15foregroundColorAA0F0VSgvg");
CIDER_STUB_SYMBOL(26, "_$s7SwiftUI17EnvironmentValuesV15foregroundColorAA0F0VSgvpMV");
CIDER_STUB_SYMBOL(27, "_$s7SwiftUI17EnvironmentValuesV15foregroundColorAA0F0VSgvs");
CIDER_STUB_SYMBOL(28, "_$s7SwiftUI17EnvironmentValuesV4fontAA4FontVSgvg");
CIDER_STUB_SYMBOL(29, "_$s7SwiftUI17EnvironmentValuesV4fontAA4FontVSgvpMV");
CIDER_STUB_SYMBOL(30, "_$s7SwiftUI17EnvironmentValuesV4fontAA4FontVSgvs");
CIDER_STUB_SYMBOL(31, "_$s7SwiftUI17EnvironmentValuesVMn");
CIDER_STUB_SYMBOL(32, "_$s7SwiftUI17VerticalAlignmentV6centerACvgZ");
CIDER_STUB_SYMBOL(33, "_$s7SwiftUI18LocalizedStringKeyV0D13InterpolationV06appendF0_9specifieryx_SStAA18_FormatSpecifiableRzlF");
CIDER_STUB_SYMBOL(34, "_$s7SwiftUI18LocalizedStringKeyV0D13InterpolationV13appendLiteralyySSF");
CIDER_STUB_SYMBOL(35, "_$s7SwiftUI18LocalizedStringKeyV0D13InterpolationV15literalCapacity18interpolationCountAESi_SitcfC");
CIDER_STUB_SYMBOL(36, "_$s7SwiftUI18LocalizedStringKeyV0D13InterpolationVMa");
CIDER_STUB_SYMBOL(37, "_$s7SwiftUI18LocalizedStringKeyV13stringLiteralACSS_tcfC");
CIDER_STUB_SYMBOL(38, "_$s7SwiftUI18LocalizedStringKeyV19stringInterpolationA2C0dG0V_tcfC");
CIDER_STUB_SYMBOL(39, "_$s7SwiftUI18RoundedCornerStyleO10continuousyA2CmFWC");
CIDER_STUB_SYMBOL(40, "_$s7SwiftUI18RoundedCornerStyleOMa");
CIDER_STUB_SYMBOL(41, "_$s7SwiftUI19HorizontalAlignmentV6centerACvgZ");
CIDER_STUB_SYMBOL(42, "_$s7SwiftUI19HorizontalAlignmentV7leadingACvgZ");
CIDER_STUB_SYMBOL(43, "_$s7SwiftUI19_BackgroundModifierVMn");
CIDER_STUB_SYMBOL(44, "_$s7SwiftUI19_ConditionalContentV7StorageOMn");
CIDER_STUB_SYMBOL(45, "_$s7SwiftUI19_ConditionalContentVA2A4ViewRzAaDR_rlE7storageACyxq_GAC7StorageOyxq__G_tcfC");
CIDER_STUB_SYMBOL(46, "_$s7SwiftUI19_ConditionalContentVMn");
CIDER_STUB_SYMBOL(47, "_$s7SwiftUI19_ConditionalContentVyxq_GAA4ViewA2aERzAaER_rlMc");
CIDER_STUB_SYMBOL(48, "_$s7SwiftUI24_BackgroundStyleModifierVMn");
CIDER_STUB_SYMBOL(49, "_$s7SwiftUI30_EnvironmentKeyWritingModifierVMn");
CIDER_STUB_SYMBOL(50, "_$s7SwiftUI4EdgeO3SetV3allAEvgZ");
CIDER_STUB_SYMBOL(51, "_$s7SwiftUI4EdgeO3SetV3topAEvgZ");
CIDER_STUB_SYMBOL(52, "_$s7SwiftUI4FontV7captionACvgZ");
CIDER_STUB_SYMBOL(53, "_$s7SwiftUI4FontVMn");
CIDER_STUB_SYMBOL(54, "_$s7SwiftUI4TextVAA4ViewAAWP");
CIDER_STUB_SYMBOL(55, "_$s7SwiftUI4TextVMn");
CIDER_STUB_SYMBOL(56, "_$s7SwiftUI4TextV_9tableName6bundle7commentAcA18LocalizedStringKeyV_SSSgSo8NSBundleCSgs06StaticI0VSgtcfC");
CIDER_STUB_SYMBOL(57, "_$s7SwiftUI4ViewMp");
CIDER_STUB_SYMBOL(58, "_$s7SwiftUI4ViewP05_makeC04view6inputsAA01_C7OutputsVAA11_GraphValueVyxG_AA01_C6InputsVtFZTq");
CIDER_STUB_SYMBOL(59, "_$s7SwiftUI4ViewP05_makeC4List4view6inputsAA01_cE7OutputsVAA11_GraphValueVyxG_AA01_cE6InputsVtFZTq");
CIDER_STUB_SYMBOL(60, "_$s7SwiftUI4ViewP14_viewListCount6inputsSiSgAA01_ceF6InputsV_tFZTq");
CIDER_STUB_SYMBOL(61, "_$s7SwiftUI4ViewP4BodyAC_AaBTn");
CIDER_STUB_SYMBOL(62, "_$s7SwiftUI4ViewP4body4BodyQzvgTq");
CIDER_STUB_SYMBOL(63, "_$s7SwiftUI4ViewP6ChartsE10chartXAxis7contentQrqd__yXE_tAD11AxisContentRd__lF");
CIDER_STUB_SYMBOL(64, "_$s7SwiftUI4ViewP6ChartsE10chartXAxis7contentQrqd__yXE_tAD11AxisContentRd__lFQOMQ");
CIDER_STUB_SYMBOL(65, "_$s7SwiftUI4ViewP6ChartsE12chartOverlay9alignment7contentQrAA9AlignmentV_qd__AD10ChartProxyVctAaBRd__lF");
CIDER_STUB_SYMBOL(66, "_$s7SwiftUI4ViewP6ChartsE12chartOverlay9alignment7contentQrAA9AlignmentV_qd__AD10ChartProxyVctAaBRd__lFQOMQ");
CIDER_STUB_SYMBOL(67, "_$s7SwiftUI4ViewP6ChartsE15chartXSelection5valueQrAA7BindingVyqd__SgG_tAD9PlottableRd__lF");
CIDER_STUB_SYMBOL(68, "_$s7SwiftUI4ViewP6ChartsE15chartXSelection5valueQrAA7BindingVyqd__SgG_tAD9PlottableRd__lFQOMQ");
CIDER_STUB_SYMBOL(69, "_$s7SwiftUI4ViewPAAE05_makeC04view6inputsAA01_C7OutputsVAA11_GraphValueVyxG_AA01_C6InputsVtFZ");
CIDER_STUB_SYMBOL(70, "_$s7SwiftUI4ViewPAAE05_makeC4List4view6inputsAA01_cE7OutputsVAA11_GraphValueVyxG_AA01_cE6InputsVtFZ");
CIDER_STUB_SYMBOL(71, "_$s7SwiftUI4ViewPAAE14_viewListCount6inputsSiSgAA01_ceF6InputsV_tFZ");
CIDER_STUB_SYMBOL(72, "_$s7SwiftUI5ColorV3redACvgZ");
CIDER_STUB_SYMBOL(73, "_$s7SwiftUI5ColorV4blueACvgZ");
CIDER_STUB_SYMBOL(74, "_$s7SwiftUI5ColorV6purpleACvgZ");
CIDER_STUB_SYMBOL(75, "_$s7SwiftUI5ColorV7opacityyACSdF");
CIDER_STUB_SYMBOL(76, "_$s7SwiftUI5ColorVAA10ShapeStyleAAMc");
CIDER_STUB_SYMBOL(77, "_$s7SwiftUI5ColorVMn");
CIDER_STUB_SYMBOL(78, "_$s7SwiftUI5ColorVN");
CIDER_STUB_SYMBOL(79, "_$s7SwiftUI5ColorVyACSo7NSColorCcfC");
CIDER_STUB_SYMBOL(80, "_$s7SwiftUI5GroupVMn");
CIDER_STUB_SYMBOL(81, "_$s7SwiftUI5GroupVyxGAA4ViewA2aERzlMc");
CIDER_STUB_SYMBOL(82, "_$s7SwiftUI5StateV12wrappedValueACyxGx_tcfC");
CIDER_STUB_SYMBOL(83, "_$s7SwiftUI5StateV12wrappedValuexvg");
CIDER_STUB_SYMBOL(84, "_$s7SwiftUI5StateV12wrappedValuexvs");
CIDER_STUB_SYMBOL(85, "_$s7SwiftUI5StateVMn");
CIDER_STUB_SYMBOL(86, "_$s7SwiftUI6HStackVMn");
CIDER_STUB_SYMBOL(87, "_$s7SwiftUI6SpacerVMn");
CIDER_STUB_SYMBOL(88, "_$s7SwiftUI6VStackVMn");
CIDER_STUB_SYMBOL(89, "_$s7SwiftUI6VStackVyxGAA4ViewAAMc");
CIDER_STUB_SYMBOL(90, "_$s7SwiftUI7AnyViewVAA0D0AAWP");
CIDER_STUB_SYMBOL(91, "_$s7SwiftUI7AnyViewVMn");
CIDER_STUB_SYMBOL(92, "_$s7SwiftUI7AnyViewVN");
CIDER_STUB_SYMBOL(93, "_$s7SwiftUI7AnyViewVyACxcAA0D0RzlufC");
CIDER_STUB_SYMBOL(94, "_$s7SwiftUI7BindingV3get3setACyxGxyc_yxctcfC");
CIDER_STUB_SYMBOL(95, "_$s7SwiftUI7ForEachV6ChartsAD12ChartContentR0_rlE_2id7contentACyxq_q0_Gx_s7KeyPathCy7ElementQzq_Gq0_ALctcfC");
CIDER_STUB_SYMBOL(96, "_$s7SwiftUI7ForEachVMn");
CIDER_STUB_SYMBOL(97, "_$s7SwiftUI7ForEachVyxq_q0_G6Charts12ChartContentA2eFR0_rlMc");
CIDER_STUB_SYMBOL(98, "_$s7SwiftUI9AlignmentV3topACvgZ");
CIDER_STUB_SYMBOL(99, "_$s7SwiftUI9AlignmentV6centerACvgZ");
CIDER_STUB_SYMBOL(100, "_$s7SwiftUI9EmptyViewVMn");
CIDER_STUB_SYMBOL(101, "_$s7SwiftUI9TupleViewVMn");

const char cider_stub_module_SwiftUI[] = "cider stub SwiftUI";
