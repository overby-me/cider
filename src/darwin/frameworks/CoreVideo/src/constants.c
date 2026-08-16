#include <CoreFoundation/CoreFoundation.h>

const CFStringRef kCVImageBufferPixelAspectRatioKey = CFSTR("CVPixelAspectRatio");
const CFStringRef kCVImageBufferGammaLevelKey = CFSTR("CVImageBufferGammaLevel");
const CFStringRef kCVImageBufferYCbCrMatrixKey = CFSTR("CVImageBufferYCbCrMatrix");
const CFStringRef kCVImageBufferColorPrimariesKey = CFSTR("CVImageBufferColorPrimaries");
const CFStringRef kCVImageBufferTransferFunctionKey = CFSTR("CVImageBufferTransferFunction");
const CFStringRef kCVImageBufferChromaLocationBottomFieldKey = CFSTR("CVImageBufferChromaLocationBottomField");
const CFStringRef kCVImageBufferChromaLocationTopFieldKey = CFSTR("CVImageBufferChromaLocationTopField");

const CFStringRef kCVImageBufferPixelAspectRatioHorizontalSpacingKey = CFSTR("CVImageBufferPixelAspectRatioHorizontalSpacing");
const CFStringRef kCVImageBufferPixelAspectRatioVerticalSpacingKey = CFSTR("CVImageBufferPixelAspectRatioVerticalSpacing");

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
