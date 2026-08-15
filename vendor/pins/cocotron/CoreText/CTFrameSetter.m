#import <CoreText/CTFrameSetter.h>

CFTypeID CTFramesetterGetTypeID(void)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return 0;
}

CTFramesetterRef CTFramesetterCreateWithTypesetter(CTTypesetterRef typesetter)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTFramesetterRef CTFramesetterCreateWithAttributedString(CFAttributedStringRef attrString)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTFrameRef CTFramesetterCreateFrame(CTFramesetterRef framesetter,
                                    CFRange stringRange,
                                    CGPathRef path,
                                    CFDictionaryRef frameAttributes)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CTTypesetterRef CTFramesetterGetTypesetter(CTFramesetterRef framesetter)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CGSize CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterRef framesetter,
                                                    CFRange stringRange,
                                                    CFDictionaryRef frameAttributes,
                                                    CGSize constraints,
                                                    CFRange *fitRange)
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return CGSizeZero;
}
