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
#ifndef CGEVENTTAP_INTERNAL_H
#define CGEVENTTAP_INTERNAL_H
#include <CoreGraphics/CGEventTypes.h>
#include <mach/message.h>

#ifdef __cplusplus
extern "C" {
#endif

extern void _CGEventTapDestroyed(CGEventTapLocation loc, mach_port_t mp);

struct TapMachMessage {
    mach_msg_header_t header;
    CGEventTapProxy proxy;
    CGEventRef event;
};

#ifdef __cplusplus
}
#endif

#endif
