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

#include <AudioToolbox/AudioToolbox.h>
#include <iostream>
#include "stub.h"

void CAShow(void* inObject)
{
	// TODO: print something useful
	std::cout << "CAShow: " << inObject << std::endl;
}

/*
 * THE SYSTEM ALERT SOUNDS, WHICH THIS PORT HAS NO PATH FOR AND MUST STILL DEFINE.
 *
 * Money Manager Ex imports all five of these. None of them existed, in any form, and a function
 * that is declared and never defined does not give a wrong answer: it kills the process on the
 * lazy bind the first time the application reaches it. The same shape of defect took the same
 * application down on its first keystroke, through CGEventSourceKeyState.
 *
 * There is no audio device behind AppKit here, so a sound is not played. That is a visible
 * absence, not a wrong result, and it is far better than an application that exits when it wants
 * to beep. -1500 is kAudioServicesUnsupportedPropertyError, which is the truth: the property, an
 * actual output device, is not there.
 */
extern "C" {

typedef unsigned int CiderSystemSoundID;
typedef int CiderOSStatus;
typedef void (*CiderSystemSoundCompletionProc)(CiderSystemSoundID, void *);

CiderOSStatus AudioServicesCreateSystemSoundID(const void *inFileURL,
                                               CiderSystemSoundID *outSystemSoundID)
{
    STUB();
    if (outSystemSoundID != nullptr)
        *outSystemSoundID = 0;
    return -1500;
}

CiderOSStatus AudioServicesDisposeSystemSoundID(CiderSystemSoundID inSystemSoundID)
{
    STUB();
    return 0;
}

void AudioServicesPlaySystemSound(CiderSystemSoundID inSystemSoundID)
{
    STUB();
}

CiderOSStatus AudioServicesAddSystemSoundCompletion(CiderSystemSoundID inSystemSoundID,
                                                    void *inRunLoop, const void *inRunLoopMode,
                                                    CiderSystemSoundCompletionProc inCompletionRoutine,
                                                    void *inClientData)
{
    STUB();
    return -1500;
}

void AudioServicesRemoveSystemSoundCompletion(CiderSystemSoundID inSystemSoundID)
{
    STUB();
}

}
