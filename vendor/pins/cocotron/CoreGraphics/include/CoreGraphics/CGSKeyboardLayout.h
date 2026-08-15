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

#ifndef CGSKEYBOARDLAYOUT_H
#define CGSKEYBOARDLAYOUT_H
#import <Foundation/NSString.h>
#include <CarbonCore/UnicodeUtilities.h>
#include <stdint.h>

@interface CGSKeyboardLayout : NSObject {
	UCKeyboardLayout* _layout;
	uint32_t _layoutLength;
	NSString* _name;
	NSString* _fullName;
}

@property(readwrite, strong) NSString* name;
@property(readwrite, strong) NSString* fullName;
@property(readonly) UCKeyboardLayout* layout;
@property(readonly) uint32_t layoutLength;

-(void) setLayout:(UCKeyboardLayout*) layout length:(uint32_t) length;

@end

#endif
