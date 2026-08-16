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
 * A MISSING CLASS IS A LINK ERROR, not a message that goes nowhere: an application that names
 * ABGroup anywhere cannot start until this symbol exists. Swift Publisher 5 names it, in the part
 * that offers to merge a mailing list from the address book.
 *
 * The interface is declared here rather than in a header because nothing in this tree compiles
 * against it. The framework header map is generated, and adding a header for a class only the
 * loader cares about would be a bigger change than the class itself.
 */

#import <AddressBook/ABRecord.h>

@interface ABGroup : ABRecord
@end

@implementation ABGroup

- (NSMethodSignature *) methodSignatureForSelector: (SEL) aSelector {
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void) forwardInvocation: (NSInvocation *) anInvocation {
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]),
          [self class]);
}

@end
