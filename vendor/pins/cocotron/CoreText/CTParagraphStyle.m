#import <CoreText/CTParagraphStyle.h>

#include <stdio.h>

CTParagraphStyleRef CTParagraphStyleCreate(const CTParagraphStyleSetting *settings, size_t settingCount) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

bool CTParagraphStyleGetValueForSpecifier(CTParagraphStyleRef paragraphStyle, CTParagraphStyleSpecifier spec, size_t valueBufferSize, void *valueBuffer) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}
