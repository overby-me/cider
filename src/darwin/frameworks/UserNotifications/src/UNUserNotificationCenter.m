/*
 This file is part of Darling.

 Copyright (C) 2021 Lubos Dolezel

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

#import <UserNotifications/UNUserNotificationCenter.h>
#import <dispatch/dispatch.h>

/*
 * THE ENTRY POINT, which is a CLASS method and so was never covered by the forwarding below.
 *
 * forwardInvocation: catches instance messages only, so every class message to this class raised.
 * iTerm2 asks for the current centre while it starts, does not catch the failure, and the process
 * terminated on an uncaught NSException.
 *
 * There is one centre per process on macOS and the same holds here.
 */
@implementation UNUserNotificationCenter {
    id _delegate;
}

+ (UNUserNotificationCenter *)currentNotificationCenter
{
    static UNUserNotificationCenter *center = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        center = [[UNUserNotificationCenter alloc] init];
    });
    return center;
}

/*
 * NOT GRANTED IS THE TRUTHFUL ANSWER: there is no notification system behind this, so a caller told
 * yes would post notifications that go nowhere and report success. The handler IS called, because a
 * completion handler that never runs leaves the caller waiting forever, which is worse than a no.
 */
- (void)requestAuthorizationWithOptions:(NSUInteger)options
                      completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
    if (completionHandler != NULL) {
        completionHandler(NO, nil);
    }
}

- (id)delegate
{
    return _delegate;
}

- (void)setDelegate:(id)delegate
{
    _delegate = delegate;
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
