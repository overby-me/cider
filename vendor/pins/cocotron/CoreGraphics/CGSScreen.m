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

#import <CoreGraphics/CGSScreen.h>

@implementation CGSScreen
@synthesize edid = _edid;
@synthesize modes = _modes;
@synthesize currentMode = _currentMode;

-(void) dealloc
{
	[_edid release];
	[_modes release];
	[super dealloc];
}

-(uint32_t) currentModeHeight
{
	if (!_currentModeHeightCached)
	{
		if (_currentMode < 0 || _currentMode >= [_modes count])
			return 0;
		NSNumber* height = (NSNumber*) _modes[_currentMode][@"Height"];
		_currentModeHeightCached = height.intValue;
	}
	return _currentModeHeightCached;
}
@end

