/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

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

#import <objc/runtime.h>
#import <AppKit/NSPrinter.h>
#import <Foundation/Foundation.h>

@implementation NSPrinter

/*
 * ENOUGH OF NSPrinter TO SAY THERE ARE NO PRINTERS, which is the truth in this container and was
 * not something this class could express.
 *
 * The forwarding below covers INSTANCE messages only; a class message lands nowhere, so
 * +printerNames raised and killed the process. LibreOffice sends it the moment its print dialog is
 * dismissed -- and the dialog it shows first is the one saying no default printer was found, so the
 * only way out of that dialog was a crash.
 *
 * Empty answers rather than clever ones. There is no CUPS in the container and nothing here can
 * print; an application that asks and is told nothing is available behaves correctly, and one that
 * is handed an invented printer would fail later and further from the cause. The selectors are the
 * ones libvclplug_osxlo actually sends, found by intersecting its strings with this API.
 */
+ (NSArray *) printerNames {
    return [NSArray array];
}

+ (NSArray *) printerTypes {
    return [NSArray array];
}

+ (NSPrinter *) printerWithName: (NSString *) name {
    return nil;
}

+ (NSPrinter *) printerWithType: (NSString *) type {
    return nil;
}

- (NSString *) name {
    return @"";
}

- (NSString *) type {
    return @"";
}

- (NSDictionary *) deviceDescription {
    return [NSDictionary dictionary];
}

- (NSSize) pageSizeForPaper: (NSString *) paper {
    return NSZeroSize;
}

/* NSPrinterTableNotFound, spelled as the number because this header does not define the enum. */
- (NSInteger) statusForTable: (NSString *) table {
    return 1;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    /* The arity comes from the selector's colons and the return is an object: "v@:" claimed every
     * method took none and returned nothing, so a caller passing arguments wrote through slots the
     * invocation did not have, and one using the result read the leftover return register. */
    const char *name = sel_getName(aSelector);
    char types[256];
    size_t n = 0;

    types[n++] = '@';
    types[n++] = '@';
    types[n++] = ':';
    for (const char *p = name; *p != '\0' && n < sizeof(types) - 1; p++) {
        if (*p == ':')
            types[n++] = '@';
    }
    types[n] = '\0';
    return [NSMethodSignature signatureWithObjCTypes: types];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    id nothing = nil;
    [anInvocation setReturnValue: &nothing];
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
