#import <Foundation/Foundation.h>

@interface NSControlAuxiliary : NSObject {
    NSInteger _tag;
    id _target;
    SEL _action;
}

- (id) target;
- (SEL) action;
- (NSInteger) tag;

- (void) setTag: (NSInteger) tag;
- (void) setAction: (SEL) action;
- (void) setTarget: (id) target;

@end
