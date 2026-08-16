#import <CoreText/CTFontCollection.h>
#import <CoreText/CTFontDescriptor.h>
#import <CoreText/CTFontTraits.h>
#import <fontconfig/fontconfig.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <strings.h>

/*
 * THE TRAIT KEYS ARE DEFINED AND NEVER DECLARED. constants.c exports all four, and no header in
 * this tree mentions them, so a user of CoreText inside CoreText has to declare them itself.
 * They are also part of the surface LibreOffice imports, which is how they were known to exist
 * before this file needed them.
 */
extern const CFStringRef kCTFontSymbolicTrait;
extern const CFStringRef kCTFontWeightTrait;
extern const CFStringRef kCTFontWidthTrait;
extern const CFStringRef kCTFontSlantTrait;

// The only collection OPTION anything here asks for. Same reason as the variation axes key: it
// is a data symbol, so it is bound at load and a missing one is a process that never starts.
const CFStringRef kCTFontCollectionRemoveDuplicatesOption =
        CFSTR("NSCTFontCollectionRemoveDuplicatesOption");

/*
 * Font enumeration, over fontconfig.
 *
 * A COLLECTION IS A CFArray OF DESCRIPTORS and a DESCRIPTOR IS A CFDictionary OF ATTRIBUTES.
 * That is close to what they are on macOS, where a descriptor is defined by its attribute
 * dictionary, and it means CTFontDescriptorCopyAttribute is a dictionary lookup rather than a
 * new CFRuntime class with its own allocation and finalisation. Nothing in the callers asks
 * either object for its CFTypeID.
 *
 * fontconfig is the source because this fork already relies on it for the AppKit font methods,
 * where it answers 380 families on this machine, and because it is the only thing here that
 * knows which font files exist.
 */
static void _CiderAddTrait(CFMutableDictionaryRef traits, CFStringRef key, double value)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
    if (number != NULL) {
        CFDictionarySetValue(traits, key, number);
        CFRelease(number);
    }
}

static CFDictionaryRef _CiderDescriptorFromPattern(FcPattern *pattern)
{
    FcChar8 *family = NULL;
    if (FcPatternGetString(pattern, FC_FAMILY, 0, &family) != FcResultMatch || family == NULL) {
        return NULL;
    }

    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attributes == NULL) return NULL;

    CFStringRef familyName = CFStringCreateWithCString(kCFAllocatorDefault, (const char *)family,
            kCFStringEncodingUTF8);
    if (familyName != NULL) {
        CFDictionarySetValue(attributes, kCTFontFamilyNameAttribute, familyName);
        CFRelease(familyName);
    }

    FcChar8 *style = NULL;
    if (FcPatternGetString(pattern, FC_STYLE, 0, &style) == FcResultMatch && style != NULL) {
        CFStringRef styleName = CFStringCreateWithCString(kCFAllocatorDefault, (const char *)style,
                kCFStringEncodingUTF8);
        if (styleName != NULL) {
            CFDictionarySetValue(attributes, kCTFontStyleNameAttribute, styleName);
            CFRelease(styleName);
        }
    }

    /* The FILE is what makes a descriptor usable rather than merely descriptive: it is how
     * anything turns this back into an actual font. */
    FcChar8 *file = NULL;
    if (FcPatternGetString(pattern, FC_FILE, 0, &file) == FcResultMatch && file != NULL) {
        CFStringRef path = CFStringCreateWithCString(kCFAllocatorDefault, (const char *)file,
                kCFStringEncodingUTF8);
        if (path != NULL) {
            CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path,
                    kCFURLPOSIXPathStyle, false);
            if (url != NULL) {
                CFDictionarySetValue(attributes, kCTFontURLAttribute, url);
                CFRelease(url);
            }
            CFRelease(path);
        }
    }

    int slant = FC_SLANT_ROMAN, weight = FC_WEIGHT_REGULAR, width = FC_WIDTH_NORMAL, spacing = 0;
    FcPatternGetInteger(pattern, FC_SLANT, 0, &slant);
    FcPatternGetInteger(pattern, FC_WEIGHT, 0, &weight);
    FcPatternGetInteger(pattern, FC_WIDTH, 0, &width);
    FcPatternGetInteger(pattern, FC_SPACING, 0, &spacing);

    /* Symbolic traits are a bitmask; the normalised ones are -1..1 with 0 meaning regular, which
     * is why the weight arithmetic is not simply a division. */
    uint32_t symbolic = 0;
    if (slant == FC_SLANT_ITALIC || slant == FC_SLANT_OBLIQUE) symbolic |= (1u << 0);
    if (weight >= FC_WEIGHT_BOLD) symbolic |= (1u << 1);
    if (width >= FC_WIDTH_SEMIEXPANDED) symbolic |= (1u << 5);
    if (width <= FC_WIDTH_SEMICONDENSED) symbolic |= (1u << 6);
    if (spacing >= FC_MONO) symbolic |= (1u << 10);

    CFMutableDictionaryRef traits = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (traits != NULL) {
        int symbolicValue = (int)symbolic;
        CFNumberRef symbolicNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType,
                &symbolicValue);
        if (symbolicNumber != NULL) {
            CFDictionarySetValue(traits, kCTFontSymbolicTrait, symbolicNumber);
            CFRelease(symbolicNumber);
        }
        double normalisedWeight = (weight >= FC_WEIGHT_REGULAR)
                ? (double)(weight - FC_WEIGHT_REGULAR) / (double)(FC_WEIGHT_BLACK - FC_WEIGHT_REGULAR)
                : -(double)(FC_WEIGHT_REGULAR - weight) / (double)FC_WEIGHT_REGULAR;
        double normalisedWidth = (double)(width - FC_WIDTH_NORMAL) / (double)FC_WIDTH_NORMAL;
        _CiderAddTrait(traits, kCTFontWeightTrait, normalisedWeight);
        _CiderAddTrait(traits, kCTFontWidthTrait, normalisedWidth);
        _CiderAddTrait(traits, kCTFontSlantTrait, (symbolic & 1u) ? 1.0 : 0.0);
        CFDictionarySetValue(attributes, kCTFontTraitsAttribute, traits);
        CFRelease(traits);
    }

    CFDictionarySetValue(attributes, kCTFontEnabledAttribute, kCFBooleanTrue);

    /*
     * THE FORMAT IS A FILTER, not decoration. A consumer that enumerates fonts decides what it
     * can use from this: LibreOffice imports kCTFontFormatAttribute and skips what it cannot
     * rasterise, and an attribute that answers NULL reads as unusable. Leaving it out therefore
     * does not mean "unknown", it means every font is rejected and the list comes out empty.
     *
     * CTFontFormat: 1 OpenType PostScript, 2 OpenType TrueType, 3 TrueType, 4 PostScript,
     * 5 bitmap. The file extension is the only evidence available without opening the file, and
     * it is the same evidence fontconfig used to index it.
     */
    int format = 2; /* OpenType TrueType, the common case and the safe default */
    if (file != NULL) {
        const char *dot = strrchr((const char *)file, '.');
        if (dot != NULL) {
            if (strcasecmp(dot, ".pfb") == 0 || strcasecmp(dot, ".pfa") == 0) format = 4;
            else if (strcasecmp(dot, ".pcf") == 0 || strcasecmp(dot, ".bdf") == 0) format = 5;
            else if (strcasecmp(dot, ".otf") == 0) format = 1;
        }
    }
    CFNumberRef formatNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &format);
    if (formatNumber != NULL) {
        CFDictionarySetValue(attributes, kCTFontFormatAttribute, formatNumber);
        CFRelease(formatNumber);
    }
    return attributes;
}

CTFontCollectionRef CTFontCollectionCreateFromAvailableFonts(CFDictionaryRef options)
{
    FcInit();
    FcPattern *pattern = FcPatternCreate();
    FcObjectSet *props = FcObjectSetBuild(FC_FAMILY, FC_STYLE, FC_FILE, FC_SLANT, FC_WEIGHT,
            FC_WIDTH, FC_SPACING, (char *)NULL);
    /* NULL config means the current one, which is what O2FontSharedFontConfig would return and
     * is not exported here. */
    FcFontSet *set = FcFontList(NULL, pattern, props);

    CFMutableArrayRef descriptors = CFArrayCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeArrayCallBacks);
    int count = 0;
    /*
     * A DIAGNOSTIC CAP, off by default. A consumer that walks this list and does per font work
     * turns a slow path into a very slow one, and there is no way to tell an infinite loop from
     * an expensive one by watching a process spin. Capping the list answers that in one run: if
     * the work finishes with ten fonts and not with 1560, the loop terminates and the cost is in
     * the walk, not in a cycle.
     *
     * It is announced when set, because a font list that is quietly short is a trap of its own.
     */
    int limit = 0;
    const char *limitEnv = getenv("CIDER_CORETEXT_MAX_FONTS");
    if (limitEnv != NULL) {
        limit = atoi(limitEnv);
        if (limit > 0) {
            printf("CoreText: CAPPING the font list at %d, CIDER_CORETEXT_MAX_FONTS is set\n",
                   limit);
        }
    }
    if (set != NULL && descriptors != NULL) {
        for (int i = 0; i < set->nfont; i++) {
            if (limit > 0 && count >= limit) break;
            CFDictionaryRef descriptor = _CiderDescriptorFromPattern(set->fonts[i]);
            if (descriptor != NULL) {
                CFArrayAppendValue(descriptors, descriptor);
                CFRelease(descriptor);
                count++;
            }
        }
    }
    if (set != NULL) FcFontSetDestroy(set);
    if (props != NULL) FcObjectSetDestroy(props);
    if (pattern != NULL) FcPatternDestroy(pattern);

    printf("CoreText: font collection has %d descriptors\n", count);
    fflush(stdout);
    return (CTFontCollectionRef)descriptors;
}

CFArrayRef _Nullable CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionRef collection)
{
    /* The collection IS the array, so this is a retain. The name says Create, so the caller owns
     * the result and releasing it must not take the collection with it. */
    if (collection == NULL) return NULL;
    return (CFArrayRef)CFRetain((CFTypeRef)collection);
}

CTFontCollectionRef CTFontCollectionCreateWithFontDescriptors(CFArrayRef _Nullable queryDescriptors,
                                                              CFDictionaryRef _Nullable options)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}
