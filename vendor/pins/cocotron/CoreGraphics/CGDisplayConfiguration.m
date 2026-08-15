#import <CoreGraphics/CGDisplayConfiguration.h>

CGError CGDisplayRegisterReconfigurationCallback(CGDisplayReconfigurationCallBack callback, void *userInfo) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return kCGErrorSuccess;
}

CGError CGDisplayRemoveReconfigurationCallback(CGDisplayReconfigurationCallBack callback, void *userInfo) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return kCGErrorSuccess;
}
