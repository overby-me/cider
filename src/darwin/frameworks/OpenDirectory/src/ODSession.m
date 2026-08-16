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

#import <OpenDirectory/ODSession.h>

#import <Foundation/Foundation.h>

@implementation ODSession

/*
 * THE DEFAULT SESSION, and why a stub needs one at all.
 *
 * This class forwards every INSTANCE message it does not implement and logs it, which is what a
 * stub should do. It forwards nothing sent to the CLASS, so +defaultSession, the entry point every
 * caller starts from, raised an unrecognized selector instead. iTerm2 asks for it while its delegate
 * is starting up, and while NSApplication caught that one, an application that does not catch it
 * dies before it opens a window.
 *
 * A shared instance is returned rather than nil, because nil is an answer callers act on: a lookup
 * against nil silently succeeds with no results, where an object that forwards says in the log what
 * was asked of it.
 */
+ (instancetype)defaultSession
{
    static ODSession *shared = nil;

    if (shared == nil) {
        shared = [[ODSession alloc] init];
    }
    return shared;
}

+ (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

+ (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: +%@ in %@", NSStringFromSelector([anInvocation selector]), self);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
