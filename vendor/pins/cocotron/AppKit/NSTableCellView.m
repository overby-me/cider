/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#import <objc/runtime.h>
#import <AppKit/NSTableCellView.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSImageView.h>
#import <Foundation/NSArray.h>

@implementation NSTableCellView

/*
 * THE REAL SHAPE, not just a forwarder.
 *
 * This class was nothing but a message swallower, so every one of these returned nil quietly: a
 * table that vends cell views got views whose textField was nil, which is why iA Writer's library
 * rows drew as empty stripes with the outline structure around them intact. The outlets are what a
 * nib connects and what a delegate fills in.
 *
 * The stub forwarder below still catches everything else, so this is strictly more than there was.
 */
- (id) objectValue {
    return _objectValue;
}

- (void) setObjectValue: (id) objectValue {
    objectValue = [objectValue retain];
    [_objectValue release];
    _objectValue = objectValue;
}

- (NSTextField *) textField {
    return _textField;
}

- (void) setTextField: (NSTextField *) textField {
    textField = [textField retain];
    [_textField release];
    _textField = textField;
}

- (NSImageView *) imageView {
    return _imageView;
}

- (void) setImageView: (NSImageView *) imageView {
    imageView = [imageView retain];
    [_imageView release];
    _imageView = imageView;
}

- (NSBackgroundStyle) backgroundStyle {
    return _backgroundStyle;
}

- (void) setBackgroundStyle: (NSBackgroundStyle) backgroundStyle {
    _backgroundStyle = backgroundStyle;
    [self setNeedsDisplay: YES];
}

- (NSInteger) rowSizeStyle {
    return _rowSizeStyle;
}

- (void) setRowSizeStyle: (NSInteger) rowSizeStyle {
    _rowSizeStyle = rowSizeStyle;
}

- (NSArray *) draggingImageComponents {
    return [NSArray array];
}

- (void) dealloc {
    [_objectValue release];
    [_textField release];
    [_imageView release];
    [super dealloc];
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
