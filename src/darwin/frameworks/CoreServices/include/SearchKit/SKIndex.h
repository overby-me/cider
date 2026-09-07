/*
 This file is part of Darling.

 Copyright (C) 2025 Darling Developers

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

#ifndef SKINDEX_H_
#define SKINDEX_H_

#include <CoreFoundation/CFBase.h>

typedef CF_ENUM(SInt32, SKIndexType) {
	kSKIndexUnknown = 0,
	kSKIndexInverted = 1,
	kSKIndexVector = 2,
	kSKIndexInvertedVector = 3,
};

#ifdef __cplusplus
extern "C" {
#endif

extern void SKLoadDefaultExtractorPlugIns(void);

#ifdef __cplusplus
}
#endif

#endif
