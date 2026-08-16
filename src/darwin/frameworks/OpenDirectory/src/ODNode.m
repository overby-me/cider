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

#import <Foundation/Foundation.h>
#import <OpenDirectory/ODNode.h>

@implementation ODNode

/*
 * THERE IS NO DIRECTORY SERVICE HERE, and saying so is better than either answer this stub gave.
 *
 * The class forwards nothing, so +nodeWithSession:type:error: raised an unrecognized selector and
 * killed the caller. Forwarding it instead would be worse: the stub signature in this tree is v@:,
 * so a method that returns an object hands the caller whatever was in the return register.
 *
 * nil WITH AN ERROR is what a lookup that cannot be performed returns, and it is the case every
 * caller of this API already handles: iTerm2 asks OpenDirectory for the user record and falls back
 * to the password file when it gets nothing.
 */
static NSError *_ODNoDirectoryError(void)
{
    NSDictionary *info = @{
        NSLocalizedDescriptionKey : @"OpenDirectory is not available in this environment"
    };

    return [NSError errorWithDomain: @"com.apple.OpenDirectory.ErrorDomain"
                               code: 2100
                           userInfo: info];
}

+ (instancetype)nodeWithSession:(ODSession *)inSession type:(ODNodeType)inType error:(NSError **)outError
{
    if (outError != NULL) {
        *outError = _ODNoDirectoryError();
    }
    return nil;
}

+ (instancetype)nodeWithSession:(ODSession *)inSession name:(NSString *)inName error:(NSError **)outError
{
    if (outError != NULL) {
        *outError = _ODNoDirectoryError();
    }
    return nil;
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
