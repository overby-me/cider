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
#ifndef CGSSCREEN_H
#define CGSSCREEN_H
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSData.h>

@interface CGSScreen : NSObject {
	NSData* _edid;
	NSArray<NSDictionary*>* _modes;
	CFIndex _currentMode;

	uint32_t _currentModeHeightCached;
}

@property(readwrite, strong) NSData* edid;
@property(readwrite, strong) NSArray<NSDictionary*>* modes;
@property(readwrite, assign) CFIndex currentMode;

@property(readonly) uint32_t currentModeHeight;

@end

#endif

