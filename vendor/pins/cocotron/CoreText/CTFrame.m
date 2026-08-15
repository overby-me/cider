#import <CoreText/CTFrame.h>

/*
 * THE FRAME ATTRIBUTES, declared in the header since it was written and defined nowhere, so any
 * application that named one could not load. They are the keys of the dictionary passed to
 * CTFramesetterCreateFrame: which way the lines run, how a clipping path is filled, and the paths
 * text has to flow around. Swift Publisher 5 sets text in shapes, so it names the first of them.
 *
 * The strings are the ones macOS uses, which matter here for the same reason a notification name
 * does: an attribute dictionary built by one library and read by another agrees only on the string.
 */
const CFStringRef kCTFrameProgressionAttributeName = CFSTR("CTFrameProgression");
const CFStringRef kCTFramePathFillRuleAttributeName = CFSTR("CTFramePathFillRule");
const CFStringRef kCTFramePathWidthAttributeName = CFSTR("CTFramePathWidth");
const CFStringRef kCTFrameClippingPathsAttributeName = CFSTR("CTFrameClippingPaths");
const CFStringRef kCTFramePathClippingPathAttributeName = CFSTR("CTFramePathClippingPath");

CFRange CTFrameGetStringRange(CTFrameRef frame)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CFRangeMake(0, 0);
}

CFRange CTFrameGetVisibleStringRange(CTFrameRef frame)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CFRangeMake(0, 0);
}

CGPathRef CTFrameGetPath(CTFrameRef frame)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFDictionaryRef _Nullable CTFrameGetFrameAttributes(CTFrameRef frame)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFArrayRef CTFrameGetLines(CTFrameRef frame)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

void CTFrameGetLineOrigins(CTFrameRef frame, CFRange range, CGPoint origins[_Nonnull])
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

void CTFrameDraw(CTFrameRef frame, CGContextRef context)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}
