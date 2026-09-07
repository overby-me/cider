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


#ifndef _Quartz_H_
#define _Quartz_H_

// Quartz is an umbrella and this one was empty, so a consumer reaching PDFKit the way macOS
// documents it, through Quartz rather than PDFKit directly, found nothing at all.
// GUARDED, because PDFKit is Objective-C and Quartz.h is reachable from plain C. Unguarded it
// stops this framework's own Quartz.c on the first NSString in Foundation.
#ifdef __OBJC__
#import <PDFKit/PDFKit.h>
#endif

#endif
