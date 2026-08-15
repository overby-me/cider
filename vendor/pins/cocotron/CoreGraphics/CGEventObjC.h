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

#ifndef CGEVENT_OBJC_H
#define CGEVENT_OBJC_H
#include <CoreGraphics/CGEvent.h>
#include <CoreFoundation/CFBase.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSData.h>

@class CGEventSource;

@interface CGEvent : NSObject <NSCopying, NSCoding> {
	CGEventSource* _source;
	CGEventType _type;
	CGEventTimestamp _timestamp;
	CGEventFlags _flags;
	NSMutableDictionary<NSNumber*, NSNumber*>* _fields;

	// keyboard events
	CGKeyCode _virtualKey;
	UniChar _unicodeString[5];

	// mouse button events
	CGPoint _location;
	CGMouseButton _mouseButton;

	CGSEventRecordPtr _eventRecord;
	uint32_t _eventRecordLength;
}
-(instancetype) initWithSource:(CGEventSource*) source;
-(instancetype) initWithSource:(CGEventSource*) source
						type:(CGEventType) type;
-(instancetype) initWithEventRecord:(const CGSEventRecordPtr) eventRecord
							length:(uint32_t) length;

-(void) dealloc;
-(id)copy;
-(CFTypeID) _cfTypeID;

-(void) setEventRecord:(CGSEventRecordPtr) record
				length:(uint32_t) length;
@property(readonly) uint32_t eventRecordLength;
@property(readonly) CGSEventRecordPtr eventRecord;

@property(readwrite) CGEventType type;
@property(retain) CGEventSource* source;
@property(readwrite) CGEventTimestamp timestamp;
@property(readwrite) CGEventFlags flags;
@property(readonly) NSMutableDictionary<NSNumber*, NSNumber*>* fields;

@property(readwrite) CGKeyCode virtualKey;

@property(readwrite) CGPoint location;
@property(readwrite) CGMouseButton mouseButton;

@property(readonly) UniChar* unicodeString;

@end

//////////////////////////////////////////////////////////////////////

@interface CGEventSource : NSObject {
	CGEventSourceStateID _stateId;
	CGEventSourceKeyboardType _keyboardType;
	int64_t _userData;
	double _pixelsPerLine;
}
-(instancetype) initWithState: (CGEventSourceStateID) stateId;
-(CFTypeID) _cfTypeID;
+(CGEventSource*) hidEventSource;

@property CGEventSourceKeyboardType keyboardType;
@property CGEventSourceStateID stateID;
@property int64_t userData;
@property double pixelsPerLine;

@end

//////////////////////////////////////////////////////////////////////

@interface CGEventTap : NSObject {
	CGEventTapLocation _location;
	CGEventTapOptions _options;
	CGEventMask _mask;
	CGEventTapCallBack _callback;
	void* _userInfo;
	Boolean _enabled;

	mach_port_t _machPort;
}

-(instancetype) initWithLocation: (CGEventTapLocation) location
						options: (CGEventTapOptions) options
							mask: (CGEventMask) mask
						callback: (CGEventTapCallBack) callback
						userInfo: (void*) userInfo;

-(void) dealloc;
-(CFMachPortRef) createCFMachPort;

@property(readonly) mach_port_t machPort;
@property(readonly) CGEventTapOptions options;
@property(readonly) CGEventMask mask;
@property(readonly) CGEventTapCallBack callback;
@property(readonly) void* userInfo;
@property Boolean enabled;

@end

#endif

