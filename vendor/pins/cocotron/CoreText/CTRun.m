#import <CoreText/CTRun.h>

CFTypeID CTRunGetTypeID(void)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}

CFIndex CTRunGetGlyphCount(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1;
}

CFDictionaryRef CTRunGetAttributes(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTRunStatus CTRunGetStatus(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}

const CGGlyph * CTRunGetGlyphsPtr(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

void CTRunGetGlyphs(CTRunRef run, CFRange range, CGGlyph *buffer)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

const CGPoint * CTRunGetPositionsPtr(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

void CTRunGetPositions(CTRunRef run, CFRange range, CGPoint *buffer)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

const CGSize * CTRunGetAdvancesPtr(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

void CTRunGetAdvances(CTRunRef run, CFRange range, CGSize *buffer)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

const CFIndex * CTRunGetStringIndicesPtr(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

void CTRunGetStringIndices(CTRunRef run, CFRange range, CFIndex *buffer)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

CFRange CTRunGetStringRange(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CFRangeMake(0, 0);
}

double CTRunGetTypographicBounds(CTRunRef run, CFRange range, CGFloat *ascent, CGFloat *descent, CGFloat *leading)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1.0;
}

CGRect CTRunGetImageBounds(CTRunRef run, CGContextRef context, CFRange range)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGRectMake(0, 0, 0, 0);
}

CGAffineTransform CTRunGetTextMatrix(CTRunRef run)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGAffineTransformIdentity;
}

void CTRunGetBaseAdvancesAndOrigins(CTRunRef runRef, CFRange range, CGSize *advancesBuffer, CGPoint *originsBuffer)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

void CTRunDraw(CTRunRef run, CGContextRef context, CFRange range)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}
