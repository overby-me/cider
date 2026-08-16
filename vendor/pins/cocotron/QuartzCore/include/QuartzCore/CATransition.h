#import <QuartzCore/CAAnimation.h>

@interface CATransition : CAAnimation {
    NSString *_type;
    NSString *_subtype;
    CGFloat _startProgress;
    CGFloat _endProgress;
}

@property(copy) NSString *type;
@property(copy) NSString *subtype;
@property CGFloat startProgress;
@property CGFloat endProgress;

@end
