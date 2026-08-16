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

#include <CoreGraphics/CGEvent.h>
#import "CGEventObjC.h"
#include <CoreGraphics/CGEventTapInternal.h>

void CGEventPost(CGEventTapLocation tap, CGEventRef _Nullable event)
{
	// TODO: Create an appropriate CGEventTapProxy and call CGEventTapPostEvent()
	// TODO: Finally, invoke callbacks registered with CGSRegisterNotifyProc()
}

CFMachPortRef CGEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place,
	CGEventTapOptions options, CGEventMask eventsOfInterest, CGEventTapCallBack callback, void *userInfo)
{
	CGEventTap* newTap = [[CGEventTap alloc] initWithLocation: tap
													options: options
													mask: eventsOfInterest
													callback: callback
													userInfo: userInfo];

	mach_port_t port = newTap.machPort;

	// TODO: Save this port to tapping structures

	CFMachPortRef mp = [newTap createCFMachPort];
	[newTap release]; // CFMachPortRef now holds a ref

	return mp;
}

void _CGEventTapDestroyed(CGEventTapLocation location, mach_port_t mp)
{
	// TODO: Deregister the tap
}

void CGEventTapEnable(CFMachPortRef tap, bool enable)
{
	mach_port_t mp = CFMachPortGetPort(tap);

	// TODO: Lookup CGEventTap instance by mp
	CGEventTap* tapObj = nil;
	tapObj.enabled = enable;
}

void CGEventTapPostEvent(CGEventTapProxy proxy, CGEventRef event)
{

}

CGError CGGetEventTapList(uint32_t maxNumberOfTaps, CGEventTapInformation *tapList, uint32_t *eventTapCount)
{

}
