#import <CoreText/CTFrame.h>
#import <CoreText/CTTypesetter.h>

CF_IMPLICIT_BRIDGING_ENABLED

typedef struct __CTFramesetter* CTFramesetterRef;

CORETEXT_EXPORT CFTypeID CTFramesetterGetTypeID(void);
CORETEXT_EXPORT CTFramesetterRef CTFramesetterCreateWithTypesetter(CTTypesetterRef typesetter);
CORETEXT_EXPORT CTFramesetterRef CTFramesetterCreateWithAttributedString(CFAttributedStringRef attrString);

CORETEXT_EXPORT CTFrameRef CTFramesetterCreateFrame(CTFramesetterRef framesetter,
                                                    CFRange stringRange,
                                                    CGPathRef path,
                                                    CFDictionaryRef frameAttributes);

CORETEXT_EXPORT CTTypesetterRef CTFramesetterGetTypesetter(CTFramesetterRef framesetter);

CORETEXT_EXPORT CGSize CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterRef framesetter,
                                                                    CFRange stringRange,
                                                                    CFDictionaryRef frameAttributes,
                                                                    CGSize constraints,
                                                                    CFRange *fitRange);

CF_IMPLICIT_BRIDGING_DISABLED
