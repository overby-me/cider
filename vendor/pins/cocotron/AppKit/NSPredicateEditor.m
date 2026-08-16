#import <AppKit/NSPredicateEditor.h>
#import <Foundation/NSRaise.h>

@implementation NSPredicateEditor

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

- (instancetype) initWithCoder: (NSCoder *) coder {
    NSUnimplementedMethod();
    return self;
}

- (BOOL) _forceUseDelegate {
    NSUnimplementedMethod();
    return NO;
}

@end
