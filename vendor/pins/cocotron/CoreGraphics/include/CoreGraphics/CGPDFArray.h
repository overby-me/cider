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

#ifndef COREGRAPHICS_CGPDFARRAY_H
#define COREGRAPHICS_CGPDFARRAY_H

#include <CoreGraphics/CGPDFDictionary.h>
#include <CoreGraphics/CGPDFObject.h>
#include <CoreGraphics/CGPDFStream.h>
#include <CoreGraphics/CoreGraphicsExport.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct CGPDFArray *CGPDFArrayRef;

COREGRAPHICS_EXPORT size_t CGPDFArrayGetCount(CGPDFArrayRef array);

/*
 * EACH GETTER ANSWERS WHETHER IT COULD, which is the whole shape of this API: a PDF array holds
 * objects of any type, so asking for a dictionary at index three is a question, not an assertion.
 * On false the out parameter is untouched.
 */
COREGRAPHICS_EXPORT bool CGPDFArrayGetObject(CGPDFArrayRef array, size_t index,
                                             CGPDFObjectRef *value);
COREGRAPHICS_EXPORT bool CGPDFArrayGetArray(CGPDFArrayRef array, size_t index,
                                            CGPDFArrayRef *value);
COREGRAPHICS_EXPORT bool CGPDFArrayGetDictionary(CGPDFArrayRef array, size_t index,
                                                 CGPDFDictionaryRef *value);
COREGRAPHICS_EXPORT bool CGPDFArrayGetStream(CGPDFArrayRef array, size_t index,
                                             CGPDFStreamRef *value);
COREGRAPHICS_EXPORT bool CGPDFArrayGetString(CGPDFArrayRef array, size_t index,
                                             CGPDFStringRef *value);

#endif // COREGRAPHICS_CGPDFARRAY_H
