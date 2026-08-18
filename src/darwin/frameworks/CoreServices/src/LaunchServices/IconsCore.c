/*
 This file is part of Cider.

 NO ICON DATABASE, SO NO ICON: the getter answers unimpErr and writes NULL, which is a policy answer
 and not an oversight. Every caller of GetIconRefFromFileInfo has to check the OSStatus before it
 touches the ref, because the real function fails for a file that has no custom icon, so a failure
 here takes the same path the application already has: fall back to a generic icon of its own.
 The alternative, handing back a non-null handle with nothing behind it, would fault inside whatever
 tried to draw it, a long way from here.

 ReleaseIconRef and AcquireIconRef answer noErr for the NULL ref the getter produced, so paired
 release calls do not report failures that mean nothing.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
*/

#include <LaunchServices/IconsCore.h>

// unimpErr, the classic Mac OS "unimplemented core routine". Named rather than spelled -4 at the
// return, so the reason travels with the value.
#define CIDER_UNIMP_ERR -4

OSStatus GetIconRefFromFileInfo(const FSRef *inRef, UniCharCount inFileNameLength,
                                const UniChar *inFileName, FSCatalogInfoBitmap inWhichInfo,
                                const void *inCatalogInfo, IconServicesUsageFlags inUsageFlags,
                                IconRef *outIconRef, SInt16 *outLabel)
{
    if (outIconRef != NULL) {
        *outIconRef = NULL;
    }
    if (outLabel != NULL) {
        *outLabel = 0;
    }

    return CIDER_UNIMP_ERR;
}

OSStatus ReleaseIconRef(IconRef theIconRef)
{
    return theIconRef == NULL ? 0 : CIDER_UNIMP_ERR;
}

OSStatus AcquireIconRef(IconRef theIconRef)
{
    return theIconRef == NULL ? 0 : CIDER_UNIMP_ERR;
}
