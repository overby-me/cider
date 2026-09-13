/*
 This file is part of Darling.

 Copyright (C) 2020 Lubos Dolezel

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

#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <IOSurface/IOSurfacePriv.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOCFSerialize.h>
#include <stdatomic.h>

static io_service_t g_surfaceService;

typedef struct
{
	struct _IOSurfaceObjectRetval* surface;
	_Atomic int32_t localUseCount;
	/* A LOCAL surface owns its pixels and never talks to iokitd. The daemon's create never wrote
	 * its response and every other surface RPC answers KERN_NOT_SUPPORTED, so the round trip
	 * bought a struct of stack garbage whose address field Qt then wrote pixels through. Nothing
	 * we run shares a surface across processes; when something does, the sharing goes through
	 * iokitd and this flag is how the two kinds coexist. Task #227. */
	bool local;
	void* pixels;
} ImplData;

@implementation IOSurface

+ (void)initialize
{
	if (self == [IOSurface self])
	{
		CFMutableDictionaryRef matching = IOServiceNameMatching("IOSurfaceRoot");

		/* IOServiceGetMatchingService CONSUMES the matching dictionary, which macOS documents and
		 * IOKitLib.c:509 does. The CFRelease that used to be here was a second one: Qt calls
		 * IOSurfaceCreate, +initialize ran, and CMake.app died in objc_msgSend sending release to
		 * the freed dictionary. Task #227. */
		g_surfaceService = IOServiceGetMatchingService(kIOMasterPortDefault, matching);

		if (!g_surfaceService)
		{
			fprintf(stderr, "CIDER_IOSURFACE no IOSurfaceRoot service\n");
			fflush(stderr);
		}
	}
}

- (nullable instancetype)initWithResponse:(const void*)bytes length:(size_t)length
{
	ImplData* idata = (ImplData*) malloc(sizeof(ImplData));
	idata->surface = malloc(length);
	memcpy(idata->surface, bytes, length);

	idata->localUseCount = 0;
	idata->local = false;
	idata->pixels = NULL;
	self->_impl = idata;

	return self;
}

static uint32_t readUInt(NSDictionary* dict, CFStringRef key, uint32_t fallback)
{
	NSNumber* n = ((NSDictionary*) dict)[(NSString*) key];
	return n != nil ? (uint32_t) [n unsignedIntValue] : fallback;
}

- (nullable instancetype)initLocalWithProperties:(NSDictionary <IOSurfacePropertyKey, id> *)properties
{
	uint32_t width = readUInt(properties, kIOSurfaceWidth, 0);
	uint32_t height = readUInt(properties, kIOSurfaceHeight, 0);

	if (width == 0 || height == 0)
	{
		fprintf(stderr, "CIDER_IOSURFACE local create rejected, width=%u height=%u\n", width,
		        height);
		fflush(stderr);
		[self release];
		return nil;
	}

	uint32_t bytesPerElement = readUInt(properties, kIOSurfaceBytesPerElement, 4);
	uint32_t bytesPerRow = readUInt(properties, kIOSurfaceBytesPerRow, width * bytesPerElement);
	uint64_t allocSize = readUInt(properties, kIOSurfaceAllocSize, 0);
	if (allocSize == 0)
		allocSize = (uint64_t) height * bytesPerRow;

	/* calloc, not malloc: a fresh IOSurface arrives ZEROED on macOS, and Qt documents relying on
	 * it, skipping its own clear for newly created buffers. */
	void* pixels = calloc(1, allocSize);
	if (pixels == NULL)
	{
		[self release];
		return nil;
	}

	ImplData* idata = (ImplData*) malloc(sizeof(ImplData));
	idata->surface = calloc(1, sizeof(struct _IOSurfaceObjectRetval));

	static _Atomic uint32_t nextLocalID = 1;
	idata->surface->surfaceID = nextLocalID++;
	idata->surface->pixelFormat = readUInt(properties, kIOSurfacePixelFormat, 0);
	idata->surface->address = (uint64_t) pixels;
	idata->surface->planeCount = 1;
	idata->surface->planes[0].memoryOffset = 0;
	idata->surface->planes[0].bytesPerElement = bytesPerElement;
	idata->surface->planes[0].width = width;
	idata->surface->planes[0].height = height;
	idata->surface->planes[0].bytesPerRow = bytesPerRow;

	idata->localUseCount = 0;
	idata->local = true;
	idata->pixels = pixels;
	self->_impl = idata;

	return self;
}

- (nullable instancetype)initWithProperties:(NSDictionary <IOSurfacePropertyKey, id> *)properties
{
	/* Local, not a daemon round trip. iokitd createSurface never writes its response struct and
	 * every other surface method there is KERN_NOT_SUPPORTED, so the RPC handed back stack
	 * garbage whose address Qt wrote pixels through. A surface nobody shares is a pixel buffer;
	 * cross process lookup goes back through iokitd when somebody implements it. Task #227. */
	return [self initLocalWithProperties: properties];
}

- (nullable instancetype)initWithSurfaceID:(IOSurfaceID)surfaceID
{
	uint8_t responseBuffer[3500];
	size_t responseLength = sizeof(responseBuffer);

	uint64_t scalar = surfaceID;
	kern_return_t ret = IOConnectCallMethod(g_surfaceService, kIOSurfaceMethodLookupByID, &scalar, 1, NULL, 0, NULL, 0, responseBuffer, &responseLength);

	if (ret != kIOSurfaceSuccess)
	{
		[self release];
		return nil;
	}

	return [self initWithResponse: responseBuffer length: responseLength];
}

- (void) dealloc
{
	ImplData* data = (ImplData*) _impl;
	if (data != NULL)
	{
		if (data->surface != NULL)
		{
			if (!data->local)
				IOConnectCallMethod(g_surfaceService, kIOSurfaceMethodRelease, NULL, 0, &data->surface->surfaceID, 1, NULL, 0, NULL, 0);

			free(data->surface);
		}
		free(data->pixels);

		free(data);
	}
	[super dealloc];
}

- (NSUInteger) hash
{
	ImplData* data = (ImplData*) _impl;
	return data->surface->surfaceID;
}

- (BOOL)isEqual:(id)object
{
	if (![object isKindOfClass: [self class]])
		return NO;

	IOSurface* that = (IOSurface*) object;
	return ((ImplData*) self->_impl)->surface->surfaceID == ((ImplData*) that->_impl)->surface->surfaceID;
}

- (CFTypeID) _cfTypeID
{
    return IOSurfaceGetTypeID();
}

- (NSInteger) width
{
	return [self widthOfPlaneAtIndex: 0];
}

- (NSInteger) height
{
	return [self heightOfPlaneAtIndex: 0];
}

- (void *) baseAddress
{
	return [self baseAddressOfPlaneAtIndex: 0];
}

- (NSInteger) bytesPerRow
{
	return [self bytesPerRowOfPlaneAtIndex: 0];
}

- (NSInteger) bytesPerElement
{
	return [self bytesPerElementOfPlaneAtIndex: 0];
}

- (NSInteger) elementWidth
{
	return [self elementWidthOfPlaneAtIndex: 0];
}

- (NSInteger) elementHeight
{
	return [self elementHeightOfPlaneAtIndex: 0];
}

- (OSType) pixelFormat
{
	return ((ImplData*) _impl)->surface->pixelFormat;
}

- (NSUInteger) planeCount
{
	return ((ImplData*) _impl)->surface->planeCount;
}

- (NSInteger)widthOfPlaneAtIndex:(NSUInteger)planeIndex
{
	if (planeIndex >= [self planeCount])
		return 0;

	ImplData* data = (ImplData*) _impl;
	return data->surface->planes[planeIndex].width;
}

- (NSInteger)heightOfPlaneAtIndex:(NSUInteger)planeIndex
{
	if (planeIndex >= [self planeCount])
		return 0;

	ImplData* data = (ImplData*) _impl;
	return data->surface->planes[planeIndex].height;
}

- (NSInteger)bytesPerRowOfPlaneAtIndex:(NSUInteger)planeIndex
{
	if (planeIndex >= [self planeCount])
		return 0;

	ImplData* data = (ImplData*) _impl;
	return data->surface->planes[planeIndex].bytesPerRow;
}

- (NSInteger)bytesPerElementOfPlaneAtIndex:(NSUInteger)planeIndex
{
	if (planeIndex >= [self planeCount])
		return 0;

	ImplData* data = (ImplData*) _impl;
	return data->surface->planes[planeIndex].bytesPerElement;
}

- (NSInteger)elementWidthOfPlaneAtIndex:(NSUInteger)planeIndex
{
	return 1;
}

- (NSInteger)elementHeightOfPlaneAtIndex:(NSUInteger)planeIndex
{
	return 1;
}

- (void *)baseAddressOfPlaneAtIndex:(NSUInteger)planeIndex
{
	if (planeIndex >= [self planeCount])
		return NULL;

	ImplData* data = (ImplData*) _impl;
	return (void*)(data->surface->address + data->surface->planes[planeIndex].memoryOffset);
}

- (void)incrementUseCount
{
	ImplData* data = (ImplData*) _impl;
	if ((data->localUseCount++) == 0 && !data->local)
	{
		uint64_t scalar = data->surface->surfaceID;
		IOConnectCallMethod(g_surfaceService, kIOSurfaceMethodIncrementUseCount, &scalar, 1, NULL, 0, NULL, 0, NULL, 0);
	}
}

- (void)decrementUseCount
{
	ImplData* data = (ImplData*) _impl;
	if (--data->localUseCount == 0 && !data->local)
	{
		uint64_t scalar = data->surface->surfaceID;
		IOConnectCallMethod(g_surfaceService, kIOSurfaceMethodDecrementUseCount, &scalar, 1, NULL, 0, NULL, 0, NULL, 0);
	}
}

/* Whether ANOTHER holder still reads the surface is what a swapchain asks before reusing a
 * buffer. There is no compositor holding local surfaces, so the local count is the whole truth;
 * before this the auto synthesised property getter answered a never written ivar, a constant NO. */
- (BOOL)isInUse
{
	return ((ImplData*) _impl)->localUseCount > 0;
}

- (int32_t) localUseCount
{
	ImplData* data = (ImplData*) _impl;
	return data->localUseCount;
}

- (kern_return_t)lockWithOptions:(IOSurfaceLockOptions)options seed:(nullable uint32_t *)seed
{
	ImplData* data = (ImplData*) _impl;
	/* Locking arbitrates against a GPU or another process. A local surface has neither, so
	 * success IS the correct answer, not a shortcut; failing here made Qt retry with a read-back
	 * and then warn on every frame. */
	if (data->local)
		return kIOSurfaceSuccess;
	struct _IOSurfaceLockUnlock args = {
		.surfaceID = data->surface->surfaceID,
		.options = options,
	};
	return IOConnectCallMethod(g_surfaceService, kIOSurfaceMethodLock, NULL, 0, &args, sizeof(args), NULL, 0, NULL, 0);
}

- (kern_return_t)unlockWithOptions:(IOSurfaceLockOptions)options seed:(nullable uint32_t *)seed
{
	ImplData* data = (ImplData*) _impl;
	if (data->local)
		return kIOSurfaceSuccess;
	struct _IOSurfaceLockUnlock args = {
		.surfaceID = data->surface->surfaceID,
		.options = options,
	};
	return IOConnectCallMethod(g_surfaceService, kIOSurfaceMethodUnlock, NULL, 0, &args, sizeof(args), NULL, 0, NULL, 0);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
