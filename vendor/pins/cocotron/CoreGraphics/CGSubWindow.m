#import <CoreGraphics/CGSubWindow.h>
#import <Onyx2D/O2Exceptions.h>

@implementation CGSubWindow

- (void *) nativeWindow {
    O2InvalidAbstractInvocation();
    return NULL;
}

- (void) show {
    O2InvalidAbstractInvocation();
}

- (void) hide {
    O2InvalidAbstractInvocation();
}

- (void) setFrame: (CGRect) frame {
    O2InvalidAbstractInvocation();
}

@end
