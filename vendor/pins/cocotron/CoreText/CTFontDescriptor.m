#import <CoreText/CTFontDescriptor.h>

#include <stdio.h>

const CFStringRef kCTFontURLAttribute = CFSTR("NSCTFontFileURLAttribute");
const CFStringRef kCTFontNameAttribute = CFSTR("NSFontNameAttribute");
const CFStringRef kCTFontDisplayNameAttribute = CFSTR("NSFontVisibleNameAttribute");
const CFStringRef kCTFontFamilyNameAttribute = CFSTR("NSFontFamilyAttribute");
const CFStringRef kCTFontStyleNameAttribute = CFSTR("NSFontFaceAttribute");
const CFStringRef kCTFontTraitsAttribute = CFSTR("NSCTFontTraitsAttribute");
const CFStringRef kCTFontVariationAttribute = CFSTR("NSCTFontVariationAttribute");
// The AXES of a variable font, as opposed to kCTFontVariationAttribute, which is a chosen
// setting. LibreOffice binds this EAGERLY through libskialo, so its absence is not a missing
// feature but a process that will not start: a two level namespace binary resolves data symbols
// at load, and dyld aborts on the first one it cannot find.
const CFStringRef kCTFontVariationAxesAttribute = CFSTR("NSCTFontVariationAxesAttribute");
const CFStringRef kCTFontSizeAttribute = CFSTR("NSFontSizeAttribute");
const CFStringRef kCTFontMatrixAttribute = CFSTR("NSCTFontMatrixAttribute");
const CFStringRef kCTFontCascadeListAttribute = CFSTR("NSCTFontCascadeListAttribute");
const CFStringRef kCTFontCharacterSetAttribute = CFSTR("NSCTFontCharacterSetAttribute");
const CFStringRef kCTFontLanguagesAttribute = CFSTR("NSCTFontLanguagesAttribute");
const CFStringRef kCTFontBaselineAdjustAttribute = CFSTR("NSCTFontBaselineAdjustAttribute");
const CFStringRef kCTFontMacintoshEncodingsAttribute = CFSTR("NSCTFontMacintoshEncodingsAttribute");
const CFStringRef kCTFontFeaturesAttribute = CFSTR("NSCTFontFeaturesAttribute");
const CFStringRef kCTFontFeatureSettingsAttribute = CFSTR("NSCTFontFeatureSettingsAttribute");
const CFStringRef kCTFontFixedAdvanceAttribute = CFSTR("NSCTFontFixedAdvanceAttribute");
const CFStringRef kCTFontOrientationAttribute = CFSTR("NSCTFontOrientationAttribute");
const CFStringRef kCTFontEnabledAttribute = CFSTR("NSCTFontEnabledAttribute");
const CFStringRef kCTFontFormatAttribute = CFSTR("NSCTFontFormatAttribute");
const CFStringRef kCTFontRegistrationScopeAttribute = CFSTR("NSCTFontRegistrationScopeAttribute");
const CFStringRef kCTFontPriorityAttribute = CFSTR("NSCTFontPriorityAttribute");

/*
 * A descriptor is the attribute dictionary CTFontCollection built, so this is a lookup. The name
 * begins with Copy, so the caller owns the result and it is retained here.
 */
CFTypeRef CTFontDescriptorCopyAttribute(CTFontDescriptorRef descriptor, CFStringRef attribute)
{
    if (descriptor == NULL || attribute == NULL) return NULL;
    CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)descriptor, attribute);
    return value ? CFRetain(value) : NULL;
}

/*
 * THE SAME ANSWER, AND THE LANGUAGE OUT PARAMETER IS SET TO NULL rather than left alone. The
 * caller owns whatever comes back through it and will release it, so leaving it untouched is
 * the same defect that made CTFontManagerRegisterFontsForURL crash a correct caller.
 *
 * Nothing here is localised: fontconfig reports one family name per font and there is no table
 * of translations to consult, so answering the unlocalised name is honest and answering nothing
 * would lose the font entirely.
 */
CFTypeRef CTFontDescriptorCopyLocalizedAttribute(CTFontDescriptorRef descriptor,
        CFStringRef attribute, CFStringRef *language)
{
    if (language != NULL) *language = NULL;
    return CTFontDescriptorCopyAttribute(descriptor, attribute);
}

/*
 * A DESCRIPTOR IS THE ATTRIBUTE DICTIONARY in this port -- CTFontCollection builds one per face and
 * CTFontDescriptorCopyAttribute reads straight out of it -- so creating one from attributes is a
 * copy, and the stub that returned NULL was the reason an application could not ask for a font by
 * anything except a family name. LibreOffice calls this 53 times in a single run.
 */
CTFontDescriptorRef CTFontDescriptorCreateWithAttributes(CFDictionaryRef attributes)
{
    if (attributes == NULL) return NULL;
    return (CTFontDescriptorRef) CFDictionaryCreateCopy(kCFAllocatorDefault, attributes);
}
