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

#import <AppKit/NSAppearance.h>

NSString *const NSAppearanceNameAqua = @"NSAppearanceNameAqua";
NSString *const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";
NSString *const NSAppearanceNameSystem = @"NSAppearanceNameSystem";
NSString *const NSAppearanceNameTouchBar = @"NSAppearanceNameTouchBar";
NSString *const NSAppearanceNameLightContent = @"NSAppearanceNameLightContent";
NSString *const NSAppearanceNameVibrantDark = @"NSAppearanceNameVibrantDark";
NSString *const NSAppearanceNameVibrantLight = @"NSAppearanceNameVibrantLight";
NSString *const NSAppearanceNameAccessibilityHighContrastAqua =
        @"NSAppearanceNameAccessibilityAqua";
NSString *const NSAppearanceNameAccessibilityHighContrastDarkAqua =
        @"NSAppearanceNameAccessibilityDarkAqua";
NSString *const NSAppearanceNameAccessibilityHighContrastSystem =
        @"NSAppearanceNameAccessibilityHighContrastSystem";
NSString *const NSAppearanceNameAccessibilityHighContrastVibrantLight =
        @"NSAppearanceNameAccessibilityVibrantLight";
NSString *const NSAppearanceNameAccessibilityHighContrastVibrantDark =
        @"NSAppearanceNameAccessibilityVibrantDark";

NSString *const NSAppearanceNameControlStrip =
        @"NSAppearanceNameControlStrip"; // Undocumented

@implementation NSAppearance

/*
 * WORSE THAN A STUB, as written: it returned [NSAppearance alloc], an object that was never
 * initialised. Anything that used it was reading uninitialised memory, and the STUB print made it
 * look deliberate.
 *
 * One instance per name, kept forever. Appearances are compared by identity in places and there
 * is no state behind them here, so handing back the same object per name is both cheaper and
 * more correct than a fresh one each call.
 */
/*
 * The appearance drawing code should consult, set around a drawing block by the caller.
 *
 * A PLAIN GLOBAL, not a stack, and not thread local. AppKit drawing here happens on one thread,
 * and a setter that pushed and popped would need a matching pop that this API does not have:
 * the caller sets it and sets it back, which is what the class method pair is for.
 *
 * Retained, because the caller is entitled to release its own reference afterwards.
 */
static NSAppearance *_ciderCurrentAppearance = nil;

+ (void) setCurrentAppearance: (NSAppearance *) appearance {
    if (_ciderCurrentAppearance != appearance) {
        [appearance retain];
        [_ciderCurrentAppearance release];
        _ciderCurrentAppearance = appearance;
    }
}

+ (NSAppearance *) currentAppearance {
    if (_ciderCurrentAppearance != nil) {
        return _ciderCurrentAppearance;
    }
    /* Never nil: a caller asking what to draw with cannot act on "nothing", and Aqua is the one
     * look this platform has. */
    return [self appearanceNamed: NSAppearanceNameAqua];
}

/*
 * AN APPEARANCE HAS TO KNOW ITS OWN NAME, which it did not: appearanceNamed: kept one instance
 * per name and then had no way to say which it was, so -name could only have lied and
 * -bestMatchFromAppearancesWithNames: could not answer at all.
 */
- (NSAppearanceName) name {
    return _name;
}

/*
 * Which of the offered names this appearance is closest to.
 *
 * ITS OWN NAME IF IT IS OFFERED, because an exact match is the best match by definition.
 * Otherwise the FIRST offered, since the caller lists them in its own order of preference and
 * this platform has one look to choose from: answering nil would leave the caller with no
 * appearance at all, which is worse than answering its first choice.
 */
- (NSAppearanceName) bestMatchFromAppearancesWithNames: (NSArray *) names {
    if (names == nil || [names count] == 0) {
        return _name;
    }
    if (_name != nil && [names containsObject: _name]) {
        return _name;
    }
    return [names objectAtIndex: 0];
}

+ (NSAppearance *) appearanceNamed: (NSAppearanceName) name {
    static NSMutableDictionary *byName = nil;
    if (byName == nil) {
        byName = [[NSMutableDictionary alloc] init];
    }
    NSAppearance *existing = (name != nil) ? [byName objectForKey: name] : nil;
    if (existing != nil) {
        return existing;
    }
    NSAppearance *appearance = [[NSAppearance alloc] init];
    if (appearance != nil) {
        appearance->_name = [name copy];
    }
    if (name != nil && appearance != nil) {
        [byName setObject: appearance forKey: name];
    }
    return appearance;
}

- (void) encodeWithCoder: (NSCoder *) aCoder {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

- (id) initWithCoder: (NSCoder *) aDecoder {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return self;
}

+ (BOOL) supportsSecureCoding
{
    return YES;
}

@end
