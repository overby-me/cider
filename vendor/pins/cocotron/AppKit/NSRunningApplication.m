#import <AppKit/NSRunningApplication.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#import <unistd.h>

// DUMMY

// Implementation notes:
// _LSCopyApplicationInformationItem(-2, ...) is used to fetch properties, such
// as _kLSExecutablePathKey Applications (processes) are referred to by an
// opaque void* asn (application serial number). ASNs can be compared with
// _LSCompareASNs().
//
// lsd provides notifications when processes change. This is registered via:
// _LSScheduleNotificationFunction(-2, callback, eventMask, context,
// CFRunLoopRef, kCFRunLoopCommonModes) and _LSModifyNotification(). The
// properties are updated via KVO.
//
// Current application is also observed via LS - _LSGetCurrentApplicationASN().
// All apps: _LSCopyRunningApplicationArray() - returns an array of ASNs.
// Running apps: _LSCopyRunningApplicationArray() - ditto.

@implementation NSRunningApplication

+ (NSArray<NSRunningApplication *> *) runningApplicationsWithBundleIdentifier: (NSString *) bundleIdentifier {
    /* Other processes are not enumerable here, but THIS one is, and an application looking for
     * itself by bundle identifier is a common check. */
    NSRunningApplication *current = [self currentApplication];

    if (bundleIdentifier != nil &&
        [bundleIdentifier isEqualToString: [current bundleIdentifier]]) {
        return [NSArray arrayWithObject: current];
    }
    return [NSArray array];
}

+ (NSRunningApplication *) currentApplication {
    static NSRunningApplication *current = nil;

    if (current == nil) {
        NSBundle *bundle = [NSBundle mainBundle];

        current = [[self alloc] init];
        current->_processIdentifier = (int) getpid();
        current->_bundleIdentifier = [[bundle bundleIdentifier] copy];
        current->_localizedName =
                [[[bundle objectForInfoDictionaryKey: @"CFBundleName"] description] copy];
        current->_bundleURL = [[bundle bundleURL] retain];
        current->_executableURL = [[bundle executableURL] retain];
        current->_launchDate = [[NSDate date] retain];
        current->_active = YES;
        current->_activationPolicy = NSApplicationActivationPolicyRegular;
    }
    return current;
}

+ (NSRunningApplication *) runningApplicationWithProcessIdentifier: (int) pid {
    /* NIL FOR ANYBODY ELSE, which is the documented answer for a pid that is not running, and it
     * is the honest one here: this process cannot see the others. */
    return (pid == (int) getpid()) ? [self currentApplication] : nil;
}

- (int) processIdentifier {
    return _processIdentifier;
}

- (NSString *) bundleIdentifier {
    return _bundleIdentifier;
}

- (NSString *) localizedName {
    return _localizedName;
}

- (NSURL *) bundleURL {
    return _bundleURL;
}

- (NSURL *) executableURL {
    return _executableURL;
}

- (NSDate *) launchDate {
    return _launchDate;
}

- (BOOL) isActive {
    return _active;
}

- (BOOL) isTerminated {
    return _terminated;
}

- (BOOL) isFinishedLaunching {
    return YES;
}

- (BOOL) isHidden {
    return NO;
}

- (NSApplicationActivationPolicy) activationPolicy {
    return _activationPolicy;
}

/* THE FOUR THAT ACT ON ANOTHER PROCESS answer NO, because this one cannot reach another process
 * to do it, and NO is what the API says when the operation did not happen. */
- (BOOL) activateWithOptions: (NSUInteger) options {
    return (self == [NSRunningApplication currentApplication]);
}

- (BOOL) hide {
    return NO;
}

- (BOOL) unhide {
    return NO;
}

- (BOOL) terminate {
    return NO;
}

- (BOOL) forceTerminate {
    return NO;
}

@end
