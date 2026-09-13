/*
 This file is part of Darling.

 Copyright (C) 2017 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#include <stdlib.h>
#include <stdio.h>
#import <IOSurface/IOSurface.h>

#include <CoreFoundation/CoreFoundation.h>

static int verbose = 0;

__attribute__((constructor))
static void initme(void) {
    verbose = getenv("STUB_VERBOSE") != NULL;
}


IOSurfaceRef _Nullable IOSurfaceLookup(IOSurfaceID csid){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


IOSurfaceID IOSurfaceGetID(IOSurfaceRef buffer){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}



size_t IOSurfaceGetNumberOfComponentsOfPlane(IOSurfaceRef buffer, size_t planeIndex){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


IOSurfaceComponentName IOSurfaceGetNameOfComponentOfPlane(IOSurfaceRef buffer, size_t planeIndex, size_t componentIndex){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


IOSurfaceComponentType IOSurfaceGetTypeOfComponentOfPlane(IOSurfaceRef buffer, size_t planeIndex, size_t componentIndex){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


IOSurfaceComponentRange IOSurfaceGetRangeOfComponentOfPlane(IOSurfaceRef buffer, size_t planeIndex, size_t componentIndex){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


size_t IOSurfaceGetBitDepthOfComponentOfPlane(IOSurfaceRef buffer, size_t planeIndex, size_t componentIndex){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


size_t IOSurfaceGetBitOffsetOfComponentOfPlane(IOSurfaceRef buffer, size_t planeIndex, size_t componentIndex){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


IOSurfaceSubsampling IOSurfaceGetSubsampling(IOSurfaceRef buffer){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}



mach_port_t IOSurfaceCreateMachPort(IOSurfaceRef buffer){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


size_t IOSurfaceGetPropertyMaximum(CFStringRef property){
    /* Zero here says "no surface can exist": Qt asserts width <= maximum in debug builds and a
     * caller that sizes against it gets nothing. A generous bound is the truthful shape for a
     * software surface whose only limit is memory. */
    return 1 << 30;
}

size_t IOSurfaceGetPropertyAlignment(CFStringRef property){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}



size_t IOSurfaceAlignProperty(CFStringRef property, size_t value){
    /* RETURNING 0 CORRUPTED THE HEAP. Qt aligns BytesPerRow and AllocSize through this BEFORE
     * IOSurfaceCreate, so 0 put zeros in the creation dictionary, the surface allocated zero
     * bytes, and the first frame was written through it: a GP fault on 0xED poison one run and a
     * tiny_malloc free list abort the next, neither anywhere near here. Task #227.
     *
     * Round UP like macOS does: rows to 64 bytes, sizes to a page, and never answer less than
     * the value asked about. */
    size_t align = 1;
    if (property != NULL && CFEqual(property, kIOSurfaceBytesPerRow))
        align = 64;
    else if (property != NULL && CFEqual(property, kIOSurfaceAllocSize))
        align = 4096;
    return (value + align - 1) & ~(align - 1);
}



Boolean IOSurfaceAllowsPixelSizeCasting(IOSurfaceRef buffer){
    if (verbose) printf("STUB: %s called\n", __FUNCTION__);
    return 0;
}


