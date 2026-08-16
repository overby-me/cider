
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/CAAction.h>
#import <QuartzCore/CATransform3D.h>

@class CAAnimation, CALayerContext, CALayer;

enum {
    kCALayerNotSizable = 0x00,
    kCALayerMinXMargin = 0x01,
    kCALayerWidthSizable = 0x02,
    kCALayerMaxXMargin = 0x04,
    kCALayerMinYMargin = 0x08,
    kCALayerHeightSizable = 0x10,
    kCALayerMaxYMargin = 0x20,
};

CA_EXPORT NSString *const kCAFilterLinear;
CA_EXPORT NSString *const kCAFilterNearest;
CA_EXPORT NSString *const kCAFilterTrilinear;

CA_EXPORT NSString *const kCAGravityResizeAspect;
CA_EXPORT NSString *const kCAGravityResizeAspectFill;

CA_EXPORT NSString *const kCAGravityCenter;
CA_EXPORT NSString *const kCAGravityTop;
CA_EXPORT NSString *const kCAGravityBottom;
CA_EXPORT NSString *const kCAGravityLeft;
CA_EXPORT NSString *const kCAGravityRight;
CA_EXPORT NSString *const kCAGravityTopLeft;
CA_EXPORT NSString *const kCAGravityTopRight;
CA_EXPORT NSString *const kCAGravityBottomLeft;
CA_EXPORT NSString *const kCAGravityBottomRight;
CA_EXPORT NSString *const kCAGravityResize;

CA_EXPORT NSString *const kCAOnOrderIn;
typedef NSString *CACornerCurve;
extern NSString *const kCACornerCurveCircular;
extern NSString *const kCACornerCurveContinuous;

CA_EXPORT NSString *const kCAOnOrderOut;
CA_EXPORT NSString *const kCATransition;

CA_EXPORT NSString *const kCAContentsFormatRGBA8Uint;
CA_EXPORT NSString *const kCAContentsFormatRGBA16Float;
CA_EXPORT NSString *const kCAContentsFormatGray8Uint;

@protocol CALayerDelegate <NSObject>

@optional

- (void)displayLayer: (CALayer*)layer;

- (void)drawLayer: (CALayer*)layer
        inContext: (CGContextRef)ctx;

- (void)layerWillDraw: (CALayer*)layer;

- (void)layoutSublayersOfLayer: (CALayer*)layer;

- (id<CAAction>)actionForLayer: (CALayer*)layer
                        forKey: (NSString*)event;

@end

@interface CALayer : NSObject {
    CALayerContext *_context;
    CALayer *_superlayer;
    NSArray *_sublayers;
    id _delegate;
    CGPoint _anchorPoint;
    CGPoint _position;
    CGRect _bounds;
    CGFloat _opacity;
    BOOL _opaque;
    id _contents;
    CATransform3D _transform;
    CATransform3D _sublayerTransform;
    NSString *_minificationFilter;
    NSString *_magnificationFilter;
    NSString *_contentsGravity;
    NSDictionary *_actions;
    CGColorRef _backgroundColor;
    CGColorRef _borderColor;
    CGFloat _borderWidth;
    CGFloat _cornerRadius;
    CGFloat _zPosition;
    BOOL _hidden;
    NSString *_name;
    CGFloat _contentsScale;
    BOOL _masksToBounds;
    BOOL _needsDisplayOnBoundsChange;
    BOOL _needsDisplay;
    NSMutableDictionary *_animations;
    NSNumber *_textureId;
}

+ layer;

@property(readonly) CALayer *superlayer;
@property(copy) NSArray *sublayers;
@property(assign) id<CALayerDelegate> delegate;
@property CGPoint anchorPoint;
@property CGPoint position;
@property CGRect bounds;
@property CGRect frame;
@property CGFloat opacity;
@property BOOL opaque;
@property(retain) id contents;
//@property CATransform3D transform;
@property CATransform3D sublayerTransform;

@property(copy) NSString *minificationFilter;
@property(copy) NSString *magnificationFilter;

/* HOW THE CONTENTS SIT IN THE LAYER, and the scale they are drawn at. A layer backed view sets
 * these as a matter of course, and every one of them was an unrecognized selector. */
@property(copy) NSString *contentsGravity;
@property CGFloat contentsScale;
@property BOOL masksToBounds;
@property BOOL needsDisplayOnBoundsChange;

/* THE ACTION MAP, which is how an application turns an implicit animation OFF. */
@property(copy) NSDictionary *actions;

/* THE ORDINARY LAYER LOOK. Stored and answered; the drawing here does not honour them yet. */
@property CGColorRef backgroundColor;
@property CGColorRef borderColor;
@property CGFloat borderWidth;
@property CGFloat cornerRadius;
@property CGFloat zPosition;
@property(getter=isHidden) BOOL hidden;
@property(copy) NSString *name;

- init;

- (void) addSublayer: (CALayer *) layer;
- (void) replaceSublayer: (CALayer *) layer with: (CALayer *) other;
- (void) display;
- (void) displayIfNeeded;
- (void) drawInContext: (CGContextRef) context;
- (BOOL) needsDisplay;
- (void) removeFromSuperlayer;
- (void) setNeedsDisplay;
- (void) setNeedsDisplayInRect: (CGRect) rect;

- (void) addAnimation: (CAAnimation *) animation forKey: (NSString *) key;
- (CAAnimation *) animationForKey: (NSString *) key;
- (void) removeAllAnimations;
- (void) removeAnimationForKey: (NSString *) key;
- (NSArray *) animationKeys;

- (id<CAAction>) actionForKey: (NSString *) key;

@end

@protocol CALayoutManager <NSObject>
@optional

- (CGSize) preferredSizeOfLayer: (CALayer *) layer;
- (void) invalidateLayoutOfLayer: (CALayer *) layer;
- (void) layoutSublayersOfLayer: (CALayer *) layer;

@end
