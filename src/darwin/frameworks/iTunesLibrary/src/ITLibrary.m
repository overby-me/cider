/*
 * iTunesLibrary, enough of it that an application which links against it can START.
 *
 * This framework is not part of macOS proper: iTunes installs it into /Library/Frameworks, and
 * applications that offer "insert a track from your music library" link against it directly. Swift
 * Publisher 5 is one of them. A hard link to a framework that is not there is fatal at load, so
 * without this file the application never reaches its first line of code.
 *
 * WHAT IT DOES IS SAY NO, WHICH IS THE TRUTH. There is no iTunes library on this machine, so
 * +libraryWithAPIVersion:error: answers nil with an error, which is exactly the documented shape of
 * "the library could not be read" and is what an application is already prepared for. Answering a
 * stub object instead would be worse: the caller would walk empty collections it believes are real.
 */

#import <Foundation/Foundation.h>

NSString *const ITLibNotificationNameMediaItemAdded = @"ITLibNotificationNameMediaItemAdded";

@interface ITLibrary : NSObject
+ (instancetype) libraryWithAPIVersion: (NSString *) requestedAPIVersion
                                 error: (NSError **) error;
+ (instancetype) libraryWithAPIVersion: (NSString *) requestedAPIVersion
                               options: (NSUInteger) options
                                 error: (NSError **) error;
@end

@implementation ITLibrary

+ (instancetype) libraryWithAPIVersion: (NSString *) requestedAPIVersion
                                 error: (NSError **) error
{
    return [self libraryWithAPIVersion: requestedAPIVersion options: 0 error: error];
}

+ (instancetype) libraryWithAPIVersion: (NSString *) requestedAPIVersion
                               options: (NSUInteger) options
                                 error: (NSError **) error
{
    if (error != NULL) {
        *error = [NSError
                errorWithDomain: @"com.apple.iTunesLibrary.ITLibraryErrorDomain"
                           code: 1
                       userInfo: @{
                           NSLocalizedDescriptionKey:
                                   @"There is no iTunes library on this system."
                       }];
    }

    return nil;
}

@end
