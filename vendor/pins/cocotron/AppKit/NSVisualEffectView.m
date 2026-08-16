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

#import <AppKit/NSVisualEffectView.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSImage.h>

/*
 * A REAL CLASS INSTEAD OF A CATCH ALL.
 *
 * What was here answered EVERY selector through a forwarding stub whose signature said the method
 * returns void and takes nothing. Two things follow from that and both are worse than a missing
 * method. A setter arrives with an argument the signature does not describe, which is the
 * NSForwardSignatureError iTerm2 produced three times in a row on setMaterial:, setBlendingMode:
 * and setState:. And a GETTER returns whatever happens to be in the return register, so a caller
 * that asks which material it is gets a number nobody chose.
 *
 * The properties are real now, and the drawing is an APPROXIMATION THAT IS STATED RATHER THAN
 * IMPLIED: a material is filled with the nearest system colour instead of sampling and blurring
 * what is behind the view. Blending behind the window needs the compositor, and blending within it
 * needs the window content under this view; the menu backdrop in the Wayland backend does the first
 * of those for menus only. What an application gets from this is a view that is the right colour,
 * takes its settings and does not throw.
 */
@implementation NSVisualEffectView

@synthesize material = _material;
@synthesize blendingMode = _blendingMode;
@synthesize state = _state;
@synthesize maskImage = _maskImage;
@synthesize emphasized = _emphasized;

- (void) dealloc {
    [_maskImage release];
    [super dealloc];
}

- (BOOL) isOpaque {
    return NO;
}

/* The nearest colour macOS would end up with once the blur is done. */
- (NSColor *) _cider_materialColor {
    switch (_material) {
    case NSVisualEffectMaterialMenu:
    case NSVisualEffectMaterialPopover:
    case NSVisualEffectMaterialToolTip:
    case NSVisualEffectMaterialSheet:
        return [NSColor colorWithCalibratedWhite: 0.96 alpha: 0.92];

    case NSVisualEffectMaterialSidebar:
    case NSVisualEffectMaterialUnderWindowBackground:
    case NSVisualEffectMaterialUnderPageBackground:
        return [NSColor colorWithCalibratedWhite: 0.91 alpha: 0.92];

    case NSVisualEffectMaterialTitlebar:
    case NSVisualEffectMaterialHeaderView:
        return [NSColor colorWithCalibratedWhite: 0.93 alpha: 0.95];

    case NSVisualEffectMaterialSelection:
        return _emphasized ? [NSColor selectedContentBackgroundColor]
                           : [NSColor colorWithCalibratedWhite: 0.85 alpha: 0.9];

    case NSVisualEffectMaterialHUDWindow:
    case NSVisualEffectMaterialDark:
    case NSVisualEffectMaterialUltraDark:
        return [NSColor colorWithCalibratedWhite: 0.18 alpha: 0.9];

    case NSVisualEffectMaterialContentBackground:
        return [NSColor colorWithCalibratedWhite: 1.0 alpha: 0.95];

    default:
        return [NSColor windowBackgroundColor];
    }
}

- (void) drawRect: (NSRect) rect {
    [[self _cider_materialColor] set];
    NSRectFillUsingOperation(rect, NSCompositeSourceOver);
}

@end
