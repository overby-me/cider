#import <CoreText/CTFrame.h>

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
