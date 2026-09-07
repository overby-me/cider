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

#ifndef _SKSEARCH_H_
#define _SKSEARCH_H_

#include <CoreFoundation/CFBase.h>

typedef CF_ENUM(SInt32, SKSearchType) {
	kSKSearchRanked = 0,
	kSKSearchBooleanRanked = 1,
	kSKSearchRequiredRanked = 2,
	kSKSearchPrefixRanked = 3,
};

typedef CF_OPTIONS(CFOptionFlags, SKSearchOptions) {
	kSKSearchOptionDefault = 0,
	kSKSearchOptionNoRelevanceScores = 1UL << 0,
	kSKSearchOptionSpaceMeansOR = 1UL << 1,
	kSKSearchOptionFindSimilar = 1UL << 2,
};

#endif
