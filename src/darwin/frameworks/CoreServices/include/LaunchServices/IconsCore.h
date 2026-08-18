/*
 This file is part of Cider.

 ICON SERVICES, THE HANDLE AND THE TWO CALLS AN APPLICATION STILL MAKES. Icon Services hands out an
 IconRef for a file, a type or a bundle, and a Carbon-era application draws it or converts it to an
 NSImage. This port has no icon database and no icon server, so the getter reports that it has no
 icon rather than handing back something to draw; see IconsCore.c for why that is the safe answer.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
*/

#ifndef _ICONSCORE_H
#define _ICONSCORE_H

#include <CoreServices/FileManager.h>
#include <MacTypes.h>

typedef struct OpaqueIconRef *IconRef;
typedef uint32_t IconServicesUsageFlags;

enum {
    kIconServicesNormalUsageFlag = 0,
    kIconServicesNoBadgeFlag = 1,
    kIconServicesUpdateIfNeededFlag = 2,
};

#ifdef __cplusplus
extern "C" {
#endif

OSStatus GetIconRefFromFileInfo(const FSRef *inRef, UniCharCount inFileNameLength,
                                const UniChar *inFileName, FSCatalogInfoBitmap inWhichInfo,
                                const void *inCatalogInfo, IconServicesUsageFlags inUsageFlags,
                                IconRef *outIconRef, SInt16 *outLabel);

OSStatus ReleaseIconRef(IconRef theIconRef);
OSStatus AcquireIconRef(IconRef theIconRef);

#ifdef __cplusplus
}
#endif

#endif
