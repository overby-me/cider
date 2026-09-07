#include <CoreFoundation/CoreFoundation.h>

const CFStringRef kCVImageBufferPixelAspectRatioKey = CFSTR("CVPixelAspectRatio");
const CFStringRef kCVImageBufferGammaLevelKey = CFSTR("CVImageBufferGammaLevel");
const CFStringRef kCVImageBufferYCbCrMatrixKey = CFSTR("CVImageBufferYCbCrMatrix");
const CFStringRef kCVImageBufferColorPrimariesKey = CFSTR("CVImageBufferColorPrimaries");
const CFStringRef kCVImageBufferTransferFunctionKey = CFSTR("CVImageBufferTransferFunction");
const CFStringRef kCVImageBufferChromaLocationBottomFieldKey = CFSTR("CVImageBufferChromaLocationBottomField");
const CFStringRef kCVImageBufferChromaLocationTopFieldKey = CFSTR("CVImageBufferChromaLocationTopField");

// These two are the SPACING KEYS INSIDE the pixel aspect ratio dictionary, so macOS names them by
// the short form and not by the outer key. Ours carried the long name and would not have matched a
// dictionary any real framework built.
const CFStringRef kCVImageBufferPixelAspectRatioHorizontalSpacingKey = CFSTR("HorizontalSpacing");
const CFStringRef kCVImageBufferPixelAspectRatioVerticalSpacingKey = CFSTR("VerticalSpacing");

const CFStringRef kCVImageBufferYCbCrMatrix_ITU_R_709_2 = CFSTR("ITU_R_709_2");
const CFStringRef kCVImageBufferYCbCrMatrix_ITU_R_601_4 = CFSTR("ITU_R_601_4");
const CFStringRef kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 = CFSTR("SMPTE_240M_1995");

const CFStringRef kCVImageBufferColorPrimaries_ITU_R_709_2 = CFSTR("ITU_R_709_2");
const CFStringRef kCVImageBufferColorPrimaries_EBU_3213 = CFSTR("EBU_3213");
const CFStringRef kCVImageBufferColorPrimaries_SMPTE_C = CFSTR("SMPTE_C");

const CFStringRef kCVImageBufferTransferFunction_ITU_R_709_2 = CFSTR("ITU_R_709_2");
const CFStringRef kCVImageBufferTransferFunction_SMPTE_240M_1995 = CFSTR("SMPTE_240M_1995");
const CFStringRef kCVImageBufferTransferFunction_UseGamma = CFSTR("UseGamma");

const CFStringRef kCVImageBufferChromaLocation_Left = CFSTR("Left");

const CFStringRef kCVPixelBufferIOSurfacePropertiesKey = CFSTR("IOSurfaceProperties");
const CFStringRef kCVPixelBufferOpenGLCompatibilityKey = CFSTR("OpenGLCompatibility");
const CFStringRef kCVPixelBufferPixelFormatTypeKey = CFSTR("PixelFormatType");
const CFStringRef kCVPixelBufferMetalCompatibilityKey = CFSTR("MetalCompatibility");
const CFStringRef kCVPixelBufferBytesPerRowAlignmentKey = CFSTR("BytesPerRowAlignment");
const CFStringRef kCVPixelBufferHeightKey = CFSTR("Height");
const CFStringRef kCVPixelBufferWidthKey = CFSTR("Width");

/* THE CG COMPATIBILITY KEYS. A caller puts these in the attributes dictionary of a pixel buffer
 * pool to say the buffers must be usable as a CGImage or as the backing of a CGBitmapContext. The
 * VALUES are the ones macOS uses, since a dictionary key that differs by a character is a request
 * that is silently ignored. Their symbols stop a modern application at load time. */
const CFStringRef kCVPixelBufferCGImageCompatibilityKey = CFSTR("CGImageCompatibility");
const CFStringRef kCVPixelBufferCGBitmapContextCompatibilityKey = CFSTR("CGBitmapContextCompatibility");

const CFStringRef kCVImageBufferYCbCrMatrix_ITU_R_2020 = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferColorPrimaries_ITU_R_2020 = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferTransferFunction_ITU_R_2020 = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferTransferFunction_ITU_R_2100_HLG = CFSTR("ITU_R_2100_HLG");
const CFStringRef kCVImageBufferTransferFunction_Linear = CFSTR("Linear");
const CFStringRef kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = CFSTR("SMPTE_ST_2084_PQ");
const CFStringRef kCVImageBufferTransferFunction_SMPTE_ST_428_1 = CFSTR("SMPTE_ST_428_1");
const CFStringRef kCVImageBufferTransferFunction_SMPTE_C = CFSTR("SMPTE_C");
const CFStringRef kCVImageBufferCGColorSpaceKey = CFSTR("CGColorSpace");
const CFStringRef kCVImageBufferChromaLocation_Bottom = CFSTR("Bottom");
const CFStringRef kCVImageBufferChromaLocation_BottomLeft = CFSTR("BottomLeft");
const CFStringRef kCVImageBufferChromaLocation_Center = CFSTR("Center");
const CFStringRef kCVImageBufferChromaLocation_DV420 = CFSTR("DV 4:2:0");
const CFStringRef kCVImageBufferChromaLocation_Top = CFSTR("Top");
const CFStringRef kCVImageBufferChromaLocation_TopLeft = CFSTR("TopLeft");
const CFStringRef kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey = CFSTR("IOSurfaceOpenGLTextureCompatibility");
const CFStringRef kCVPixelBufferPoolMaximumBufferAgeKey = CFSTR("MaximumBufferAge");
const CFStringRef kCVPixelBufferPoolMinimumBufferCountKey = CFSTR("MinimumBufferCount");
