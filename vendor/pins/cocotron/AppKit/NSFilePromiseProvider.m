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

#import <objc/runtime.h>
#import <AppKit/NSFilePromiseProvider.h>
#import <Foundation/NSMethodSignature.h>
#import <Foundation/NSInvocation.h>

@implementation NSFilePromiseProvider

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    /* The arity comes from the selector's colons and the return is an object: "v@:" claimed every
     * method took none and returned nothing, so a caller passing arguments wrote through slots the
     * invocation did not have, and one using the result read the leftover return register. */
    const char *name = sel_getName(aSelector);
    char types[256];
    size_t n = 0;

    types[n++] = '@';
    types[n++] = '@';
    types[n++] = ':';
    for (const char *p = name; *p != '\0' && n < sizeof(types) - 1; p++) {
        if (*p == ':')
            types[n++] = '@';
    }
    types[n] = '\0';
    return [NSMethodSignature signatureWithObjCTypes: types];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    id nothing = nil;
    [anInvocation setReturnValue: &nothing];
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
