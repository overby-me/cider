#import <Foundation/NSString.h>

typedef NSString* NSUserInterfaceItemIdentifier;

@protocol NSUserInterfaceItemIdentification

@property(copy) NSUserInterfaceItemIdentifier identifier;

@end

@interface NSObject (NSUserInterfaceItemIdentification)

@property(copy) NSUserInterfaceItemIdentifier userInterfaceItemIdentifier;

@end
