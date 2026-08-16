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

/*
 * The value of an address book property that can have several entries with labels: three phone
 * numbers, two of them work. See ABGroup.m for why the interface is here and not in a header.
 *
 * -count answers zero rather than forwarding, because a caller that asks a stub how many entries
 * there are gets a nil back from the forwarder and reads it as a count, and then indexes into a
 * value that is not there. Zero is both true and safe.
 */

#import <Foundation/Foundation.h>

@interface ABMultiValue : NSObject
@end

@implementation ABMultiValue

- (NSUInteger) count {
    return 0;
}

- (NSMethodSignature *) methodSignatureForSelector: (SEL) aSelector {
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void) forwardInvocation: (NSInvocation *) anInvocation {
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]),
          [self class]);
}

@end
