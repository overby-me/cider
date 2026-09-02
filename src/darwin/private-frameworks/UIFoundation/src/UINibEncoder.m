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

#import <UIFoundation/UINibEncoder.h>

@implementation UINibEncoder

/*
 * A STUB STILL HAS TO ANSWER IN THE RIGHT REGISTER.
 *
 * "v@:" says the method returns nothing, so nothing is written to the return register and the caller
 * reads whatever the last call left there. iA Writer took that value, 0x4e, for an object and sent
 * it a message: SIGSEGV in objc_msgSend with this forwardInvocation three frames down, during nib
 * decoding, with no other sign of what went wrong.
 *
 * "@@:" plus an explicit nil costs a caller that wanted void nothing at all, and gives one that
 * wanted an object the only safe answer. Same trap as the initialiser that handed back its return
 * register; the pattern is shared by every generated stub in this tree.
 */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "@@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    id nothing = nil;
    [anInvocation setReturnValue: &nothing];
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
