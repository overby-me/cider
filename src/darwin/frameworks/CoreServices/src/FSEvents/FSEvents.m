/*
 This file is part of Darling.

 Copyright (C) 2019-2020 Lubos Dolezel

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

#include <FSEvents/FSEvents.h>
#include <stdio.h>
#include <stdlib.h>
#import "FSEventsImpl.h"

FSEventStreamRef FSEventStreamCreate(
		CFAllocatorRef allocator,
		FSEventStreamCallback callback,
		FSEventStreamContext *context,
		CFArrayRef pathsToWatch,
		FSEventStreamEventId sinceWhen,
		CFTimeInterval latency,
		FSEventStreamCreateFlags flags)
{
	return (FSEventStreamRef) [[FSEventsImpl alloc] initWithPaths: (NSArray*)pathsToWatch
									flags: flags
									context: context
									callback: callback];
}

extern FSEventStreamRef FSEventStreamCreateRelativeToDevice(
		CFAllocatorRef allocator,
		FSEventStreamCallback callback,
		FSEventStreamContext *context,
		dev_t deviceToWatch,
		CFArrayRef pathsToWatchRelativeToDevice,
		FSEventStreamEventId sinceWhen,
		CFTimeInterval latency,
		FSEventStreamCreateFlags flags)
{
	printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

CFArrayRef FSEventStreamCopyPathsBeingWatched(ConstFSEventStreamRef streamRef)
{
	FSEventsImpl* impl = (FSEventsImpl*) streamRef;
	return (CFArrayRef) [impl copyPathsToWatch];
}

FSEventStreamEventId FSEventStreamGetLatestEventId(ConstFSEventStreamRef streamRef)
{
	return [((FSEventsImpl*) streamRef) lastEventID];
}

/*
 * THE MOST RECENT EVENT ID ISSUED SYSTEM WIDE, which a caller stores now and passes as sinceWhen
 * later to mean "everything after this point".
 *
 * NOT ZERO. Zero is kFSEventStreamEventIdSinceNow's opposite: it means the beginning of time, so a
 * caller that stored it would ask to be replayed the whole history of the volume. A counter that
 * only goes up is the safe answer, and it is honest here because nothing else in this port issues
 * event ids to collide with.
 *
 * ABSENT, THIS DID NOT FAIL POLITELY. The symbol binds LAZILY, so the first caller to reach it
 * aborted inside dyld_stub_binder with no name attached; CMake died opening its generator wizard
 * and the only evidence was signal 6 at a dyld frame. Task #234.
 */
FSEventStreamEventId FSEventsGetCurrentEventId(void)
{
	static _Atomic FSEventStreamEventId counter = 1;
	return counter++;
}

void FSEventStreamInvalidate(FSEventStreamRef streamRef)
{
	[((FSEventsImpl*) streamRef) invalidate];
}

void FSEventStreamRelease(FSEventStreamRef streamRef)
{
	[((FSEventsImpl*) streamRef) release];
}

void FSEventStreamRetain(FSEventStreamRef streamRef)
{
	[((FSEventsImpl*) streamRef) retain];
}

void FSEventStreamScheduleWithRunLoop(FSEventStreamRef streamRef, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
	[((FSEventsImpl*) streamRef) scheduleWithRunLoop: runLoop
												mode: runLoopMode];
}

void FSEventStreamSetDispatchQueue(FSEventStreamRef streamRef, dispatch_queue_t q)
{
	[((FSEventsImpl*) streamRef) setDispatchQueue: q];
}

Boolean FSEventStreamStart(FSEventStreamRef streamRef)
{
	[((FSEventsImpl*) streamRef) start];
	return TRUE;
}

void FSEventStreamStop(FSEventStreamRef streamRef)
{
	[((FSEventsImpl*) streamRef) stop];
}

void FSEventStreamUnscheduleFromRunLoop(FSEventStreamRef streamRef, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
	[((FSEventsImpl*) streamRef) unscheduleWithRunLoop: runLoop
												mode: runLoopMode];
}
