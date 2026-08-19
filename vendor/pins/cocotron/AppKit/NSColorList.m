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

#import <AppKit/NSColorList.h>
#import <AppKit/NSRaise.h>

NSString *const NSColorListDidChangeNotification =
        @"NSColorListDidChangeNotification";

@implementation NSColorList

static NSMutableDictionary *_namedColorLists = nil;

+ (void) _createDefaultColorLists {
    static struct WebColor {
        NSString *name;
        unsigned value;
    } webColors[217] = {{@"Alice Blue", 0xF0F8FF},
                        {@"Antique White", 0xFAEBD7},
                        {@"Aqua", 0x00FFFF},
                        {@"Aquamarine", 0x7FFFD4},
                        {@"Azure", 0xF0FFFF},
                        {@"Beige", 0xF5F5DC},
                        {@"Bisque", 0xFFE4C4},
                        {@"Black", 0x000000},
                        {@"Blanched Almond", 0xFFEBCD},
                        {@"Blue", 0x0000FF},
                        {@"Blue Violet", 0x8A2BE2},
                        {@"Brown", 0xA52A2A},
                        {@"Burly Wood", 0xDEB887},
                        {@"Cadet Blue", 0x5F9EA0},
                        {@"Chartreuse", 0x7FFF00},
                        {@"Chocolate", 0xD2691E},
                        {@"Coral", 0xFF7F50},
                        {@"Cornflower Blue", 0x6495ED},
                        {@"Cornsilk", 0xFFF8DC},
                        {@"Crimson", 0xDC143C},
                        {@"Cyan", 0x00FFFF},
                        {@"Dark Blue", 0x00008B},
                        {@"Dark Cyan", 0x008B8B},
                        {@"Dark GoldenRod", 0xB8860B},
                        {@"Dark Gray", 0xA9A9A9},
                        {@"Dark Green", 0x006400},
                        {@"Dark Khaki", 0xBDB76B},
                        {@"Dark Magenta", 0x8B008B},
                        {@"Dark Olive Green", 0x556B2F},
                        {@"Dark Orange", 0xFF8C00},
                        {@"Dark Orchid", 0x9932CC},
                        {@"Dark Red", 0x8B0000},
                        {@"Dark Salmon", 0xE9967A},
                        {@"Dark Sea Green", 0x8FBC8F},
                        {@"Dark Slate Blue", 0x483D8B},
                        {@"Dark Slate Gray", 0x2F4F4F},
                        {@"Dark Turquoise", 0x00CED1},
                        {@"Dark Violet", 0x9400D3},
                        {@"Deep Pink", 0xFF1493},
                        {@"Deep Sky Blue", 0x00BFFF},
                        {@"Dim Gray", 0x696969},
                        {@"Dodger Blue", 0x1E90FF},
                        {@"Fire Brick", 0xB22222},
                        {@"Floral White", 0xFFFAF0},
                        {@"Forest Green", 0x228B22},
                        {@"Gainsboro", 0xDCDCDC},
                        {@"Ghost White", 0xF8F8FF},
                        {@"Gold", 0xFFD700},
                        {@"Golden Rod", 0xDAA520},
                        {@"Gray", 0x808080},
                        {@"Green", 0x008000},
                        {@"Green Yellow", 0xADFF2F},
                        {@"Honey Dew", 0xF0FFF0},
                        {@"Hot Pink", 0xFF69B4},
                        {@"Indian Red", 0xCD5C5C},
                        {@"Indigo", 0x4B0082},
                        {@"Ivory", 0xFFFFF0},
                        {@"Khaki", 0xF0E68C},
                        {@"Lavender", 0xE6E6FA},
                        {@"Lavender Blush", 0xFFF0F5},
                        {@"Lawn Green", 0x7CFC00},
                        {@"Lemon Chiffon", 0xFFFACD},
                        {@"Light Blue", 0xADD8E6},
                        {@"Light Coral", 0xF08080},
                        {@"Light Cyan", 0xE0FFFF},
                        {@"Light Golden Rod Yellow", 0xFAFAD2},
                        {@"Light Gray", 0xD3D3D3},
                        {@"Light Green", 0x90EE90},
                        {@"Light Pink", 0xFFB6C1},
                        {@"Light Salmon", 0xFFA07A},
                        {@"Light Sea Green", 0x20B2AA},
                        {@"Light Sky Blue", 0x87CEFA},
                        {@"Light Slate Blue", 0x8470FF},
                        {@"Light Slate Gray", 0x778899},
                        {@"Light Steel Blue", 0xB0C4DE},
                        {@"Light Yellow", 0xFFFFE0},
                        {@"Lime", 0x00FF00},
                        {@"Lime Green", 0x32CD32},
                        {@"Linen", 0xFAF0E6},
                        {@"Magenta", 0xFF00FF},
                        {@"Maroon", 0x800000},
                        {@"Medium Aqua Marine", 0x66CDAA},
                        {@"Medium Blue", 0x0000CD},
                        {@"Medium Orchid", 0xBA55D3},
                        {@"Medium Purple", 0x9370D8},
                        {@"Medium Sea Green", 0x3CB371},
                        {@"Medium Slate Blue", 0x7B68EE},
                        {@"Medium Spring Green", 0x00FA9A},
                        {@"Medium Turquoise", 0x48D1CC},
                        {@"Medium Violet Red", 0xC71585},
                        {@"Midnight Blue", 0x191970},
                        {@"Mint Cream", 0xF5FFFA},
                        {@"Misty Rose", 0xFFE4E1},
                        {@"Moccasin", 0xFFE4B5},
                        {@"Navajo White", 0xFFDEAD},
                        {@"Navy", 0x000080},
                        {@"Old Lace", 0xFDF5E6},
                        {@"Olive", 0x808000},
                        {@"Olive Drab", 0x6B8E23},
                        {@"Orange", 0xFFA500},
                        {@"Orange Red", 0xFF4500},
                        {@"Orchid", 0xDA70D6},
                        {@"Pale Golden Rod", 0xEEE8AA},
                        {@"Pale Green", 0x98FB98},
                        {@"Pale Turquoise", 0xAFEEEE},
                        {@"PaleViolet Red", 0xD87093},
                        {@"Papaya Whip", 0xFFEFD5},
                        {@"Peach Puff", 0xFFDAB9},
                        {@"Peru", 0xCD853F},
                        {@"Pink", 0xFFC0CB},
                        {@"Plum", 0xDDA0DD},
                        {@"Powder Blue", 0xB0E0E6},
                        {@"Purple", 0x800080},
                        {@"Red", 0xFF0000},
                        {@"Rosy Brown", 0xBC8F8F},
                        {@"Royal Blue", 0x4169E1},
                        {@"Saddle Brown", 0x8B4513},
                        {@"Salmon", 0xFA8072},
                        {@"Sandy Brown", 0xF4A460},
                        {@"Sea Green", 0x2E8B57},
                        {@"Sea Shell", 0xFFF5EE},
                        {@"Sienna", 0xA0522D},
                        {@"Silver", 0xC0C0C0},
                        {@"Sky Blue", 0x87CEEB},
                        {@"Slate Blue", 0x6A5ACD},
                        {@"Slate Gray", 0x708090},
                        {@"Snow", 0xFFFAFA},
                        {@"Spring Green", 0x00FF7F},
                        {@"Steel Blue", 0x4682B4},
                        {@"Tan", 0xD2B48C},
                        {@"Teal", 0x008080},
                        {@"Thistle", 0xD8BFD8},
                        {@"Tomato", 0xFF6347},
                        {@"Turquoise", 0x40E0D0},
                        {@"Violet", 0xEE82EE},
                        {@"Violet Red", 0xD02090},
                        {@"Wheat", 0xF5DEB3},
                        {@"White", 0xFFFFFF},
                        {@"White Smoke", 0xF5F5F5},
                        {@"Yellow", 0xFFFF00},
                        {@"Yellow Green", 0x9ACD32},
                        {nil, 0x0}};

    /* THE FOUR LISTS macOS SHIPS, by the names it ships them under. Two of these already existed
     * under names of this framework's own invention, which is why an application asking for the
     * standard ones by name got nothing: "Basic" is Apple's classic palette and "Web" is the
     * HTML named colours, so the first is renamed and the second takes the slot macOS calls
     * "Web Safe Colors". Its CONTENTS are still the HTML names rather than the 216 web safe
     * values, which is a difference nothing here checks yet.
     *
     * Crayons is new. The 36 chromatic crayons are the documented grid (a hue wheel at full
     * saturation, then tinted, then shaded); the 12 greys are a regular ramp rather than the
     * exact macOS steps, which were not transcribed. */
    NSColorList *appleColorList =
            [[[NSColorList alloc] initWithName: @"Apple"] autorelease];
    NSColorList *crayonsColorList =
            [[[NSColorList alloc] initWithName: @"Crayons"] autorelease];
    NSColorList *systemColorList =
            [[[NSColorList alloc] initWithName: @"System"] autorelease];
    NSColorList *webColorList =
            [[[NSColorList alloc] initWithName: @"Web Safe Colors"] autorelease];
    int i;

    struct {
        NSString *name;
        unsigned value;
    } crayons[] = {
                        {@"Maraschino", 0xFF0000},
                        {@"Tangerine", 0xFF8000},
                        {@"Lemon", 0xFFFF00},
                        {@"Lime", 0x80FF00},
                        {@"Spring", 0x00FF00},
                        {@"Sea Foam", 0x00FF80},
                        {@"Turquoise", 0x00FFFF},
                        {@"Aqua", 0x0080FF},
                        {@"Blueberry", 0x0000FF},
                        {@"Grape", 0x8000FF},
                        {@"Magenta", 0xFF00FF},
                        {@"Strawberry", 0xFF0080},
                        {@"Salmon", 0xFF6666},
                        {@"Cantaloupe", 0xFFCC66},
                        {@"Banana", 0xFFFF66},
                        {@"Honeydew", 0xCCFF66},
                        {@"Flora", 0x66FF66},
                        {@"Spindrift", 0x66FFCC},
                        {@"Ice", 0x66FFFF},
                        {@"Sky", 0x66CCFF},
                        {@"Orchid", 0x6666FF},
                        {@"Lavender", 0xCC66FF},
                        {@"Bubblegum", 0xFF66FF},
                        {@"Carnation", 0xFF66CC},
                        {@"Cayenne", 0x800000},
                        {@"Mocha", 0x804000},
                        {@"Asparagus", 0x808000},
                        {@"Fern", 0x408000},
                        {@"Clover", 0x008000},
                        {@"Moss", 0x008040},
                        {@"Teal", 0x008080},
                        {@"Ocean", 0x004080},
                        {@"Midnight", 0x000080},
                        {@"Eggplant", 0x400080},
                        {@"Plum", 0x800080},
                        {@"Maroon", 0x800040},
                        {@"Snow", 0xFFFFFF},
                        {@"Mercury", 0xE8E8E8},
                        {@"Silver", 0xD1D1D1},
                        {@"Magnesium", 0xBABABA},
                        {@"Aluminum", 0xA2A2A2},
                        {@"Nickel", 0x8B8B8B},
                        {@"Tin", 0x747474},
                        {@"Steel", 0x5D5D5D},
                        {@"Tungsten", 0x464646},
                        {@"Iron", 0x2E2E2E},
                        {@"Lead", 0x171717},
                        {@"Licorice", 0x000000},
                        {nil, 0x0}};

    /* THE SYSTEM LISTS ARE NOT EDITABLE, and saying so is the whole point of the flag: an
     * application asks before offering to edit, and mutating one raises. setColor:forKey: below
     * is deliberately not guarded, because that is how the framework fills them and how the
     * display backend seeds a catalogue colour it has just answered. */
    appleColorList->_isEditable = NO;
    crayonsColorList->_isEditable = NO;
    systemColorList->_isEditable = NO;
    webColorList->_isEditable = NO;

    for (i = 0; webColors[i].name != nil; i++) {
        unsigned value = webColors[i].value;
        CGFloat red = ((value >> 16) & 0xFF) / 255.0;
        CGFloat green = ((value >> 8) & 0xFF) / 255.0;
        CGFloat blue = (value & 0xFF) / 255.0;
        NSColor *color = [NSColor colorWithCalibratedRed: red
                                                   green: green
                                                    blue: blue
                                                   alpha: 1.0];

        [webColorList setColor: color forKey: webColors[i].name];
    }

    for (i = 0; crayons[i].name != nil; i++) {
        unsigned value = crayons[i].value;
        CGFloat red = ((value >> 16) & 0xFF) / 255.0;
        CGFloat green = ((value >> 8) & 0xFF) / 255.0;
        CGFloat blue = (value & 0xFF) / 255.0;

        [crayonsColorList setColor: [NSColor colorWithCalibratedRed: red
                                                              green: green
                                                               blue: blue
                                                              alpha: 1.0]
                            forKey: crayons[i].name];
    }

    [appleColorList setColor: [NSColor blackColor] forKey: @"Black"];
    [appleColorList setColor: [NSColor blueColor] forKey: @"Blue"];
    [appleColorList setColor: [NSColor brownColor] forKey: @"Brown"];
    [appleColorList setColor: [NSColor cyanColor] forKey: @"Cyan"];
    [appleColorList setColor: [NSColor greenColor] forKey: @"Green"];
    [appleColorList setColor: [NSColor magentaColor] forKey: @"Magenta"];
    [appleColorList setColor: [NSColor orangeColor] forKey: @"Orange"];
    [appleColorList setColor: [NSColor purpleColor] forKey: @"Purple"];
    [appleColorList setColor: [NSColor redColor] forKey: @"Red"];
    [appleColorList setColor: [NSColor yellowColor] forKey: @"Yellow"];
    [appleColorList setColor: [NSColor whiteColor] forKey: @"White"];

    /* THE SYSTEM LIST IS THE KEYS macOS PUBLISHES, exactly these and no others. The older names
     * this list used to carry (controlHighlightColor, knobColor, scrollBarColor and the rest) are
     * still answered by NSColor: a class method here goes to the DISPLAY for its value, not to
     * this list, so what is in the list decides what a colour panel offers and nothing else. */
    [systemColorList setColor: [NSColor alternateSelectedControlTextColor]
                       forKey: @"alternateSelectedControlTextColor"];
    [systemColorList setColor: [NSColor alternatingContentBackgroundColor]
                       forKey: @"alternatingContentBackgroundColor"];
    [systemColorList setColor: [NSColor controlAccentColor]
                       forKey: @"controlAccentColor"];
    [systemColorList setColor: [NSColor controlBackgroundColor]
                       forKey: @"controlBackgroundColor"];
    [systemColorList setColor: [NSColor controlColor]
                       forKey: @"controlColor"];
    [systemColorList setColor: [NSColor controlTextColor]
                       forKey: @"controlTextColor"];
    [systemColorList setColor: [NSColor disabledControlTextColor]
                       forKey: @"disabledControlTextColor"];
    [systemColorList setColor: [NSColor findHighlightColor]
                       forKey: @"findHighlightColor"];
    [systemColorList setColor: [NSColor gridColor]
                       forKey: @"gridColor"];
    [systemColorList setColor: [NSColor headerTextColor]
                       forKey: @"headerTextColor"];
    [systemColorList setColor: [NSColor keyboardFocusIndicatorColor]
                       forKey: @"keyboardFocusIndicatorColor"];
    [systemColorList setColor: [NSColor labelColor]
                       forKey: @"labelColor"];
    [systemColorList setColor: [NSColor linkColor]
                       forKey: @"linkColor"];
    [systemColorList setColor: [NSColor placeholderTextColor]
                       forKey: @"placeholderTextColor"];
    [systemColorList setColor: [NSColor quaternaryLabelColor]
                       forKey: @"quaternaryLabelColor"];
    [systemColorList setColor: [NSColor quaternarySystemFillColor]
                       forKey: @"quaternarySystemFillColor"];
    [systemColorList setColor: [NSColor quinaryLabelColor]
                       forKey: @"quinaryLabelColor"];
    [systemColorList setColor: [NSColor quinarySystemFillColor]
                       forKey: @"quinarySystemFillColor"];
    [systemColorList setColor: [NSColor secondaryLabelColor]
                       forKey: @"secondaryLabelColor"];
    [systemColorList setColor: [NSColor secondarySystemFillColor]
                       forKey: @"secondarySystemFillColor"];
    [systemColorList setColor: [NSColor selectedContentBackgroundColor]
                       forKey: @"selectedContentBackgroundColor"];
    [systemColorList setColor: [NSColor selectedControlColor]
                       forKey: @"selectedControlColor"];
    [systemColorList setColor: [NSColor selectedControlTextColor]
                       forKey: @"selectedControlTextColor"];
    [systemColorList setColor: [NSColor selectedMenuItemTextColor]
                       forKey: @"selectedMenuItemTextColor"];
    [systemColorList setColor: [NSColor selectedTextBackgroundColor]
                       forKey: @"selectedTextBackgroundColor"];
    [systemColorList setColor: [NSColor selectedTextColor]
                       forKey: @"selectedTextColor"];
    [systemColorList setColor: [NSColor separatorColor]
                       forKey: @"separatorColor"];
    [systemColorList setColor: [NSColor systemBlueColor]
                       forKey: @"systemBlueColor"];
    [systemColorList setColor: [NSColor systemBrownColor]
                       forKey: @"systemBrownColor"];
    [systemColorList setColor: [NSColor systemCyanColor]
                       forKey: @"systemCyanColor"];
    [systemColorList setColor: [NSColor systemFillColor]
                       forKey: @"systemFillColor"];
    [systemColorList setColor: [NSColor systemGrayColor]
                       forKey: @"systemGrayColor"];
    [systemColorList setColor: [NSColor systemGreenColor]
                       forKey: @"systemGreenColor"];
    [systemColorList setColor: [NSColor systemIndigoColor]
                       forKey: @"systemIndigoColor"];
    [systemColorList setColor: [NSColor systemMintColor]
                       forKey: @"systemMintColor"];
    [systemColorList setColor: [NSColor systemOrangeColor]
                       forKey: @"systemOrangeColor"];
    [systemColorList setColor: [NSColor systemPinkColor]
                       forKey: @"systemPinkColor"];
    [systemColorList setColor: [NSColor systemPurpleColor]
                       forKey: @"systemPurpleColor"];
    [systemColorList setColor: [NSColor systemRedColor]
                       forKey: @"systemRedColor"];
    [systemColorList setColor: [NSColor systemTealColor]
                       forKey: @"systemTealColor"];
    [systemColorList setColor: [NSColor systemYellowColor]
                       forKey: @"systemYellowColor"];
    [systemColorList setColor: [NSColor tertiaryLabelColor]
                       forKey: @"tertiaryLabelColor"];
    [systemColorList setColor: [NSColor tertiarySystemFillColor]
                       forKey: @"tertiarySystemFillColor"];
    [systemColorList setColor: [NSColor textBackgroundColor]
                       forKey: @"textBackgroundColor"];
    [systemColorList setColor: [NSColor textColor]
                       forKey: @"textColor"];
    [systemColorList setColor: [NSColor underPageBackgroundColor]
                       forKey: @"underPageBackgroundColor"];
    [systemColorList setColor: [NSColor unemphasizedSelectedContentBackgroundColor]
                       forKey: @"unemphasizedSelectedContentBackgroundColor"];
    [systemColorList setColor: [NSColor unemphasizedSelectedTextBackgroundColor]
                       forKey: @"unemphasizedSelectedTextBackgroundColor"];
    [systemColorList setColor: [NSColor unemphasizedSelectedTextColor]
                       forKey: @"unemphasizedSelectedTextColor"];
    [systemColorList setColor: [NSColor windowBackgroundColor]
                       forKey: @"windowBackgroundColor"];
    [systemColorList setColor: [NSColor windowFrameTextColor]
                       forKey: @"windowFrameTextColor"];

    _namedColorLists = [[NSMutableDictionary alloc] init];
    [_namedColorLists setObject: appleColorList forKey: @"Apple"];
    [_namedColorLists setObject: crayonsColorList forKey: @"Crayons"];
    [_namedColorLists setObject: systemColorList forKey: @"System"];
    [_namedColorLists setObject: webColorList forKey: @"Web Safe Colors"];
}

+ (NSArray *) availableColorLists {
    if (_namedColorLists == nil)
        [NSColorList _createDefaultColorLists];

    return [_namedColorLists allValues];
}

- initWithName: (NSString *) name fromFile: (NSString *) path {
    _keys = [[NSMutableArray alloc] init];
    _colors = [[NSMutableArray alloc] init];
    _name = [name copy];
    _path = [path copy];
    /* Editable by default: an application that makes a list means to fill it. The framework marks
     * its own system lists otherwise, just below. */
    _isEditable = YES;

    if (_path != nil) {
        // FIX, file loading doesnt work for NSColorList
        // DYFIX: load list
    }

    return self;
}

- initWithName: (NSString *) name {
    return [self initWithName: name fromFile: nil];
}

- (void) dealloc {
    [_keys release];
    [_colors release];
    [_name release];
    [_path release];

    [super dealloc];
}

+ (NSColorList *) colorListNamed: (NSString *) name {
    if (_namedColorLists == nil)
        [NSColorList _createDefaultColorLists];

    return [_namedColorLists objectForKey: name];
}

- (BOOL) isEditable {
    return _isEditable;
}

- (NSString *) name {
    return _name;
}

- (NSArray *) allKeys {
    return _keys;
}

- (NSColor *) colorWithKey: (NSString *) soughtKey
                  indexPtr: (unsigned *) index
{
    NSEnumerator *keyEnumerator = [_keys objectEnumerator];
    NSString *thisKey;

    *index = 0;
    while ((thisKey = [keyEnumerator nextObject]) != nil) {
        if ([thisKey isEqualToString: soughtKey])
            return [_colors objectAtIndex: *index];
        (*index)++;
    }

    return nil;
}

- (NSColor *) colorWithKey: (NSString *) soughtKey {
    unsigned index; // unused
    return [self colorWithKey: soughtKey indexPtr: &index];
}

- (void) setColor: (NSColor *) color forKey: (NSString *) key {
    unsigned index;

    // if we already have a color with this key, replace it...
    if ([self colorWithKey: key indexPtr: &index])
        [_colors replaceObjectAtIndex: index withObject: color];
    else {
        [_keys addObject: key]; // otherwise the color/key combo are added to
                                // the end of the list
        [_colors addObject: color];
    }

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSColorListDidChangeNotification
                          object: self];
}

- (void) removeColorWithKey: (NSString *) key {
    unsigned index;

    if ([self colorWithKey: key indexPtr: &index]) {
        [_colors removeObjectAtIndex: index];
        [_keys removeObjectAtIndex: index];

        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSColorListDidChangeNotification
                              object: self];
    }
}

- (void) insertColor: (NSColor *) color
                 key: (NSString *) key
             atIndex: (unsigned) index
{
    /* A SYSTEM LIST REFUSES BY RAISING, which is how an application learns it may not edit one.
     * Ours inserted into it happily, so a caller that offered the user an editable list of system
     * colours was told nothing at all and the edit simply did not survive. */
    if (![self isEditable]) {
        [NSException raise: NSColorListNotEditableException
                    format: @"color list %@ is not editable", _name];
        return;
    }

    [_colors insertObject: color atIndex: index];
    [_keys insertObject: key atIndex: index];

    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSColorListDidChangeNotification
                          object: self];
}

- (void) writeToFile: (NSString *) path {
    NSUnimplementedMethod();
}

- (void) removeFile {
    [[NSFileManager defaultManager] removeFileAtPath: _path handler: nil];
}

@end
