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

#import <Foundation/NSObject.h>

typedef enum {
    NSApplicationActivationPolicyRegular,
    NSApplicationActivationPolicyAccessory,
    NSApplicationActivationPolicyProhibited
} NSApplicationActivationPolicy;

@class NSString, NSDate, NSURL;

@interface NSRunningApplication : NSObject {
    int _processIdentifier;
    NSString *_bundleIdentifier;
    NSString *_localizedName;
    NSURL *_bundleURL;
    NSURL *_executableURL;
    NSDate *_launchDate;
    BOOL _active;
    BOOL _terminated;
    NSApplicationActivationPolicy _activationPolicy;
}

+ (NSArray<NSRunningApplication *> *) runningApplicationsWithBundleIdentifier: (NSString *) bundleIdentifier;

/* THIS PROCESS AS AN OBJECT. Everything else the class can do needs a window server that lists
 * other processes, and there is none here, but an application asking about ITSELF can be answered
 * exactly: the values come from the running process and its own bundle. iTerm2 asks on the first
 * update of its session. */
+ (NSRunningApplication *) currentApplication;

+ (NSRunningApplication *) runningApplicationWithProcessIdentifier: (int) pid;

- (int) processIdentifier;
- (NSString *) bundleIdentifier;
- (NSString *) localizedName;
- (NSURL *) bundleURL;
- (NSURL *) executableURL;
- (NSDate *) launchDate;
- (BOOL) isActive;
- (BOOL) isTerminated;
- (BOOL) isFinishedLaunching;
- (BOOL) isHidden;
- (NSApplicationActivationPolicy) activationPolicy;
- (BOOL) activateWithOptions: (NSUInteger) options;
- (BOOL) hide;
- (BOOL) unhide;
- (BOOL) terminate;
- (BOOL) forceTerminate;

@end
