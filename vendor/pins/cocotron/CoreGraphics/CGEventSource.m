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
#include "CGEventObjC.h"
#include <CoreGraphics/CGEventSource.h>

static CGEventFlags g_sourceStates[3];

CFTypeID CGEventSourceGetTypeID(void) {
    return (CFTypeID)[CGEventSource self];
}

CGEventSourceRef CGEventSourceCreate(CGEventSourceStateID stateID) {
    return (CGEventSourceRef) [[CGEventSource alloc] initWithState: stateID];
}

CGEventSourceKeyboardType CGEventSourceGetKeyboardType(CGEventSourceRef source)
{
    CGEventSource *src = (CGEventSource *) source;
    return src.keyboardType;
}

void CGEventSourceSetKeyboardType(CGEventSourceRef source,
                                  CGEventSourceKeyboardType keyboardType)
{
    CGEventSource *src = (CGEventSource *) source;
    src.keyboardType = keyboardType;
}

CGEventSourceStateID CGEventSourceGetSourceStateID(CGEventSourceRef source) {
    CGEventSource *src = (CGEventSource *) source;
    return src.stateID;
}

int64_t CGEventSourceGetUserData(CGEventSourceRef source) {
    CGEventSource *src = (CGEventSource *) source;
    return src.userData;
}

void CGEventSourceSetUserData(CGEventSourceRef source, int64_t userData) {
    CGEventSource *src = (CGEventSource *) source;
    src.userData = userData;
}

double CGEventSourceGetPixelsPerLine(CGEventSourceRef source) {
    CGEventSource *src = (CGEventSource *) source;
    return src.pixelsPerLine;
}

void CGEventSourceSetPixelsPerLine(CGEventSourceRef source,
                                   double pixelsPerLine)
{
    CGEventSource *src = (CGEventSource *) source;
    src.pixelsPerLine = pixelsPerLine;
}

CGEventFlags CGEventSourceFlagsState(CGEventSourceStateID stateID) {
    return g_sourceStates[stateID + 1];
}

void CGEventSourceSetLocalEventsSuppressionInterval(CGEventSourceRef source, CFTimeInterval seconds) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

/*
 * IDLE TIME, WHICH THIS PORT CANNOT MEASURE, so it reports none rather than inventing an amount.
 * Input arrives from the compositor straight into AppKit as NSEvents; nothing passes through a
 * CGEvent source, so there is no per-type last-event clock to subtract from. Zero says an event of
 * that type just happened, so an application that asks "has the user been idle for N seconds"
 * concludes NO and takes no idle action. The opposite default would dim screens and log people out.
 */
CFTimeInterval CGEventSourceSecondsSinceLastEventType(CGEventSourceStateID stateID,
                                                      CGEventType eventType)
{
    return 0.0;
}
