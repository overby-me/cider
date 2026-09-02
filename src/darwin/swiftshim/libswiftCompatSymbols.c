/*
 * THE SYMBOLS A CURRENT BINARY ASKS FOR AND THIS RUNTIME DOES NOT HAVE.
 *
 * Each one is a name that stops dyld dead, from overlays this tree ships an older version of or does
 * not ship at all: os.Logger, System.FilePath, Network.ProxyConfiguration, SwiftUI, and the Swift
 * concurrency runtime. They live in the compat library because the loader consults it only after a
 * two level lookup has already failed, so nothing that resolves normally ever reaches them.
 *
 * THEY ARE ADDRESSES, NOT IMPLEMENTATIONS, and that distinction is the whole point: a placeholder
 * gets a process past dyld and faults at the FIRST REAL USE. The poison base makes that fault say so
 * rather than look like a wild pointer. A symbol that turns out to be called needs a real
 * implementation, and the fault address names which one.
 *
 * Generated from the measured gap: every undefined symbol across iTerm2's 31 binaries, minus what
 * the application itself defines, minus what the runtime tree and the prefix provide.
 */

#include <stdint.h>

#define CIDER_COMPAT_POISON_BASE ((uintptr_t) 0x5417C00000ull)

#define CIDER_COMPAT_SYMBOL(id, mangled)                                                           \
    __attribute__((visibility("default"))) const uintptr_t cider_compat_##id __asm__(mangled) =     \
            CIDER_COMPAT_POISON_BASE + (id) * 0x100

CIDER_COMPAT_SYMBOL(1, "_$s10Foundation17URLResourceValuesV22UniformTypeIdentifiersE07contentE0AD6UTTypeVSgvg");
CIDER_COMPAT_SYMBOL(2, "_$s10Foundation3URLV08_System_A0EyACSg0C08FilePathVcfC");
CIDER_COMPAT_SYMBOL(3, "_$s2os6LoggerV9logObjectSo03OS_a1_C0Cvg");
CIDER_COMPAT_SYMBOL(4, "_$s2os6LoggerV9subsystem8categoryACSS_SStcfC");
CIDER_COMPAT_SYMBOL(5, "_$s2os6LoggerVMa");
CIDER_COMPAT_SYMBOL(6, "_$s4Body7SwiftUI4ViewPTl");
CIDER_COMPAT_SYMBOL(7, "_$s6System8FilePathV13stringLiteralACSS_tcfC");
CIDER_COMPAT_SYMBOL(8, "_$s6System8FilePathVMa");
CIDER_COMPAT_SYMBOL(9, "_$s7Network18ProxyConfigurationV16httpCONNECTProxy10tlsOptionsAcA10NWEndpointO_AA13NWProtocolTLSC0G0CSgtcfC");
CIDER_COMPAT_SYMBOL(10, "_$s7Network18ProxyConfigurationVMa");
CIDER_COMPAT_SYMBOL(11, "_$s7Network18ProxyConfigurationVMn");
CIDER_COMPAT_SYMBOL(12, "_$s8Dispatch0A8WorkItemC5flags5blockAcA0abC5FlagsV_yyXBtcfc");
CIDER_COMPAT_SYMBOL(13, "_$sScg4next9isolationxSgScA_pSgYi_tYaKF");
CIDER_COMPAT_SYMBOL(14, "_$sScg4next9isolationxSgScA_pSgYi_tYaKFTu");
CIDER_COMPAT_SYMBOL(15, "_$sSd6Charts9PlottableAAWP");
CIDER_COMPAT_SYMBOL(16, "_$sSd7SwiftUI18_FormatSpecifiableAAWP");
CIDER_COMPAT_SYMBOL(17, "_$sSdySdSgSscfC");
CIDER_COMPAT_SYMBOL(18, "_$sSi6Charts9PlottableAAWP");
CIDER_COMPAT_SYMBOL(19, "_$sSi7SwiftUI18_FormatSpecifiableAAWP");
CIDER_COMPAT_SYMBOL(20, "_$sSo12NSFileHandleC10FoundationE4read9upToCountAC4DataVSgSi_tKF");
CIDER_COMPAT_SYMBOL(21, "_$sSo12NSFileHandleC10FoundationE5write10contentsOfyx_tKAC12DataProtocolRzlF");
CIDER_COMPAT_SYMBOL(22, "_$sSo12NSURLSessionC10FoundationE4data4from8delegateAC4DataV_So13NSURLResponseCtAC3URLV_So0A12TaskDelegate_pSgtYaKF");
CIDER_COMPAT_SYMBOL(23, "_$sSo12NSURLSessionC10FoundationE4data4from8delegateAC4DataV_So13NSURLResponseCtAC3URLV_So0A12TaskDelegate_pSgtYaKFTu");
CIDER_COMPAT_SYMBOL(24, "_$ss13withTaskGroup2of9returning9isolation4bodyq_xm_q_mScA_pSgYiq_ScGyxGzYaXEtYas8SendableRzr0_lF");
CIDER_COMPAT_SYMBOL(25, "_$ss13withTaskGroup2of9returning9isolation4bodyq_xm_q_mScA_pSgYiq_ScGyxGzYaXEtYas8SendableRzr0_lFTu");
CIDER_COMPAT_SYMBOL(26, "_$ss21withThrowingTaskGroup2of9returning9isolation4bodyq_xm_q_mScA_pSgYiq_Scgyxs5Error_pGzYaKXEtYaKs8SendableRzr0_lF");
CIDER_COMPAT_SYMBOL(27, "_$ss21withThrowingTaskGroup2of9returning9isolation4bodyq_xm_q_mScA_pSgYiq_Scgyxs5Error_pGzYaKXEtYaKs8SendableRzr0_lFTu");
CIDER_COMPAT_SYMBOL(28, "_$ss23withCheckedContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5NeverOGXEtYalF");
CIDER_COMPAT_SYMBOL(29, "_$ss23withCheckedContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5NeverOGXEtYalFTu");
CIDER_COMPAT_SYMBOL(30, "_$ss27withTaskCancellationHandler9operation8onCancel9isolationxxyYaKXE_yyYbXEScA_pSgYitYaKlF");
CIDER_COMPAT_SYMBOL(31, "_$ss27withTaskCancellationHandler9operation8onCancel9isolationxxyYaKXE_yyYbXEScA_pSgYitYaKlFTu");
CIDER_COMPAT_SYMBOL(32, "_$ss31withCheckedThrowingContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5Error_pGXEtYaKlF");
CIDER_COMPAT_SYMBOL(33, "_$ss31withCheckedThrowingContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5Error_pGXEtYaKlFTu");
CIDER_COMPAT_SYMBOL(34, "_$ss9TaskLocalC13withValueImpl_9operation9isolation4file4lineqd__xn_qd__yYaKXEScA_pSgYiSSSutYaKlF");
CIDER_COMPAT_SYMBOL(35, "_$ss9TaskLocalC13withValueImpl_9operation9isolation4file4lineqd__xn_qd__yYaKXEScA_pSgYiSSSutYaKlFTu");
CIDER_COMPAT_SYMBOL(36, "_$ss9TaskLocalC9withValue_9operation9isolation4file4lineqd__x_qd__yYaKXEScA_pSgYiSSSutYaKlF");
CIDER_COMPAT_SYMBOL(37, "_$ss9TaskLocalC9withValue_9operation9isolation4file4lineqd__x_qd__yYaKXEScA_pSgYiSSSutYaKlFTu");
CIDER_COMPAT_SYMBOL(38, "_$sxSg7SwiftUI4ViewA2bCRzlMc");
CIDER_COMPAT_SYMBOL(39, "_CAFrameRateRangeMake");
CIDER_COMPAT_SYMBOL(40, "_CFFileDescriptorCreate");
CIDER_COMPAT_SYMBOL(41, "_CFFileDescriptorCreateRunLoopSource");
CIDER_COMPAT_SYMBOL(42, "_CFFileDescriptorEnableCallBacks");
CIDER_COMPAT_SYMBOL(43, "_CFFileDescriptorGetNativeDescriptor");
CIDER_COMPAT_SYMBOL(44, "_CGColorSpaceCreateLab");
CIDER_COMPAT_SYMBOL(45, "_CGEventGetFlags");
CIDER_COMPAT_SYMBOL(46, "_CGEventSetFlags");
CIDER_COMPAT_SYMBOL(47, "_CGSessionCopyCurrentDictionary");
CIDER_COMPAT_SYMBOL(48, "_CGWindowListCopyWindowInfo");
CIDER_COMPAT_SYMBOL(49, "_CTFontManagerCreateFontDescriptorsFromURL");
CIDER_COMPAT_SYMBOL(50, "_CTFontManagerRegisterFontDescriptors");
CIDER_COMPAT_SYMBOL(51, "_CVPixelBufferCreate");
CIDER_COMPAT_SYMBOL(52, "_CVPixelBufferGetBytesPerRow");
CIDER_COMPAT_SYMBOL(53, "_CVPixelBufferGetPixelFormatType");
CIDER_COMPAT_SYMBOL(54, "_FSCopyObjectSync");
CIDER_COMPAT_SYMBOL(55, "_FSEventStreamCopyDescription");
CIDER_COMPAT_SYMBOL(56, "_FSEventStreamFlushAsync");
CIDER_COMPAT_SYMBOL(57, "_FSEventStreamFlushSync");
CIDER_COMPAT_SYMBOL(58, "_FSGetCatalogInfo");
CIDER_COMPAT_SYMBOL(59, "_GetCurrentKeyModifiers");
CIDER_COMPAT_SYMBOL(60, "_LSCanURLAcceptURL");
/* 61 was _LSSetDefaultHandlerForURLScheme, now a real function in LaunchServices: it is CALLED,
 * and a placeholder that is called is a crash rather than a missing feature. */
CIDER_COMPAT_SYMBOL(62, "_LSSetDefaultRoleHandlerForContentType");
CIDER_COMPAT_SYMBOL(63, "_NSAccessibilityRoleDescriptionForUIElement");
CIDER_COMPAT_SYMBOL(64, "_SecTrustCopyCertificateChain");
CIDER_COMPAT_SYMBOL(65, "_TISCreateInputSourceList");
CIDER_COMPAT_SYMBOL(66, "_TISSelectInputSource");
CIDER_COMPAT_SYMBOL(67, "__swift_FORCE_LOAD_$_swiftCoreMIDI");
CIDER_COMPAT_SYMBOL(68, "__swift_FORCE_LOAD_$_swiftOSLog");
CIDER_COMPAT_SYMBOL(69, "__swift_FORCE_LOAD_$_swiftQuickLookUI");
CIDER_COMPAT_SYMBOL(70, "__swift_FORCE_LOAD_$_swiftSpatial");
CIDER_COMPAT_SYMBOL(71, "__swift_FORCE_LOAD_$_swiftUniformTypeIdentifiers");
CIDER_COMPAT_SYMBOL(72, "__swift_FORCE_LOAD_$_swiftVideoToolbox");
CIDER_COMPAT_SYMBOL(73, "__swift_FORCE_LOAD_$_swift_Builtin_float");
CIDER_COMPAT_SYMBOL(74, "_memset_pattern16");
CIDER_COMPAT_SYMBOL(75, "_responsibility_spawnattrs_setdisclaim");
CIDER_COMPAT_SYMBOL(76, "_swift_coroFrameAlloc");
CIDER_COMPAT_SYMBOL(77, "_swift_isUniquelyReferenced");
CIDER_COMPAT_SYMBOL(78, "_swift_isUniquelyReferenced_nonNull");
CIDER_COMPAT_SYMBOL(79, "_swift_stdlib_isStackAllocationSafe");

const char cider_compat_symbols[] = "cider compat symbols";
