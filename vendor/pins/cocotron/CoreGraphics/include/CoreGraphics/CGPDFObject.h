/* Copyright (c) 2026 Cider

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

#ifndef COREGRAPHICS_CGPDFOBJECT_H
#define COREGRAPHICS_CGPDFOBJECT_H

#include <CoreGraphics/CoreGraphicsExport.h>
#include <stdbool.h>

typedef struct CGPDFObject *CGPDFObjectRef;
typedef struct CGPDFString *CGPDFStringRef;

typedef bool CGPDFBoolean;
typedef long CGPDFInteger;
typedef double CGPDFReal;

/*
 * THE NINE THINGS A PDF OBJECT CAN BE. The numbering is the one applications compile against and it
 * is also, deliberately, the numbering Onyx2D uses internally (O2PDFObjectType), so the two need no
 * translation table that could drift.
 */
typedef enum {
    kCGPDFObjectTypeNull = 1,
    kCGPDFObjectTypeBoolean,
    kCGPDFObjectTypeInteger,
    kCGPDFObjectTypeReal,
    kCGPDFObjectTypeName,
    kCGPDFObjectTypeString,
    kCGPDFObjectTypeArray,
    kCGPDFObjectTypeDictionary,
    kCGPDFObjectTypeStream,
} CGPDFObjectType;

COREGRAPHICS_EXPORT CGPDFObjectType CGPDFObjectGetType(CGPDFObjectRef object);

/*
 * ASK FOR A TYPE AND GET AN ANSWER, not a cast. False means the object is something else, and then
 * value is untouched. What value points at depends on the type asked for: a CGPDFBoolean, a
 * CGPDFInteger, a CGPDFReal, a const char * for a name, or a ref for the four object types.
 */
COREGRAPHICS_EXPORT bool CGPDFObjectGetValue(CGPDFObjectRef object, CGPDFObjectType type,
                                             void *value);

#endif // COREGRAPHICS_CGPDFOBJECT_H
