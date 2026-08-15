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

/*
 * READING A PDF FROM C. Onyx2D already parses PDF into an object graph and draws it; what was
 * missing was the C interface applications actually call, so a program that wanted to look inside a
 * document it had opened could not, and referencing one of these functions stopped it loading at
 * all. Swift Publisher 5 places PDFs in a page and reads their metadata to do it.
 *
 * These are bindings, not stubs: every one of them is the Onyx2D method that already existed.
 */

#import <CoreGraphics/CGPDFArray.h>
#import <CoreGraphics/CGPDFDictionary.h>
#import <CoreGraphics/CGPDFObject.h>
#import <CoreGraphics/CGPDFStream.h>
#import <Onyx2D/O2PDFArray.h>
#import <Onyx2D/O2PDFDictionary.h>
#import <Onyx2D/O2PDFObject.h>
#import <Onyx2D/O2PDFStream.h>

CGPDFObjectType CGPDFObjectGetType(CGPDFObjectRef object) {
    if (object == NULL)
        return kCGPDFObjectTypeNull;

    /*
     * THE TWO ENUMERATIONS ARE THE SAME ONE up to kO2PDFObjectTypeStream, which is asserted here
     * rather than assumed: everything past that in the Onyx2D list is a parser mark with no PDF
     * meaning, and an application handed one of those numbers would read it as a type it knows.
     */
    O2PDFObjectType type = [(O2PDFObject *) object objectType];

    if (type < kO2PDFObjectTypeNull || type > kO2PDFObjectTypeStream)
        return kCGPDFObjectTypeNull;

    return (CGPDFObjectType) type;
}

bool CGPDFObjectGetValue(CGPDFObjectRef object, CGPDFObjectType type, void *value) {
    if (object == NULL)
        return false;

    return [(O2PDFObject *) object checkForType: (O2PDFObjectType) type value: value] ? true
                                                                                      : false;
}

size_t CGPDFArrayGetCount(CGPDFArrayRef array) {
    if (array == NULL)
        return 0;

    return [(O2PDFArray *) array count];
}

bool CGPDFArrayGetObject(CGPDFArrayRef array, size_t index, CGPDFObjectRef *value) {
    if (array == NULL)
        return false;

    return [(O2PDFArray *) array getObjectAtIndex: index value: (O2PDFObject **) value] ? true
                                                                                        : false;
}

bool CGPDFArrayGetArray(CGPDFArrayRef array, size_t index, CGPDFArrayRef *value) {
    if (array == NULL)
        return false;

    return [(O2PDFArray *) array getArrayAtIndex: index value: (O2PDFArray **) value] ? true
                                                                                      : false;
}

bool CGPDFArrayGetDictionary(CGPDFArrayRef array, size_t index, CGPDFDictionaryRef *value) {
    if (array == NULL)
        return false;

    return [(O2PDFArray *) array getDictionaryAtIndex: index
                                                value: (O2PDFDictionary **) value]
            ? true
            : false;
}

bool CGPDFArrayGetStream(CGPDFArrayRef array, size_t index, CGPDFStreamRef *value) {
    if (array == NULL)
        return false;

    return [(O2PDFArray *) array getStreamAtIndex: index value: (O2PDFStream **) value] ? true
                                                                                        : false;
}

bool CGPDFArrayGetString(CGPDFArrayRef array, size_t index, CGPDFStringRef *value) {
    if (array == NULL)
        return false;

    return [(O2PDFArray *) array getStringAtIndex: index value: (O2PDFString **) value] ? true
                                                                                        : false;
}

CGPDFDictionaryRef CGPDFStreamGetDictionary(CGPDFStreamRef stream) {
    if (stream == NULL)
        return NULL;

    return (CGPDFDictionaryRef) [(O2PDFStream *) stream dictionary];
}

void CGPDFDictionaryApplyFunction(CGPDFDictionaryRef dict, CGPDFDictionaryApplierFunction function,
                                  void *info) {
    if (dict == NULL || function == NULL)
        return;

    [(O2PDFDictionary *) dict applyFunction: (void (*)(const char *, void *, void *)) function
                                      info: info];
}
