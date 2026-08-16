/*
 * WKContentWorld, the JavaScript world a script or an evaluation runs in.
 *
 * Added because a modern application asks for the class by name at load time: iTerm2 3.6.10 links
 * it, and dyld stops the process before main with Symbol not found _OBJC_CLASS_$_WKContentWorld.
 */

#import <Foundation/Foundation.h>

@interface WKContentWorld : NSObject

@property (class, nonatomic, readonly) WKContentWorld *pageWorld;
@property (class, nonatomic, readonly) WKContentWorld *defaultClientWorld;
@property (nonatomic, readonly, copy) NSString *name;

+ (WKContentWorld *) worldWithName: (NSString *) name;

@end
