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

#import <WebKit/WebScriptObject.h>
#import <Foundation/NSMethodSignature.h>
#import <Foundation/NSInvocation.h>

@implementation WebScriptObject

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end

/*
 * UNDEFINED IS A VALUE IN JAVASCRIPT and nil is not it, so the bridge needs an object that means it.
 * A dictionary cannot hold nil, and undefined is exactly what a property that was never set reads
 * back as, so every bridged value that came from JavaScript can be one of these.
 *
 * It is a singleton, and the interface is declared here because the header this framework ships
 * does not carry it. Swift Publisher 5 references the class, which is enough to stop the process
 * loading without it.
 */

@interface WebUndefined : NSObject
+ (WebUndefined *) undefined;
@end

@implementation WebUndefined

+ (WebUndefined *) undefined {
    static WebUndefined *shared = nil;

    @synchronized(self) {
        if (shared == nil)
            shared = [[WebUndefined alloc] init];
    }

    return shared;
}

- (NSString *) description {
    return @"undefined";
}

@end
