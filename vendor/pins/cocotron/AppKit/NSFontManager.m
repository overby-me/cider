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

#import <AppKit/NSApplication.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSFontFamily.h>
#import <AppKit/NSFontManager.h>
#import <AppKit/NSFontPanel.h>
#import <AppKit/NSFontTypeface.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSNibLoading.h>
#import <AppKit/NSRaise.h>

@implementation NSFontManager

static Class _fontManagerFactory;
static Class _fontPanelFactory;

+ (NSFontManager *) sharedFontManager {
    NSString *name = @"NSFontManager";

    if (_fontManagerFactory != Nil)
        name = NSStringFromClass(_fontManagerFactory);

    return NSThreadSharedInstance(name);
}

+ (void) setFontManagerFactory: (Class) value {
    _fontManagerFactory = value;
}

+ (void) setFontPanelFactory: (Class) value {
    _fontPanelFactory = value;
}

- init {
    _panel = nil;
    _action = @selector(changeFont:);
    _selectedFont = [[NSFont userFontOfSize: 0] retain];
    _isMultiple = NO;
    return self;
}

- delegate {
    return _delegate;
}

- (SEL) action {
    return _action;
}

- (void) setDelegate: delegate {
    _delegate = delegate;
}

- (void) setAction: (SEL) value {
    _action = value;
}

- (NSFontAction) currentFontAction {
    return _currentFontAction;
}

- (NSArray *) collectionNames {
    NSUnimplementedMethod();
    return nil;
}

- (BOOL) addCollection: (NSString *) name options: (int) options {
    NSUnimplementedMethod();
    return 0;
}

- (void) addFontDescriptors: (NSArray *) descriptors
               toCollection: (NSString *) name
{
    NSUnimplementedMethod();
}

- (BOOL) removeCollection: (NSString *) name {
    NSUnimplementedMethod();
    return 0;
}

- (NSArray *) fontDescriptorsInCollection: (NSString *) name {
    NSUnimplementedMethod();
    return nil;
}

- (NSArray *) availableFonts {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *families = [NSFontFamily allFontFamilyNames];
    int i, count = [families count];

    for (i = 0; i < count; i++) {
        NSString *familyName = [families objectAtIndex: i];
        NSFontFamily *family = [NSFontFamily fontFamilyWithName: familyName];
        NSArray *typefaces = [family typefaces];
        int t, tcount = [typefaces count];

        for (t = 0; t < tcount; t++) {
            NSFontTypeface *typeface = [typefaces objectAtIndex: t];
            NSString *name = [typeface name];

            [result addObject: name];
        }
    }

    return result;
}

- (NSArray *) availableFontFamilies {
    NSArray *families = [NSFontFamily allFontFamilyNames];

    if (![_delegate respondsToSelector: @selector(fontManager:
                                                willIncludeFont:)])
        return families;
    else {
        NSMutableArray *result = [NSMutableArray array];
        int i, count = [families count];

        for (i = 0; i < count; i++) {
            NSString *familyName = [families objectAtIndex: i];
            NSFontFamily *family =
                    [NSFontFamily fontFamilyWithName: familyName];
            NSArray *typefaces = [family typefaces];
            int t, tcount = [typefaces count];

            for (t = 0; t < tcount; t++) {
                NSFontTypeface *typeface = [typefaces objectAtIndex: t];
                NSString *name = [typeface name];

                if ([_delegate fontManager: self willIncludeFont: name]) {
                    [result addObject: familyName];
                    break;
                }
            }
        }

        return result;
    }
}

- (NSArray *) availableMembersOfFontFamily: (NSString *) familyName {
    NSMutableArray *result = [NSMutableArray array];
    NSFontFamily *family = [NSFontFamily fontFamilyWithName: familyName];
    NSArray *typefaces = [family typefaces];
    int i, count = [typefaces count];

    for (i = 0; i < count; i++) {
        NSFontTypeface *typeface = [typefaces objectAtIndex: i];
        NSString *name = [typeface name];
        NSString *traitName = [typeface traitName];

        // Callers expect an array of four objects
        [result addObject: [NSArray arrayWithObjects: name, traitName,
                                                      [NSNumber
                                                              numberWithInt: 0],
                                                      [NSNumber
                                                              numberWithInt: 0],
                                                      nil]];
    }

    return result;
}

- (NSArray *) availableFontNamesMatchingFontDescriptor:
        (NSFontDescriptor *) descriptor
{
    NSUnimplementedMethod();
    return nil;
}

- (NSArray *) availableFontNamesWithTraits: (NSFontTraitMask) traits {
    NSUnimplementedMethod();
    return nil;
}

- (BOOL) fontNamed: (NSString *) name hasTraits: (NSFontTraitMask) traits {
    NSFont *font = [NSFont fontWithName: name size: 12];
    NSFontTraitMask fontTraits = [self traitsOfFont: font];
    return (traits & fontTraits) == traits;
}

- (NSFont *) fontWithFamily: (NSString *) familyName
                     traits: (NSFontTraitMask) traits
                     weight: (int) weight
                       size: (CGFloat) size
{
    // Note : weight is ignored

    NSFontFamily *family = [NSFontFamily fontFamilyWithName: familyName];
    NSArray *typefaces = [family typefaces];
    int i, count = [typefaces count];
    NSString *fontName = nil;

    for (i = 0; i < count; i++) {
        NSFontTypeface *typeface = [typefaces objectAtIndex: i];
        NSFontTraitMask checkTraits = [typeface traits];

        if (((traits & NSItalicFontMask) == (checkTraits & NSItalicFontMask)) &&
            ((traits & NSBoldFontMask) == (checkTraits & NSBoldFontMask))) {
            fontName = [typeface name];
            break;
        }
    }

    if (fontName == nil) {
        // match something!
        if ([typefaces count] > 0) {
            NSFontTypeface *typeface = [typefaces objectAtIndex: 0];
            fontName = [typeface name];
        }
    }

    NSFont *font = nil;
    if (fontName != nil) {
        font = [NSFont fontWithName: fontName size: size];
    } else {
        NSLog(@"unable to match any font in faces '%@' of family '%@' with "
              @"traits mask: %d",
              typefaces, familyName, traits);
    }

    return font;
}

- (int) weightOfFont: (NSFont *) font {
    return 5; // default to the normal weight
}

- (NSFontTraitMask) traitsOfFont: (NSFont *) font {
    NSFontTypeface *typeface =
            [NSFontFamily fontTypefaceWithName: [font fontName]];

    return [typeface traits];
}

- (NSString *) localizedNameForFamily: (NSString *) family
                                 face: (NSString *) face
{
    if (face == nil) {
        return family;
    }
    return [NSString stringWithFormat: @"%@ %@", family, face];
}

- (void) setFontPanel: (NSFontPanel *) panel {
    panel = [panel retain];
    [_panel release];
    _panel = panel;
}

- (NSFontPanel *) fontPanel: (BOOL) create {
    if (_panel == nil && create) {
        [NSBundle loadNibNamed: @"NSFontPanel" owner: self];
    }

    if (![_panel setFrameUsingName: @"NSFontPanel"]) {
        [_panel center];
    }
    [_panel setFrameAutosaveName: @"NSFontPanel"];

    [_panel setPanelFont: _selectedFont isMultiple: _isMultiple];
    return _panel;
}

- (BOOL) sendAction {
    return [NSApp sendAction: _action
                          to: nil
                        from: [NSFontManager sharedFontManager]];
}

- (BOOL) isEnabled {
    NSUnimplementedMethod();
    return 0;
}

- (BOOL) isMultiple {
    return _isMultiple;
}

- (NSFont *) selectedFont {
    return _selectedFont;
}

- (void) _configureMenu: (NSMenu *) menu forFont: (NSFont *) font {
    NSArray *items = [menu itemArray];
    int i, count = [items count];

    for (i = 0; i < count; i++) {
        NSMenuItem *item = [items objectAtIndex: i];

        if ([item hasSubmenu])
            [self _configureMenu: [item submenu] forFont: font];
        else if (sel_isEqual([item action], @selector(addFontTrait:)) &&
                 [item target] == self) {
            unsigned tag = [item tag];
            NSFontTraitMask traits = [self traitsOfFont: font];

            if (tag & (NSItalicFontMask | NSUnitalicFontMask)) {
                if (traits & NSItalicFontMask) {
                    [item setTag: NSUnitalicFontMask];
                    [item setTitle: NSLocalizedStringFromTableInBundle(
                                            @"Unitalic", nil,
                                            [NSBundle bundleForClass:
                                                              [NSFontManager
                                                                      class]],
                                            @"Remove the italic font trait")];
                } else {
                    [item setTag: NSItalicFontMask];
                    [item setTitle: NSLocalizedStringFromTableInBundle(
                                            @"Italic", nil,
                                            [NSBundle bundleForClass:
                                                              [NSFontManager
                                                                      class]],
                                            @"Add the italic font trait")];
                }
            }
            if (tag & (NSBoldFontMask | NSUnboldFontMask)) {
                if (traits & NSBoldFontMask) {
                    [item setTag: NSUnboldFontMask];
                    [item setTitle: NSLocalizedStringFromTableInBundle(
                                            @"Unbold", nil,
                                            [NSBundle bundleForClass:
                                                              [NSFontManager
                                                                      class]],
                                            @"Remove the bold font trait")];
                } else {
                    [item setTag: NSBoldFontMask];
                    [item setTitle: NSLocalizedStringFromTableInBundle(
                                            @"Bold", nil,
                                            [NSBundle bundleForClass:
                                                              [NSFontManager
                                                                      class]],
                                            @"Add the bold font trait")];
                }
            }
        }
    }
}

- (void) setSelectedFont: (NSFont *) font isMultiple: (BOOL) flag {
    [_selectedFont autorelease];
    _selectedFont = [font retain];
    _isMultiple = flag;

    [[self fontPanel: NO] setPanelFont: font isMultiple: flag];
    [self _configureMenu: [NSApp mainMenu] forFont: font];
}

- (void) _udpdateSelectedFont {
    if (_selectedFont) {
        NSFont *font = [self convertFont: _selectedFont];
        if (font && font != _selectedFont) {
            [self setSelectedFont: font isMultiple: _isMultiple];
        }
    }
}

- (NSFont *) convertFont: (NSFont *) font {

    if (font == nil) {
        return nil;
    }
    switch (_currentFontAction) {

    case NSNoFontChangeAction:
        break;

    case NSViaPanelFontAction:
        font = [_panel panelConvertFont: font];
        break;

    case NSAddTraitFontAction:
        font = [self convertFont: font toHaveTrait: _currentTrait];
        break;

    case NSSizeUpFontAction:
        font = [self convertFont: font toSize: [font pointSize] + 1];
        break;

    case NSSizeDownFontAction: {
        CGFloat ps = [font pointSize];
        if (ps > 1) {
            ps -= 1;
        }
        font = [self convertFont: font toSize: ps];
    } break;

    case NSHeavierFontAction:
        font = [self convertWeight: YES ofFont: font];
        break;

    case NSLighterFontAction:
        font = [self convertWeight: NO ofFont: font];
        break;

    case NSRemoveTraitFontAction:
        font = [self convertFont: font toNotHaveTrait: _currentTrait];
        break;
    }

    return font;
}

- (NSFont *) convertFont: (NSFont *) font toSize: (CGFloat) size {
    /* The nil guard every other converter in this file has, and this one did not. */
    if (font == nil) {
        return nil;
    }

    if (size == [font pointSize])
        return font;

    /* AND THE ORIGINAL WHEN THE NEW SIZE CANNOT BE BUILT. fontWithName answers nil for a name it
     * cannot resolve, and that nil used to be the return value; Apple answers the font it was
     * given. The RTF reader stores this straight into an attributes dictionary, where a nil is not
     * a degraded font but an exception that ends the parse. */
    NSFont *converted = [NSFont fontWithName: [font fontName] size: size];

    return (converted != nil) ? converted : font;
}

- (BOOL) _canConvertFont: (NSFont *) font
             toHaveTrait: (NSFontTraitMask) addTraits
{
    NSFontFamily *family =
            [NSFontFamily fontFamilyWithTypefaceName: [font fontName]];
    /* Same name-is-not-a-typeface-name fallback as convertFont:toHaveTrait:, so the menu item
     * enable state agrees with what the conversion will actually do. */
    if (family == nil)
        family = [NSFontFamily fontFamilyWithName: [font familyName]];
    NSFontTypeface *typeface = [family typefaceWithName: [font fontName]];
    NSFontTraitMask traits = [typeface traits];

    if (addTraits & NSItalicFontMask) {
        traits |= NSItalicFontMask;
    }

    if (addTraits & NSBoldFontMask) {
        traits |= NSBoldFontMask;
    }

    if (addTraits & NSUnboldFontMask) {
        traits &= ~NSBoldFontMask;
    }

    if (addTraits & NSUnitalicFontMask) {
        traits &= ~NSItalicFontMask;
    }

    NSFontTypeface *newface = [family typefaceWithTraits: traits];
    return newface != nil;
}

- (NSFont *) convertFont: (NSFont *) font
             toHaveTrait: (NSFontTraitMask) addTraits
{
    if (font == nil) {
        return nil;
    }

    NSFontFamily *family =
            [NSFontFamily fontFamilyWithTypefaceName: [font fontName]];
    /*
     * A FONT NAME IS NOT A TYPEFACE NAME. Our typefaces are named by their full fontconfig
     * descriptor, so a plain name like San Francisco matches none of them and the lookup above
     * answers nil, which then made every trait below start from an empty mask on a nil family.
     * convertFont:toNotHaveTrait: in this same file already goes by family name for that reason.
     */
    if (family == nil)
        family = [NSFontFamily fontFamilyWithName: [font familyName]];
    NSFontTypeface *typeface = [family typefaceWithName: [font fontName]];
    NSFontTraitMask traits = [typeface traits];
    NSFontTypeface *newface;

    if (addTraits & NSItalicFontMask)
        traits |= NSItalicFontMask;
    if (addTraits & NSBoldFontMask)
        traits |= NSBoldFontMask;
    if (addTraits & NSUnboldFontMask)
        traits &= ~NSBoldFontMask;
    if (addTraits & NSUnitalicFontMask)
        traits &= ~NSItalicFontMask;

    newface = [family typefaceWithTraits: traits];

    /*
     * A FACE THAT CANNOT BE MADE INTO A FONT IS STILL A FAILURE, and this returned nil for it.
     *
     * Finding a typeface with the traits does not guarantee that fontWithName can build an NSFont
     * from its name, and when it could not the nil went straight back to the caller. Apple never
     * answers nil here for a non nil font, and convertFont:toFace: in this same file already says so
     * in its own comment. The cost of the missing check: the RTF reader does
     *
     *     font = [manager convertFont: font toHaveTrait: NSBoldFontMask];
     *     [attributes setObject: font forKey: NSFontAttributeName];
     *
     * so a nil became "Cannot set nil objects nor nil keys" and took out the whole parse, which is
     * how Swift Publisher failed to build any document preview.
     */
    if (newface != nil) {
        NSFont *converted = [NSFont fontWithName: [newface name] size: [font pointSize]];

        if (converted != nil) {
            return converted;
        }
    }
    NSLog(@"%s failed, %@ %d", sel_getName(_cmd), [font fontName], addTraits);
    return font;
}

- (NSFont *) convertFont: (NSFont *) font
          toNotHaveTrait: (NSFontTraitMask) trait
{
    if (font == nil) {
        return nil;
    }

    NSFontFamily *family = [NSFontFamily fontFamilyWithName: [font familyName]];
    NSFontTypeface *typeface = [family typefaceWithName: [font fontName]];
    NSFontTraitMask traits = [typeface traits];
    traits &= ~trait; // remove the traits
    NSFontTypeface *newface;

    newface = [family typefaceWithTraits: traits];

    /* The same failure as convertFont:toHaveTrait: above, for the same reason. */
    if (newface != nil) {
        NSFont *converted = [NSFont fontWithName: [newface name] size: [font pointSize]];

        if (converted != nil) {
            return converted;
        }
    }
    NSLog(@"%s failed, %@ %d", sel_getName(_cmd), [font fontName], trait);
    return font;
}

- (NSFont *) convertFont: (NSFont *) font toFace: (NSString *) typeface {
    if (font == nil) {
        return nil;
    }

    NSFont *convertedFont = [NSFont fontWithName: typeface
                                            size: [font pointSize]];
    if (convertedFont) {
        return convertedFont;
    }

    // Return the original font if the conversion fails - same as Apple
    return font;
}

- (NSFont *) convertFont: (NSFont *) font toFamily: (NSString *) family {
    if (font == nil) {
        return nil;
    }

    // Get the current traits so we try and match them...
    NSFontFamily *fontFamily =
            [NSFontFamily fontFamilyWithName: [font familyName]];
    NSFontTypeface *typeface = [fontFamily typefaceWithName: [font fontName]];
    NSFontTraitMask traits = [typeface traits];
    NSFont *converted = [self fontWithFamily: family
                                      traits: traits
                                      weight: 5
                                        size: [font pointSize]];

    /* The original rather than nil when the family is not available, as above. */
    return (converted != nil) ? converted : font;
}

- (NSFont *) convertWeight: (BOOL) heavierNotLighter ofFont: (NSFont *) font {
    if (font == nil) {
        return nil;
    }

    NSLog(@"convertWeight: %d ofFont: %@ ignored", heavierNotLighter, font);
    return font;
}

- (NSDictionary *) convertAttributes: (NSDictionary *) attributes {
    NSUnimplementedMethod();
    return nil;
}

- (void) addFontTrait: sender {
    _currentTrait = [sender tag];
    _currentFontAction = NSAddTraitFontAction;

    [self sendAction];

    [self _udpdateSelectedFont];
}

- (void) modifyFont: sender {
    _currentFontAction = [sender tag];

    [self sendAction];

    [self _udpdateSelectedFont];
}

- (void) modifyFontViaPanel: sender {
    _currentFontAction = NSViaPanelFontAction;

    [self sendAction];

    [self _udpdateSelectedFont];
}

- (void) removeFontTrait: sender {
    _currentTrait = [sender tag];
    _currentFontAction = NSRemoveTraitFontAction;

    [self sendAction];

    [self _udpdateSelectedFont];
}

- (void) orderFrontFontPanel: sender {
    [[NSFontPanel sharedFontPanel] orderFront: sender];
}

- (void) orderFrontStylesPanel: sender {
    NSUnimplementedMethod();
}

#pragma mark -
#pragma mark Font Menu Support

- (BOOL) validateMenuItem: (NSMenuItem *) item {
    BOOL valid = YES;
    SEL action = [item action];
    if (action == @selector(addFontTrait:)) {
        NSInteger tag = [item tag];
        valid = [self _canConvertFont: [self selectedFont] toHaveTrait: tag];
    }
    return valid;
}

@end
