/*
 * Charts: THE SYMBOLS AN APPLICATION REACHES FOR, counted with llvm-nm rather than objdump.
 *
 * COUNTING THIS WRONG COST A ROUND OF STUBS. llvm-objdump --bind lists classic binds only, and
 * --lazy-bind adds the lazy ones, but twelve of iTerm2's thirty one binaries use CHAINED FIXUPS,
 * whose imports appear in neither. So the first count said CryptoKit needed three symbols when it
 * needs 11. llvm-nm --undefined-only reads the symbol table and sees them all.
 *
 * 52 symbol(s) here, as placeholders that name themselves when reached: each carries its id in an
 * unmappable address so a fault says WHICH one was wanted. Shape, not behaviour.
 */

#include <stdint.h>

#define CIDER_STUB_POISON_BASE ((uintptr_t) 0x57B00000ull)

#define CIDER_STUB_SYMBOL(id, mangled)                                                             \
    __attribute__((visibility("default"))) const uintptr_t cider_stub_##id __asm__(mangled) =      \
            CIDER_STUB_POISON_BASE + (id) * 0x100

CIDER_STUB_SYMBOL(1, "_$s6Charts10ChartProxyV8position4forX12CoreGraphics7CGFloatVSgx_tAA9PlottableRzlF");
CIDER_STUB_SYMBOL(2, "_$s6Charts10ChartProxyVMa");
CIDER_STUB_SYMBOL(3, "_$s6Charts10ChartProxyVMn");
CIDER_STUB_SYMBOL(4, "_$s6Charts11BuilderPairVMn");
CIDER_STUB_SYMBOL(5, "_$s6Charts11BuilderPairVyxq_GAA12ChartContentA2aERzAaER_rlMc");
CIDER_STUB_SYMBOL(6, "_$s6Charts11BuilderPairVyxq_GAA8AxisMarkA2aERzAaER_rlMc");
CIDER_STUB_SYMBOL(7, "_$s6Charts12AxisGridLineV8centered6strokeACSbSg_7SwiftUI11StrokeStyleVSgtcfC");
CIDER_STUB_SYMBOL(8, "_$s6Charts12AxisGridLineVAA0B4MarkAAWP");
CIDER_STUB_SYMBOL(9, "_$s6Charts12AxisGridLineVMa");
CIDER_STUB_SYMBOL(10, "_$s6Charts12AxisGridLineVMn");
CIDER_STUB_SYMBOL(11, "_$s6Charts12ChartContentPAAE013conformanceTobC0SVvgZ");
CIDER_STUB_SYMBOL(12, "_$s6Charts12ChartContentPAAE15foregroundStyleyQrqd__7SwiftUI05ShapeE0Rd__lF");
CIDER_STUB_SYMBOL(13, "_$s6Charts12ChartContentPAAE15foregroundStyleyQrqd__7SwiftUI05ShapeE0Rd__lFQOMQ");
CIDER_STUB_SYMBOL(14, "_$s6Charts12ChartContentPAAE9lineStyleyQr7SwiftUI06StrokeE0VF");
CIDER_STUB_SYMBOL(15, "_$s6Charts12ChartContentPAAE9lineStyleyQr7SwiftUI06StrokeE0VFQOMQ");
CIDER_STUB_SYMBOL(16, "_$s6Charts13RectangleMarkV6xStart4xEnd01yD001yE0AcA14PlottableValueVyxG_AjIyq_GAKtcAA0F0RzAaLR_r0_lufC");
CIDER_STUB_SYMBOL(17, "_$s6Charts13RectangleMarkVAA12ChartContentAAWP");
CIDER_STUB_SYMBOL(18, "_$s6Charts13RectangleMarkVMa");
CIDER_STUB_SYMBOL(19, "_$s6Charts13RectangleMarkVMn");
CIDER_STUB_SYMBOL(20, "_$s6Charts14AxisMarkPresetV9automaticACvgZ");
CIDER_STUB_SYMBOL(21, "_$s6Charts14AxisMarkPresetVMa");
CIDER_STUB_SYMBOL(22, "_$s6Charts14AxisMarkValuesV9automaticACvgZ");
CIDER_STUB_SYMBOL(23, "_$s6Charts14AxisMarkValuesVMa");
CIDER_STUB_SYMBOL(24, "_$s6Charts14AxisValueLabelV8centered6anchor05multiD9Alignment19collisionResolution12offsetsMarks11orientation17horizontalSpacing08verticalO07contentACyxGSbSg_7SwiftUI9UnitPointVSgAO0H0VSgAA0bcd9CollisionJ0VAnA0bcD11OrientationV12CoreGraphics7CGFloatVSgA1_xyXEtcfC");
CIDER_STUB_SYMBOL(25, "_$s6Charts14AxisValueLabelVMn");
CIDER_STUB_SYMBOL(26, "_$s6Charts14AxisValueLabelVyxGAA0B4MarkAAMc");
CIDER_STUB_SYMBOL(27, "_$s6Charts14PlottableValueV5valueyACyxG7SwiftUI18LocalizedStringKeyV_xtFZ");
CIDER_STUB_SYMBOL(28, "_$s6Charts14PlottableValueVMn");
CIDER_STUB_SYMBOL(29, "_$s6Charts16AxisMarkPositionV9automaticACvgZ");
CIDER_STUB_SYMBOL(30, "_$s6Charts16AxisMarkPositionVMa");
CIDER_STUB_SYMBOL(31, "_$s6Charts25AxisValueLabelOrientationV9automaticACvgZ");
CIDER_STUB_SYMBOL(32, "_$s6Charts25AxisValueLabelOrientationVMa");
CIDER_STUB_SYMBOL(33, "_$s6Charts33AxisValueLabelCollisionResolutionV9automaticACvgZ");
CIDER_STUB_SYMBOL(34, "_$s6Charts33AxisValueLabelCollisionResolutionVMa");
CIDER_STUB_SYMBOL(35, "_$s6Charts5ChartV7contentACyxGxyXE_tcfC");
CIDER_STUB_SYMBOL(36, "_$s6Charts5ChartVMn");
CIDER_STUB_SYMBOL(37, "_$s6Charts5ChartVyxG7SwiftUI4ViewAAMc");
CIDER_STUB_SYMBOL(38, "_$s6Charts8AxisMarkPAAE013conformanceTobC0SVvgZ");
CIDER_STUB_SYMBOL(39, "_$s6Charts8AxisTickV6LengthV9automaticAEvgZ");
CIDER_STUB_SYMBOL(40, "_$s6Charts8AxisTickV6LengthVMa");
CIDER_STUB_SYMBOL(41, "_$s6Charts8AxisTickV8centered6length6strokeACSbSg_AC6LengthV7SwiftUI11StrokeStyleVSgtcfC");
CIDER_STUB_SYMBOL(42, "_$s6Charts8AxisTickVAA0B4MarkAAWP");
CIDER_STUB_SYMBOL(43, "_$s6Charts8AxisTickVMa");
CIDER_STUB_SYMBOL(44, "_$s6Charts8AxisTickVMn");
CIDER_STUB_SYMBOL(45, "_$s6Charts8RuleMarkV1x6yStart4yEndAcA14PlottableValueVyxG_12CoreGraphics7CGFloatVSgAMtcAA0F0RzlufC");
CIDER_STUB_SYMBOL(46, "_$s6Charts8RuleMarkVAA12ChartContentAAWP");
CIDER_STUB_SYMBOL(47, "_$s6Charts8RuleMarkVMa");
CIDER_STUB_SYMBOL(48, "_$s6Charts8RuleMarkVMn");
CIDER_STUB_SYMBOL(49, "_$s6Charts9AxisMarksV6preset8position6values7contentACyxGAA0B10MarkPresetV_AA0bH8PositionVAA0bH6ValuesVxAA0B5ValueVctcfC");
CIDER_STUB_SYMBOL(50, "_$s6Charts9AxisMarksVMn");
CIDER_STUB_SYMBOL(51, "_$s6Charts9AxisMarksVyxGAA0B7ContentAAMc");
CIDER_STUB_SYMBOL(52, "_$s6Charts9AxisValueV2asyxSgxmAA9PlottableRzlF");

const char cider_stub_module_Charts[] = "cider stub Charts";
