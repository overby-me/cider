#import <AppKit/NSTitlebarAccessoryViewController.h>

@implementation NSTitlebarAccessoryViewController

@synthesize layoutAttribute = _layoutAttribute;
@synthesize fullScreenMinHeight = _fullScreenMinHeight;
@synthesize hidden = _hidden;

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
