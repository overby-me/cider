/*
 * A FRAMEWORK THAT EXISTS SO DYLD CAN FINISH, and nothing more than iTerm2 asks of it.
 *
 * dyld refuses to start a process whose LIBRARY is missing, whatever it does or does not use from
 * it, so an application that merely links ScreenCaptureKit cannot run without one. What iTerm2 actually
 * binds from this framework was counted with llvm-objdump across --bind, --lazy-bind and
 * --weak-bind: five classes and no functions: SCContentFilter, SCShareableContent, SCStream, SCStreamConfiguration, SCWindow.
 */

#import <Foundation/Foundation.h>

/*
 * Screen capture is not implemented here. These classes exist so that an application which LINKS
 * against the framework can start; anything that actually tries to capture gets an object that does
 * nothing, which is the same answer a machine with the permission denied would give.
 */
@interface SCContentFilter : NSObject
@end

@implementation SCContentFilter
@end

@interface SCShareableContent : NSObject
@end

@implementation SCShareableContent
@end

@interface SCStream : NSObject
@end

@implementation SCStream
@end

@interface SCStreamConfiguration : NSObject
@end

@implementation SCStreamConfiguration
@end

@interface SCWindow : NSObject
@end

@implementation SCWindow
@end
