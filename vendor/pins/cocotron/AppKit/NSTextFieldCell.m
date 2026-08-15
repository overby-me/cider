/* Copyright (c) 2006-2007 Christopher J. W. Lloyd <cjwl@objc.net>

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

#import "NSCoder+AppKit.h"
#include <objc/runtime.h>

#import <AppKit/NSApplication.h>
#import <AppKit/NSAttributedString.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSGraphicsStyle.h>
#import <AppKit/NSObject+BindingSupport.h>
#import <AppKit/NSParagraphStyle.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSStringDrawer.h>
#import <AppKit/NSStringDrawing.h>
#include <stdlib.h>
#import <AppKit/NSTextFieldCell.h>
#import <Foundation/NSKeyedArchiver.h>

@implementation NSTextFieldCell

@synthesize allowedInputSourceLocales = _allowedInputSourceLocales;

- (void) encodeWithCoder: (NSCoder *) coder {
    [super encodeWithCoder: coder];

    if (coder.allowsKeyedCoding) {
        [coder encodeBool: _drawsBackground forKey: @"NSDrawsBackground"];
        [coder encodeObject: _backgroundColor forKey: @"NSBackgroundColor"];
        [coder encodeObject: _textColor forKey: @"NSTextColor"];
        [coder encodeInteger: _bezelStyle forKey: @"NSTextBezelStyle"];
        [coder encodeObject: _placeholder forKey: @"NSPlaceholderString"];
    } else {
        [NSException raise: NSInvalidArchiveOperationException
                    format: @"TODO: support unkeyed encoding in NSTextFieldCell"];
    }
}

- initWithCoder: (NSCoder *) coder {
    [super initWithCoder: coder];

    if ([coder allowsKeyedCoding]) {
        NSKeyedUnarchiver *keyed = (NSKeyedUnarchiver *) coder;

        _drawsBackground = [keyed decodeBoolForKey: @"NSDrawsBackground"];
        _backgroundColor =
                [[keyed decodeObjectForKey: @"NSBackgroundColor"] retain];
        _textColor = [[keyed decodeObjectForKey: @"NSTextColor"] retain];
        _bezelStyle = [keyed decodeIntegerForKey: @"NSTextBezelStyle"];
        _placeholder =
                [[keyed decodeObjectForKey: @"NSPlaceholderString"] retain];
    } else {
        NSInteger version = [coder versionForClassName: @"NSTextFieldCell"];
        NSLog(@"NSTextFieldCell version is %ld\n", (long) version);
        if (version > 40) {
            uint8_t flags;
            [coder decodeValuesOfObjCTypes: "c@@", &flags, &_backgroundColor,
                                            &_textColor];

            _drawsBackground = flags & 1;
            _bezelStyle = (flags & 0xe) >> 1;

            if (version <= 60) {
                if ([_textColor isEqual: [NSColor textColor]])
                    [self setTextColor: [NSColor controlTextColor]];
            }
        } else if (version > 16) {
            _drawsBackground = [coder decodeByte] != 0;
            [self setBackgroundColor: [coder decodeObject]];
            [self setTextColor: [coder decodeObject]];
        } else if (version > 1) {
            [coder decodeValuesOfObjCTypes: "@@c", &_backgroundColor,
                                            &_textColor, &_drawsBackground];
        } else {
            float bgcolor, fgcolor;
            [coder decodeValuesOfObjCTypes: "ff", &bgcolor, fgcolor];

            if (bgcolor <= 0.0f) {
                _drawsBackground = FALSE;
                [self setBackgroundColor: [NSColor whiteColor]];
            } else {
                _drawsBackground = TRUE;
                [self setBackgroundColor:
                                [NSColor colorWithCalibratedWhite: bgcolor
                                                            alpha: 1.0]];
            }
            [self setTextColor: [NSColor colorWithCalibratedWhite: fgcolor
                                                            alpha: 1.0]];

            if (version != 0) {
                NSColor *color = [coder decodeNXColor];
                if (color != nil)
                    [self setTextColor: color];

                color = [coder decodeNXColor];
                if (color != nil)
                    [self setBackgroundColor: color];
            }
        }

        if (version <= 55) {
            // Fix some hardcoded colors
            if ([_backgroundColor isEqual: [NSColor whiteColor]])
                [self setBackgroundColor: [NSColor textBackgroundColor]];
            else if ([_backgroundColor isEqual: [NSColor lightGrayColor]])
                [self setBackgroundColor: [NSColor controlColor]];

            if ([_textColor isEqual: [NSColor blackColor]])
                [self setTextColor: [NSColor controlTextColor]];
        }
    }

    return self;
}

- initTextCell: (NSString *) string {
    [super initTextCell: string];
    // default for _isBezeled=NO;
    return self;
}

// Override NSCell behavior of creating an image/null type cell
- init {
    return [self initTextCell: @""];
}

- (void) dealloc {
    [_backgroundColor release];
    [_textColor release];
    [_placeholder release];
    [_allowedInputSourceLocales release];
    [super dealloc];
}

- copyWithZone: (NSZone *) zone {
    NSTextFieldCell *cell = [super copyWithZone: zone];

    cell->_backgroundColor = [_backgroundColor copy];
    cell->_textColor = [_textColor copy];

    return cell;
}

- (NSCellType) type {
    return NSTextCellType;
}

- (NSColor *) backgroundColor {
    return _backgroundColor;
}

- (NSColor *) textColor {
    return _textColor;
}

- (BOOL) drawsBackground {
    return _drawsBackground;
}

- (NSTextFieldBezelStyle) bezelStyle {
    return _bezelStyle;
}

- (NSString *) placeholderString {
    if ([_placeholder isKindOfClass: [NSString class]])
        return _placeholder;

    return nil;
}

- (NSAttributedString *) placeholderAttributedString {
    if ([_placeholder isKindOfClass: [NSAttributedString class]])
        return _placeholder;

    return nil;
}

- (void) setBackgroundColor: (NSColor *) color {
    color = [color retain];
    [_backgroundColor release];
    _backgroundColor = color;
}

- (void) setTextColor: (NSColor *) color {
    color = [color retain];
    [_textColor release];
    _textColor = color;
}

- (void) setDrawsBackground: (BOOL) flag {
    _drawsBackground = flag;
}

- (void) setBezelStyle: (NSTextFieldBezelStyle) value {
    _bezelStyle = value;
}

- (void) setPlaceholderString: (NSString *) value {
    value = [value copy];
    [_placeholder release];
    _placeholder = value;
}

- (void) setPlaceholderAttributedString: (NSAttributedString *) value {
    value = [value copy];
    [_placeholder release];
    _placeholder = value;
}

// titleRectForBounds is not used for generating the value rect in a text field
- (NSRect) _valueRectForBounds: (NSRect) rect {
    if ([self isBezeled]) {

        switch ([self bezelStyle]) {
        default:
        case NSTextFieldSquareBezel:
            rect = NSInsetRect(rect, 3, 3);
            break;

        case NSTextFieldRoundedBezel:;
            CGFloat radius = rect.size.height / 2;
            rect = NSInsetRect(rect, radius, 3);
            break;
        }
    } else if ([self isBordered])
        rect = NSInsetRect(rect, 2, 2);
    else
        rect = NSInsetRect(rect, 2, 0);

    return rect;
}

- (NSRect) titleRectForBounds: (NSRect) rect {
    return [self _valueRectForBounds: rect];
}

- (NSRect) drawingRectForBounds: (NSRect) rect {
    return [self _valueRectForBounds: rect];
}

- (NSAttributedString *) attributedStringValue {
    if ([_objectValue isKindOfClass: [NSAttributedString class]]) {
        if (_textColor == nil)
            return _objectValue;
        else {
            NSMutableAttributedString *result =
                    [[_objectValue mutableCopy] autorelease];

            [result addAttribute: NSForegroundColorAttributeName
                           value: _textColor
                           range: NSMakeRange(0, [result length])];

            return result;
        }
    } else {
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        NSMutableParagraphStyle *paraStyle =
                [[[NSParagraphStyle defaultParagraphStyle] mutableCopy]
                        autorelease];
        NSFont *font = [self font];

        if (font != nil)
            [attributes setObject: font forKey: NSFontAttributeName];

        if ([self isEnabled]) {
            if (_textColor != nil)
                [attributes setObject: _textColor
                               forKey: NSForegroundColorAttributeName];
        } else {
            [attributes setObject: [NSColor disabledControlTextColor]
                           forKey: NSForegroundColorAttributeName];
        }

#if 0
    if([self drawsBackground]/* && ![self isBezeled]*/){
     NSColor *color=(_backgroundColor==nil)?[NSColor controlColor]:_backgroundColor;
     [attributes setObject:color
                    forKey:NSBackgroundColorAttributeName];
    }
#endif

        [paraStyle setLineBreakMode: _lineBreakMode];
        [paraStyle setAlignment: _textAlignment];
        [attributes setObject: paraStyle forKey: NSParagraphStyleAttributeName];

        return [[[NSAttributedString alloc] initWithString: [self stringValue]
                                                attributes: attributes]
                autorelease];
    }
}

- (NSSize) cellSize {
    NSSize size = [[self attributedStringValue] size];

    if ([self isBezeled]) {
        size.width += 6;
        size.height += 6;
    } else if ([self isBordered]) {
        size.width += 4;
        size.height += 4;
    } else {
        size.width += 4;
    }
    return size;
}

/*
 * THE FIELD EDITOR MUST NOT PAINT ITS OWN BACKGROUND, now that the well under it is rounded.
 *
 * AppKit puts an NSTextView over the cell while it is being edited, and that view fills its whole
 * frame white. The frame is the title rect, the well is the cell frame with rounded corners, and
 * the two do not line up: a white band appeared above and to the left of every FOCUSED field, which
 * is why it was in some places and not others. The bezel is the background; the editor only draws
 * the text.
 */
static void cider_field_editor_is_transparent(NSText *editor) {
    if ([editor respondsToSelector: @selector(setDrawsBackground:)]) {
        [editor setDrawsBackground: NO];
    }
}

- (void) editWithFrame: (NSRect) frame
                inView: (NSView *) view
                editor: (NSText *) editor
              delegate: (id) delegate
                 event: (NSEvent *) event
{
    frame = [self titleRectForBounds: frame];
    [super editWithFrame: frame
                  inView: view
                  editor: editor
                delegate: delegate
                   event: event];
    if ([self isBezeled]) {
        cider_field_editor_is_transparent(editor);
    }
}

- (void) selectWithFrame: (NSRect) frame
                  inView: (NSView *) view
                  editor: (NSText *) editor
                delegate: (id) delegate
                   start: (NSInteger) location
                  length: (NSInteger) length
{
    frame = [self titleRectForBounds: frame];
    [super selectWithFrame: frame
                    inView: view
                    editor: editor
                  delegate: delegate
                     start: location
                    length: length];
    if ([self isBezeled]) {
        cider_field_editor_is_transparent(editor);
    }
}

- (void) drawInteriorWithFrame: (NSRect) frame inView: (NSView *) control {
    NSRect titleRect = [self titleRectForBounds: frame];

    NSAttributedString *drawValue = [self attributedStringValue];

    if ([drawValue length] == 0 && [_placeholder length] > 0) {
        if ([_placeholder isKindOfClass: [NSAttributedString class]])
            drawValue = _placeholder;
        else if ([_placeholder isKindOfClass: [NSString class]]) {
            NSMutableAttributedString *placeString =
                    [[drawValue mutableCopy] autorelease];
            [[placeString mutableString] setString: _placeholder];
            [placeString addAttribute: NSForegroundColorAttributeName
                                value: [NSColor disabledControlTextColor]
                                range: NSMakeRange(0, [placeString length])];
            drawValue = placeString;
        }
    }
    [drawValue _clipAndDrawInRect: titleRect
                   truncatingTail: _lineBreakMode > NSLineBreakByClipping];
}

static void drawRoundedBezel(CGContextRef context, CGRect frame) {
    CGFloat radius = frame.size.height / 2;

    CGContextBeginPath(context);
    CGContextAddArc(context, CGRectGetMaxX(frame) - radius,
                    CGRectGetMinY(frame) + radius, radius, M_PI_2, M_PI_2 * 3,
                    YES);
    CGContextAddArc(context, CGRectGetMinX(frame) + radius,
                    CGRectGetMinY(frame) + radius, radius, M_PI_2 * 3, M_PI_2,
                    YES);
    CGContextClosePath(context);
    CGContextFillPath(context);
}

- (void) drawWithFrame: (NSRect) frame inView: (NSView *) control {
    NSRect backRect = [self drawingRectForBounds: frame];
    BOOL roundedBackground = NO;

    /* THIS OVERRIDE DOES NOT CALL SUPER, so the trace on NSCell never sees a text field, a combo
     * box or anything else below them. A trace put only on the base class reported ZERO cell draws
     * in a run that drew thirty two of them, which reads exactly like a path that is never taken. */
    if (getenv("CIDER_TRACE_CELLS") != NULL) {
        NSLog(@"CIDER_CELL %s frame=%gx%g+%g+%g view=%s", object_getClassName(self),
              frame.size.width, frame.size.height, frame.origin.x, frame.origin.y,
              (control != nil) ? object_getClassName(control) : "nil");
    }

    _controlView = control;

    if ([self isBezeled]) {
        switch ([self bezelStyle]) {
        default:
        case NSTextFieldSquareBezel:
            [NSGraphicsStyleForView(control) drawTextFieldBorderInRect: frame
                                                bezeledNotLine: YES];
            /* THE BEZEL IS THE BACKGROUND NOW. Growing the fill rect by one in each direction was
             * invisible under a square bezel and pokes out of a rounded one, which is the white box
             * that appeared at the corner of every bezeled field. */
            roundedBackground = YES;
            backRect = frame;
            break;

        case NSTextFieldRoundedBezel:;
            CGContextRef context =
                    [[NSGraphicsContext currentContext] graphicsPort];
            NSRect roundedFrame = frame;

            roundedFrame.size.height--;
            [[NSColor darkGrayColor] setFill];
            drawRoundedBezel(context, roundedFrame);

            roundedFrame.origin.y += 1;
            [[NSColor lightGrayColor] setFill];
            drawRoundedBezel(context, roundedFrame);

            roundedFrame = NSInsetRect(roundedFrame, 1, 1);
            [[NSColor whiteColor] setFill];
            drawRoundedBezel(context, roundedFrame);
            break;
        }

    } else {
        if ([self isBordered]) {
            [NSGraphicsStyleForView(control) drawTextFieldBorderInRect: frame
                                                bezeledNotLine: NO];
            backRect = NSInsetRect(backRect, -1, -1);
        }
    }

    if ([self drawsBackground]) {
        if (!([self isBezeled] &&
              [self bezelStyle] == NSTextFieldRoundedBezel)) {
            NSColor *color = (_backgroundColor == nil) ? [NSColor controlColor]
                                                       : _backgroundColor;

            if (getenv("CIDER_FIELD_MAGENTA") != NULL) {
                /* THE CELL BACKGROUND, in a colour nothing else uses: if the white band above a
                 * rounded well turns cyan it is this fill, and if it stays white it is the
                 * application painting over us. */
                color = [NSColor cyanColor];
            }
            if (roundedBackground) {
                [NSGraphicsStyleForView(control) drawTextFieldBackgroundInRect: backRect
                                                                        color: color];
            } else {
                [color setFill];
                NSRectFill(backRect);
            }
        }
    }

    [self drawInteriorWithFrame: frame inView: control];
}

@end

@implementation NSTextFieldCell (Bindings)

- (CGFloat) _fontSize {
    return [_font pointSize];
}
- (void) _setFontSize: (CGFloat) fontSize {
    NSString *fontName = [_font fontName];
    [self setFont: [NSFont fontWithName: fontName size: fontSize]];
}
- (NSString *) _fontFamilyName {
    return [_font familyName];
}
- (void) _setFontFamilyName: (NSString *) familyName {
    if (!familyName) {
        return;
    }

    NSLog(@"_setFontFamilyName: %@", familyName);

    CGFloat currentSize = [_font pointSize];
    [self setFont: [NSFont fontWithName: familyName size: currentSize]];
}

- (id) _replacementKeyPathForBinding: (id) binding {
    if ([binding isEqual: @"value"])
        return @"stringValue";
    return [super _replacementKeyPathForBinding: binding];
}

@end
