#import <CoreText/CTLine.h>

CFTypeID CTLineGetTypeID(void)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}

CTLineRef CTLineCreateWithAttributedString(CFAttributedStringRef attrString)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTLineRef CTLineCreateTruncatedLine(CTLineRef line, double width,
                                    CTLineTruncationType truncationType,
                                    CTLineRef truncationToken)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTLineRef CTLineCreateJustifiedLine(CTLineRef line, CGFloat justificationFactor, double justificationWidth)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFIndex CTLineGetGlyphCount(CTLineRef line)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1;
}

CFArrayRef CTLineGetGlyphRuns(CTLineRef line)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFRange CTLineGetStringRange(CTLineRef line)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CFRangeMake(0, 0);
}

double CTLineGetPenOffsetForFlush(CTLineRef line, CGFloat flushFactor, double flushWidth)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1.0;
}

void CTLineDraw(CTLineRef line, CGContextRef context)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

double CTLineGetTypographicBounds(CTLineRef line, CGFloat *ascent, CGFloat *descent, CGFloat *leading)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1.0;
}

CGRect CTLineGetBoundsWithOptions(CTLineRef line, CTLineBoundsOptions options)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGRectMake(0, 0, 0, 0);
}

double CTLineGetTrailingWhitespaceWidth(CTLineRef line)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1.0;
}

CGRect CTLineGetImageBounds(CTLineRef line, CGContextRef context)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGRectMake(0, 0, 0, 0);
}

CFIndex CTLineGetStringIndexForPosition(CTLineRef line, CGPoint position)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1;
}

CGFloat CTLineGetOffsetForStringIndex(CTLineRef line, CFIndex charIndex, CGFloat *secondaryOffset)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return -1.0f;
}

