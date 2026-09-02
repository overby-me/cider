#import <CoreText/CTFontDescriptor.h>
#import <CoreText/CTFontCollection.h>
#include <stdlib.h>

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

/*
 * WHICH INSTALLED FACES ANSWER A DESCRIPTION. A descriptor here is its attribute dictionary and the
 * collection of available fonts is an array of exactly such dictionaries, so matching is comparing
 * the attributes the caller cares about against each face.
 *
 * MANDATORY ATTRIBUTES ARE THE ONES THAT MUST AGREE. macOS matches on those and treats the rest as
 * preferences to rank by; with none given it matches on every attribute the query carries, and a
 * face that has no opinion on an attribute is not rejected for it. Nothing here ranks, so the order
 * is the collection's.
 *
 * LibreOffice ships Skia, which asks for these two by name and cannot start without them.
 */
static Boolean _CiderDescriptorMatches(CFDictionaryRef face, CFDictionaryRef query,
                                       CFSetRef mandatory)
{
    CFIndex count = CFDictionaryGetCount(query);
    const void **keys = malloc(sizeof(void *) * (count > 0 ? count : 1));
    const void **values = malloc(sizeof(void *) * (count > 0 ? count : 1));
    Boolean matches = true;

    CFDictionaryGetKeysAndValues(query, keys, values);
    for (CFIndex i = 0; i < count && matches; i++) {
        const void *faceValue;

        if (mandatory != NULL && !CFSetContainsValue(mandatory, keys[i]))
            continue;
        if (!CFDictionaryGetValueIfPresent(face, keys[i], &faceValue)) {
            /* Unknown to the face: mandatory means it fails, otherwise it is simply not an opinion. */
            matches = (mandatory == NULL);
            continue;
        }
        matches = CFEqual(faceValue, values[i]);
    }
    free(keys);
    free(values);
    return matches;
}

CFArrayRef CTFontDescriptorCreateMatchingFontDescriptors(CTFontDescriptorRef descriptor,
                                                         CFSetRef mandatoryAttributes)
{
    CTFontCollectionRef collection;
    CFArrayRef available;
    CFMutableArrayRef result;
    CFIndex count;

    if (descriptor == NULL) return NULL;

    collection = CTFontCollectionCreateFromAvailableFonts(NULL);
    if (collection == NULL) return NULL;

    available = CTFontCollectionCreateMatchingFontDescriptors(collection);
    CFRelease(collection);
    if (available == NULL) return NULL;

    result = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    count = CFArrayGetCount(available);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef face = (CFDictionaryRef) CFArrayGetValueAtIndex(available, i);

        if (_CiderDescriptorMatches(face, (CFDictionaryRef) descriptor, mandatoryAttributes))
            CFArrayAppendValue(result, face);
    }
    CFRelease(available);
    return result;
}

CTFontDescriptorRef CTFontDescriptorCreateMatchingFontDescriptor(CTFontDescriptorRef descriptor,
                                                                 CFSetRef mandatoryAttributes)
{
    CFArrayRef all = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatoryAttributes);
    CTFontDescriptorRef first = NULL;

    if (all != NULL) {
        if (CFArrayGetCount(all) > 0)
            first = (CTFontDescriptorRef) CFRetain(CFArrayGetValueAtIndex(all, 0));
        CFRelease(all);
    }
    return first;
}
