#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSCIImageRep.h>
#import <AppKit/NSImageRep.h>
#import <AppKit/NSRaise.h>

@implementation CIImage (CIImageRepAdditions)

- initWithBitmapImageRep: (NSBitmapImageRep *) bitmapImageRep {
    return [self initWithCGImage: [bitmapImageRep CGImage]];
}

@end

@interface NSCIImageRep : NSImageRep
@end

@implementation NSCIImageRep

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
