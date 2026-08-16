/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

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

#include <CoreMedia/CMTime.h>
#include <CoreFoundation/CoreFoundation.h>

const CMTime kCMTimeInvalid = {
    .value = 0,
    .timescale = 0,
    .flags = 0,
    .epoch = 0
};

const CMTime kCMTimeIndefinite = {
    .value = 0,
    .timescale = 0,
    .flags = kCMTimeFlags_Valid | kCMTimeFlags_Indefinite,
    .epoch = 0
};

const CMTime kCMTimePositiveInfinity = {
    .value = 0,
    .timescale = 0,
    .flags = kCMTimeFlags_Valid | kCMTimeFlags_PositiveInfinity,
    .epoch = 0
};

const CMTime kCMTimeNegativeInfinity = {
    .value = 0,
    .timescale = 0,
    .flags = kCMTimeFlags_Valid | kCMTimeFlags_NegativeInfinity,
    .epoch = 0
};

const CMTime kCMTimeZero = {
    .value = 0,
    .timescale = 1,
    .flags = kCMTimeFlags_Valid,
    .epoch = 0
};


/*
 * THE METADATA BASE DATA TYPES, which name the shape of a metadata value.
 *
 * They are identifiers rather than behaviour: a caller tags a metadata item with one of these
 * strings and a reader compares it, so the VALUE has to be the one macOS uses. These are the
 * documented com.apple.metadata.datatype identifiers.
 *
 * The raw data one is here because its SYMBOL stops a modern application at load time: iTerm2 3.6.10
 * links it and dyld refuses to start without it.
 */
const CFStringRef kCMMetadataBaseDataType_RawData = CFSTR("com.apple.metadata.datatype.raw-data");
const CFStringRef kCMMetadataBaseDataType_UTF8 = CFSTR("com.apple.metadata.datatype.UTF-8");
const CFStringRef kCMMetadataBaseDataType_UTF16 = CFSTR("com.apple.metadata.datatype.UTF-16");
const CFStringRef kCMMetadataBaseDataType_Float32 = CFSTR("com.apple.metadata.datatype.float32");
const CFStringRef kCMMetadataBaseDataType_Float64 = CFSTR("com.apple.metadata.datatype.float64");
const CFStringRef kCMMetadataBaseDataType_SInt32 = CFSTR("com.apple.metadata.datatype.int32");
const CFStringRef kCMMetadataBaseDataType_SInt64 = CFSTR("com.apple.metadata.datatype.int64");
