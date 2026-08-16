#ifndef COREGRAPHICS_CGPDFDICTIONARY_H
#define COREGRAPHICS_CGPDFDICTIONARY_H

#include <CoreGraphics/CGPDFObject.h>

typedef struct CGPDFDictionary *CGPDFDictionaryRef;
typedef void (*CGPDFDictionaryApplierFunction)(const char *key, CGPDFObjectRef value, void *info);

void CGPDFDictionaryApplyFunction(CGPDFDictionaryRef dict, CGPDFDictionaryApplierFunction function, void *info);

#endif // COREGRAPHICS_CGPDFDICTIONARY_H