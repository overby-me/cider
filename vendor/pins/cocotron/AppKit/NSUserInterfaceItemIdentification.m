#import <AppKit/NSUserInterfaceItemIdentification.h>

@implementation NSObject (NSUserInterfaceItemIdentification)

- (NSUserInterfaceItemIdentifier) userInterfaceItemIdentifier {
    if ([self respondsToSelector: @selector(identifier)]) {
        return [self identifier];
    }
    return nil;
}

- (void) setUserInterfaceItemIdentifier: (NSUserInterfaceItemIdentifier) userInterfaceItemIdentifier {
    if ([self respondsToSelector: @selector(setIdentifier:)]) {
        [self setIdentifier: userInterfaceItemIdentifier];
    }
}

@end
