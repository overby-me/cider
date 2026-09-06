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

// Original - Christopher Lloyd <cjwl@objc.net>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSFontFamily.h>
#import <AppKit/NSFontTypeface.h>
#import <AppKit/NSGraphicsContext.h>

extern int O2FontAppFontGeneration(void);

@interface NSFontFamily ()
+ (NSMutableArray *) fontFamilies;
+ (void) buildFontFamilies;
@end

@implementation NSFontFamily

+ (NSMutableArray *) fontFamilies {
    static NSMutableArray *shared = nil;
    static int builtGeneration = -1;

    /* REBUILD WHEN AN APPLICATION HAS REGISTERED FONTS SINCE THIS WAS LAST BUILT.
     *
     * The list used to be built once and kept for ever, so a font registered after the first lookup
     * did not exist for any family search. iA Writer registers 19 of its own during launch and then
     * asks for one by descriptor: nothing matched, +fontWithDescriptor:size: answered nil, and the
     * nil became NSFontAttributeName in a typing-attributes dictionary, which raised. */
    if (shared == nil || builtGeneration != O2FontAppFontGeneration()) {
        [shared release];
        shared = [NSMutableArray new];
        builtGeneration = O2FontAppFontGeneration();
        [self buildFontFamilies];
    }

    return shared;
}

+ (NSArray *) allFontFamilyNames {
    NSMutableArray *result = [NSMutableArray new];
    NSArray *families = [self fontFamilies];
    int i, count = [families count];

    for (i = 0; i < count; i++) {
        NSFontFamily *family = [families objectAtIndex: i];
        NSString *name = [family name];

        /*
         * A FAMILY WITH NO NAME IS NOT A NAME, and this array is CF backed, so adding the nil
         * succeeded here and raised later: -sortUsingSelector: reported "Cannot insert nil into
         * array" with only the sort in the frames. That unwound out of
         * -[CCDocumentController applicationWillTerminate:] and Command Q stopped quitting Swift
         * Publisher at all.
         */
        if (name == nil) {
            NSLog(@"font family %d of %d has no name, skipping it", i, count);
            continue;
        }
        [result addObject: name];
    }

    [result sortUsingSelector: @selector(compare:)];

    return result;
}

+ (void) addFontFamily: (NSFontFamily *) family {
    [[self fontFamilies] addObject: family];
}

+ (NSFontFamily *) addFontFamilyWithName: (NSString *) familyName {
    NSFontFamily *family = [[self alloc] initWithName: familyName];
    [self addFontFamily: family];
    NSArray *typefaces =
            [[NSDisplay currentDisplay] fontTypefacesForFamilyName: familyName];
    [family addTypefaces: typefaces];
    return [family autorelease];
}

+ (void) buildFontFamilies {
    NSSet *initialFamilyNames = [[NSDisplay currentDisplay] allFontFamilyNames];
    for (NSString *familyName in initialFamilyNames) {
        [self addFontFamilyWithName: familyName];
    }
}

+ (NSFontFamily *) fontFamilyWithName: (NSString *) name {
    NSArray *families = [self fontFamilies];
    int i, count = [families count];

    /*
     * THERE IS NO FAMILY WITH NO NAME. Pretending below is what this method does for a family it
     * has not heard of, and asked for nil it pretended to have THAT and registered it for the rest
     * of the process: one nameless family sat at the end of the list and every later
     * +allFontFamilyNames carried a nil.
     */
    if (name == nil)
        return nil;

    for (i = 0; i < count; i++) {
        NSFontFamily *check = [families objectAtIndex: i];

        if ([[check name] isEqualToString: name])
            return check;
    }
    // Pretend to have this family.
    return [self addFontFamilyWithName: name];
}

+ (NSFontFamily *) fontFamilyWithTypefaceName: (NSString *) name {
    NSArray *families = [self fontFamilies];
    int i, count = [families count];

    for (i = 0; i < count; i++) {
        NSFontFamily *check = [families objectAtIndex: i];
        NSFontTypeface *typeface = [check typefaceWithName: name];

        if (typeface != nil)
            return check;
    }
    // TODO: pretend to have this family.
    return nil;
}

+ (NSFontTypeface *) fontTypefaceWithName: (NSString *) name {
    NSArray *families = [self fontFamilies];
    int i, count = [families count];

    for (i = 0; i < count; i++) {
        NSFontFamily *check = [families objectAtIndex: i];
        NSFontTypeface *typeface = [check typefaceWithName: name];

        if (typeface != nil)
            return typeface;
    }

    return nil;
}

- initWithName: (NSString *) name {
    _name = [name copy];
    _typefaces = [NSMutableArray new];
    return self;
}

- (void) dealloc {
    [_name release];
    [_typefaces release];
    [super dealloc];
}

- (NSString *) name {
    return _name;
}

- (NSFontTypeface *) typefaceWithName: (NSString *) name {
    int i, count = [_typefaces count];

    for (i = 0; i < count; i++) {
        NSFontTypeface *typeface = [_typefaces objectAtIndex: i];

        if ([[typeface name] isEqualToString: name])
            return typeface;
    }

    return nil;
}

/*
 * BOLD AND ITALIC ARE THE ONLY TRAITS A CALLER IS ASKING ABOUT, so match on those two bits and
 * score the rest, the way Apple picks a face rather than demanding an identical mask.
 *
 * An exact == here found nothing for any real family, because our faces carry the fontconfig
 * derived extras: DejaVu Sans Bold is NSUnitalicFontMask|NSBoldFontMask, not NSBoldFontMask, and
 * a caller adding NSItalicFontMask to it produces a mask that contradicts itself (both italic and
 * unitalic) and can never equal any face. That is why convertFont:toHaveTrait: failed 1059 times in
 * one Swift Publisher startup and every styled run fell back to the plain face.
 */
- (NSFontTypeface *) typefaceWithTraits: (NSFontTraitMask) traits {
    int i, count = [_typefaces count];
    BOOL wantBold = (traits & NSBoldFontMask) && !(traits & NSUnboldFontMask);
    BOOL wantItalic = (traits & NSItalicFontMask) && !(traits & NSUnitalicFontMask);
    NSFontTypeface *best = nil;
    int bestScore = -1;

    for (i = 0; i < count; i++) {
        NSFontTypeface *typeface = [_typefaces objectAtIndex: i];
        NSFontTraitMask have = [typeface traits];
        BOOL isBold = (have & NSBoldFontMask) != 0;
        BOOL isItalic = (have & NSItalicFontMask) != 0;

        if (isBold != wantBold || isItalic != wantItalic)
            continue;

        /* Among the faces that carry the asked-for bold and italic, prefer the one that matches the
         * width the caller asked for, so a plain request never lands on a condensed face. */
        int score = 0;
        if ((traits & NSNarrowFontMask) == (have & NSNarrowFontMask))
            score++;
        if ((traits & NSExpandedFontMask) == (have & NSExpandedFontMask))
            score++;
        if (score > bestScore) {
            bestScore = score;
            best = typeface;
        }
    }

    return best;
}

- (void) addTypeface: (NSFontTypeface *) typeface {
    [_typefaces addObject: typeface];
}

- (void) addTypefaces: (NSArray *) typefaces {
    [_typefaces addObjectsFromArray: typefaces];
}

- (NSArray *) typefaces {
    return _typefaces;
}

- (NSString *) description {
    return [NSString stringWithFormat: @"<%@ 0x%x %@ %@>", [self class], self,
                                       _name, _typefaces];
}
@end
