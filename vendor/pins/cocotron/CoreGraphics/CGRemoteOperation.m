#import <CoreGraphics/CGRemoteOperation.h>

CGError CGScreenRegisterMoveCallback(CGScreenUpdateMoveCallback callback, void *userInfo) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}

void CGScreenUnregisterMoveCallback(CGScreenUpdateMoveCallback callback, void *userInfo) {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return nil;
}
