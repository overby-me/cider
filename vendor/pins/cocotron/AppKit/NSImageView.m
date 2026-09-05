/* Copyright (c) 2006-2007 Christopher J. W. Lloyd
                 2009 Markus Hitter <mah@jump-ing.de>

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

#import <AppKit/NSImage.h>
#import <AppKit/NSImageCell.h>
#import <AppKit/NSImageView.h>
#import <AppKit/NSRaise.h>

@implementation NSImageView

+ (Class) cellClass {
    return [NSImageCell class];
}

- target {
    return _target;
}

- (SEL) action {
    return _action;
}

- (void) setTarget: target {
    _target = target;
}

- (void) setAction: (SEL) action {
    _action = action;
}

- (BOOL) allowsCutCopyPaste {
    // Because cut, copy, paste isn't implemented yet ...
    return NO;
}

- (BOOL) animates {
    // Because animation isn't implemented yet ...
    return NO;
}

- (NSImage *) image {
    return [_cell image];
}

- (NSImageAlignment) imageAlignment {
    return [_cell imageAlignment];
}

- (NSImageFrameStyle) imageFrameStyle {
    return [_cell imageFrameStyle];
}

- (NSImageScaling) imageScaling {
    return [_cell imageScaling];
}

- (BOOL) refusesFirstResponder {
    // we don't have an NSCell
    return YES;
}

- (BOOL) isEditable {
    return [_cell isEditable];
}

/* A STATIC IMAGE IS NOT A CLICK TARGET, and this is what stopped a table row selecting.
 *
 * NSImageView is an NSControl, so it inherited -[NSControl mouseDown:], which tracks the cell until
 * mouse up and never forwards to the next responder. An image view filling a table cell therefore
 * swallowed the click, the enclosing table never saw it, and the row did not select. The tracking
 * loop also ate the mouse UP, so the window only ever saw the DOWN.
 *
 * Measured in iA Writer: a click at 380,476 hit an NSImageView of 271x65 inside an
 * IALibraryTableCellView, the row did not select, and the capture did not change by a single byte.
 *
 * macOS does not behave that way: a plain image inside a cell view lets the click reach the table.
 * Declining the hit test is the faithful and least invasive way to say so. An image view that is
 * editable (it accepts drags) or that carries an action is a real target and still takes the hit. */
- (NSView *) hitTest: (NSPoint) point {
    if (![self isEditable] && _action == NULL)
        return nil;

    return [super hitTest: point];
}

- (void) setAllowsCutCopyPaste: (BOOL) allow {
    if (allow != NO)
        NSUnimplementedMethod();
}

- (void) setAnimates: (BOOL) flag {
    if (flag != NO)
        ; // NSUnimplementedMethod(); ignore until implemented
}

- (void) setEditable: (BOOL) flag {
    [_cell setEditable: flag];
}

- (void) setImage: (NSImage *) image {
    [_cell setImage: image];
    [self setNeedsDisplay: YES];
}

- (void) setValuePath: (NSString *) path {
    NSImage *image =
            [[[NSImage alloc] initWithContentsOfFile: path] autorelease];
    [_cell setImage: image];
    [self setNeedsDisplay: YES];
}

- (void) setValueURL: (NSURL *) url {
    NSImage *image = [[[NSImage alloc] initWithContentsOfURL: url] autorelease];
    [_cell setImage: image];
    [self setNeedsDisplay: YES];
}

- (void) setImageAlignment: (NSImageAlignment) alignment {
    [_cell setImageAlignment: alignment];
    [self setNeedsDisplay: YES];
}

- (void) setImageFrameStyle: (NSImageFrameStyle) frameStyle {
    [_cell setImageFrameStyle: frameStyle];
    [self setNeedsDisplay: YES];
}

- (void) setImageScaling: (NSImageScaling) scaling {
    [_cell setImageScaling: scaling];
    [self setNeedsDisplay: YES];
}

@end

/*
 * THE CONVENIENCE CONSTRUCTORS, which are how a modern application builds a view in code.
 *
 * They have been in AppKit since 10.12 and none of them existed here, so an application that builds
 * its interface without a nib raised on the first one it reached. Each is exactly what the
 * documentation says it is: a view sized to fit its content, with the ordinary defaults for a label
 * or a button set up before it is returned.
 */
@implementation NSImageView (CiderConvenience)

+ (instancetype) imageViewWithImage: (NSImage *) image {
    NSSize size = image != nil ? [image size] : NSMakeSize(0, 0);
    NSImageView *view = [[[self alloc] initWithFrame: NSMakeRect(0, 0, size.width, size.height)]
            autorelease];

    [view setImage: image];
    [view setImageScaling: NSImageScaleProportionallyDown];
    return view;
}

@end
