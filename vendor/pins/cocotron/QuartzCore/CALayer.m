#import <Foundation/NSDictionary.h>
#import <QuartzCore/CAAnimation.h>
#import <QuartzCore/CALayer.h>
#import <CoreGraphics/CGColor.h>
#import <QuartzCore/CALayerContext.h>
#import <QuartzCore/CATransaction.h>

NSString *const kCAFilterLinear = @"linear";
NSString *const kCAFilterNearest = @"nearest";
NSString *const kCAFilterTrilinear = @"trilinear";

NSString *const kCAGravityResizeAspect = @"resizeAspect";
NSString *const kCAGravityResizeAspectFill = @"resizeAspectFill";

NSString *const kCAGravityCenter = @"center";
NSString *const kCAGravityTop = @"top";
NSString *const kCAGravityBottom = @"bottom";
NSString *const kCAGravityLeft = @"left";
NSString *const kCAGravityRight = @"right";
NSString *const kCAGravityTopLeft = @"topLeft";
NSString *const kCAGravityTopRight = @"topRight";
NSString *const kCAGravityBottomLeft = @"bottomLeft";
NSString *const kCAGravityBottomRight = @"bottomRight";
NSString *const kCAGravityResize = @"resize";

/*
 * HOW A ROUNDED CORNER IS ROUNDED. A circular corner is an arc; a CONTINUOUS one is the squircle
 * Apple has used for every rounded rectangle since iOS 7, and an application that wants its panels
 * to look like the system asks for it by name. Nothing here draws the difference yet, but the names
 * have to exist: they are strings, and referencing one stops the process loading. iA Writer names
 * the continuous one inside its own InterfaceFoundation framework.
 */
NSString *const kCACornerCurveCircular = @"circular";
NSString *const kCACornerCurveContinuous = @"continuous";

NSString *const kCAOnOrderIn = @"onOrderIn";
NSString *const kCAOnOrderOut = @"onOrderOut";
NSString *const kCATransition = @"transition";

NSString *const kCAContentsFormatRGBA8Uint = @"RGBA8";
NSString *const kCAContentsFormatRGBA16Float = @"RGBAh";
NSString *const kCAContentsFormatGray8Uint = @"Gray8";

@implementation CALayer

+ layer {
    return [[[self alloc] init] autorelease];
}

- (CALayerContext *) _context {
    return _context;
}

- (void) _setContext: (CALayerContext *) context {
    if (_context != context) {
        [_context deleteTextureId: _textureId];
        [_textureId release];
        _textureId = nil;
    }

    _context = context;
    [_sublayers makeObjectsPerformSelector: @selector(_setContext:)
                                withObject: context];
}

- (CALayer *) superlayer {
    return _superlayer;
}

- (NSArray *) sublayers {
    return _sublayers;
}

- (void) setSublayers: (NSArray *) sublayers {
    sublayers = [sublayers copy];
    [_sublayers release];
    _sublayers = sublayers;
    [_sublayers makeObjectsPerformSelector: @selector(_setSuperLayer:)
                                withObject: self];
    [_sublayers makeObjectsPerformSelector: @selector(_setContext:)
                                withObject: _context];
}

- (id<CALayerDelegate>) delegate {
    return _delegate;
}

- (void) setDelegate: (id<CALayerDelegate>)value {
    _delegate = value;
}

- (CGPoint) anchorPoint {
    return _anchorPoint;
}

- (void) setAnchorPoint: (CGPoint) value {
    _anchorPoint = value;
}

- (CGPoint) position {
    return _position;
}

- (void) setPosition: (CGPoint) value {
    CAAnimation *animation = [self animationForKey: @"position"];

    if (animation == nil && ![CATransaction disableActions]) {
        id action = [self actionForKey: @"position"];

        if (action != nil)
            [self addAnimation: action forKey: @"position"];
    }

    _position = value;
}

- (CGRect) bounds {
    return _bounds;
}

- (void) setBounds: (CGRect) value {
    CAAnimation *animation = [self animationForKey: @"bounds"];

    if (animation == nil && ![CATransaction disableActions]) {
        id action = [self actionForKey: @"bounds"];

        if (action != nil)
            [self addAnimation: action forKey: @"bounds"];
    }

    _bounds = value;
}

- (CGRect) frame {
    CGRect result;

    result.size = _bounds.size;
    result.origin.x = _position.x - result.size.width * _anchorPoint.x;
    result.origin.y = _position.y - result.size.height * _anchorPoint.y;

    return result;
}

- (void) setFrame: (CGRect) value {

    CGPoint position;

    position.x = value.origin.x + value.size.width * _anchorPoint.x;
    position.y = value.origin.y + value.size.height * _anchorPoint.y;

    [self setPosition: position];

    CGRect bounds = _bounds;

    bounds.size = value.size;

    [self setBounds: bounds];
}

- (CGFloat) opacity {
    return _opacity;
}

- (void) setOpacity: (CGFloat) value {
    CAAnimation *animation = [self animationForKey: @"opacity"];

    if (animation == nil && ![CATransaction disableActions]) {
        id action = [self actionForKey: @"opacity"];

        if (action != nil)
            [self addAnimation: action forKey: @"opacity"];
    }

    _opacity = value;
}

- (BOOL) opaque {
    return _opaque;
}

- (void) setOpaque: (BOOL) value {
    _opaque = value;
}

- (id) contents {
    return _contents;
}

- (void) setContents: (id) value {
    value = [value retain];
    [_contents release];
    _contents = value;
}

- (CATransform3D) transform {
    return _transform;
}

- (void) setTransform: (CATransform3D) value {
    _transform = value;
}

- (CATransform3D) sublayerTransform {
    return _sublayerTransform;
}

- (void) setSublayerTransform: (CATransform3D) value {
    _sublayerTransform = value;
}

/*
 * CONTENTS GRAVITY, SCALE, MASKING AND THE BOUNDS REDRAW FLAG.
 *
 * These four are set by ordinary layer backed views, and until now each one was an unrecognized
 * selector that ended the process: iTerm2 raised on -setContentsGravity: while building a terminal
 * window. They are STORED AND ANSWERED, and the drawing here does not yet honour them: contents are
 * drawn the way this layer has always drawn them, masksToBounds does not clip, and a bounds change
 * redraws or does not on the old rules. Storing them is what lets an application get past its own
 * setup, and the honest statement of what is not done belongs here rather than in a release note.
 */
- (NSString *) contentsGravity {
    return _contentsGravity != nil ? _contentsGravity : kCAGravityResize;
}

- (void) setContentsGravity: (NSString *) value {
    value = [value copy];
    [_contentsGravity release];
    _contentsGravity = value;
}

- (CGFloat) contentsScale {
    return _contentsScale > 0.0 ? _contentsScale : 1.0;
}

- (void) setContentsScale: (CGFloat) value {
    _contentsScale = value;
}

- (BOOL) masksToBounds {
    return _masksToBounds;
}

- (void) setMasksToBounds: (BOOL) value {
    _masksToBounds = value;
}

- (BOOL) needsDisplayOnBoundsChange {
    return _needsDisplayOnBoundsChange;
}

- (void) setNeedsDisplayOnBoundsChange: (BOOL) value {
    _needsDisplayOnBoundsChange = value;
}

- (NSString *) minificationFilter {
    return _minificationFilter;
}

- (void) setMinificationFilter: (NSString *) value {
    value = [value copy];
    [_minificationFilter release];
    _minificationFilter = value;
}

- (NSString *) magnificationFilter {
    return _magnificationFilter;
}

- (void) setMagnificationFilter: (NSString *) value {
    value = [value copy];
    [_magnificationFilter release];
    _magnificationFilter = value;
}

- init {
    _superlayer = nil;
    _sublayers = [NSArray new];
    _delegate = nil;
    _anchorPoint = CGPointMake(0.5, 0.5);
    _position = CGPointZero;
    _bounds = CGRectZero;
    _opacity = 1.0;
    _opaque = YES;
    _contents = nil;
    _transform = CATransform3DIdentity;
    _sublayerTransform = CATransform3DIdentity;
    _minificationFilter = kCAFilterLinear;
    _magnificationFilter = kCAFilterLinear;
    _animations = [[NSMutableDictionary alloc] init];
    return self;
}

- (void) dealloc {
    [_sublayers release];
    [_animations release];
    [_minificationFilter release];
    [_magnificationFilter release];
    [_actions release];
    [_contentsGravity release];
    [_name release];
    if (_backgroundColor != NULL)
        CGColorRelease(_backgroundColor);
    if (_borderColor != NULL)
        CGColorRelease(_borderColor);
    [super dealloc];
}

- (void) _setSuperLayer: (CALayer *) parent {
    _superlayer = parent;
}

- (void) _removeSublayer: (CALayer *) child {
    NSMutableArray *layers = [_sublayers mutableCopy];
    [layers removeObjectIdenticalTo: child];
    [self setSublayers: layers];
    [layers release];
}

- (void) addSublayer: (CALayer *) layer {
    [self setSublayers: [_sublayers arrayByAddingObject: layer]];
}

- (void) replaceSublayer: (CALayer *) layer with: (CALayer *) other {
    NSMutableArray *layers = [_sublayers mutableCopy];
    NSUInteger index = [_sublayers indexOfObjectIdenticalTo: layer];

    [layers replaceObjectAtIndex: index withObject: other];

    [self setSublayers: layers];
    [layers release];

    layer->_superlayer = nil;
}

- (void) display {
    if ([_delegate respondsToSelector: @selector(displayLayer:)])
        [_delegate displayLayer: self];
    else {
#if 0

#warning create bitmap context

    [self drawInContext:context];
    _contents=image;
    [self setContents:image];
#endif
    }
}

- (void) displayIfNeeded {
}

- (void) drawInContext: (CGContextRef) context {
    if ([_delegate respondsToSelector: @selector(drawLayer:inContext:)])
        [_delegate drawLayer: self inContext: context];
}

- (BOOL) needsDisplay {
    return _needsDisplay;
}

- (void) removeFromSuperlayer {
    [_superlayer _removeSublayer: self];
    _superlayer = nil;
    [self _setContext: nil];
}

/*
 * A DIRTY LAYER HAS TO MARK THE PATH THAT ACTUALLY DRAWS.
 *
 * Nothing here composites a layer tree, so setting this flag alone reached the screen never: iA
 * Writer marks its layers rather than its views, and painted three frames in its first second and
 * then nothing at all, however many events it processed, until a compositor resize forced the whole
 * window through the ordinary display path. That path draws layer backed views correctly, which is
 * what the resize frame proves, so a dirty layer tells its delegate view, which is what AppKit sets
 * a layer backed view up as.
 */
- (void) _ciderMarkDelegateViewNeedsDisplay {
    if ([_delegate respondsToSelector: @selector(setNeedsDisplay:)])
        [(id) _delegate setNeedsDisplay: YES];
}

- (void) setNeedsDisplay {
    _needsDisplay = YES;
    [self _ciderMarkDelegateViewNeedsDisplay];
}

- (void) setNeedsDisplayInRect: (CGRect) rect {
    _needsDisplay = YES;
    [self _ciderMarkDelegateViewNeedsDisplay];
}

- (void) addAnimation: (CAAnimation *) animation forKey: (NSString *) key {
    if (_context == nil)
        return;

    [_animations setObject: animation forKey: key];
    [_context startTimerIfNeeded];
}

- (CAAnimation *) animationForKey: (NSString *) key {
    return [_animations objectForKey: key];
}

- (void) removeAllAnimations {
    [_animations removeAllObjects];
}

- (void) removeAnimationForKey: (NSString *) key {
    [_animations removeObjectForKey: key];
}

- (NSArray *) animationKeys {
    return [_animations allKeys];
}

- valueForKey: (NSString *) key {
    // FIXME: KVC appears broken for structs

    if ([key isEqualToString: @"bounds"])
        return [NSValue valueWithRect: _bounds];
    if ([key isEqualToString: @"frame"])
        return [NSValue valueWithRect: [self frame]];

    return [super valueForKey: key];
}

/*
 * THE ORDINARY LAYER LOOK: a background, a border, a corner radius, a z position, a name and the
 * hidden flag. Every one of them was an unrecognized selector, and a layer backed view sets several
 * of them as a matter of course, so an application died on the first one it reached. They are
 * STORED AND ANSWERED and the drawing does NOT honour them yet: a layer with a background colour
 * still draws exactly what it drew before. Said plainly because the difference is invisible from
 * Objective-C and very visible on screen.
 */
- (CGColorRef) backgroundColor {
    return _backgroundColor;
}

- (void) setBackgroundColor: (CGColorRef) value {
    CGColorRef old = _backgroundColor;

    _backgroundColor = value != NULL ? CGColorRetain(value) : NULL;
    if (old != NULL)
        CGColorRelease(old);
}

- (CGColorRef) borderColor {
    return _borderColor;
}

- (void) setBorderColor: (CGColorRef) value {
    CGColorRef old = _borderColor;

    _borderColor = value != NULL ? CGColorRetain(value) : NULL;
    if (old != NULL)
        CGColorRelease(old);
}

- (CGFloat) borderWidth {
    return _borderWidth;
}

- (void) setBorderWidth: (CGFloat) value {
    _borderWidth = value;
}

- (CGFloat) cornerRadius {
    return _cornerRadius;
}

- (void) setCornerRadius: (CGFloat) value {
    _cornerRadius = value;
}

- (CGFloat) zPosition {
    return _zPosition;
}

- (void) setZPosition: (CGFloat) value {
    _zPosition = value;
}

- (BOOL) isHidden {
    return _hidden;
}

- (void) setHidden: (BOOL) value {
    _hidden = value;
}

- (NSString *) name {
    return _name;
}

- (void) setName: (NSString *) value {
    value = [value copy];
    [_name release];
    _name = value;
}

- (NSDictionary *) actions {
    return _actions;
}

- (void) setActions: (NSDictionary *) value {
    value = [value copy];
    [_actions release];
    _actions = value;
}

/*
 * THE ACTION MAP IS CONSULTED FIRST, WHICH IS THE POINT OF IT. An application that wants no implicit
 * animation for a property sets actions to a dictionary with NSNull under that key, and macOS then
 * returns nothing for it. Answering a fresh CABasicAnimation for every key regardless, as this did,
 * makes that setting unobservable. NSNull means NO ACTION and is returned as nil, exactly as the
 * documented lookup order says.
 */
- (id<CAAction>) actionForKey: (NSString *) key {
    if (key != nil && _actions != nil) {
        id action = [_actions objectForKey: key];

        if (action == [NSNull null])
            return nil;
        if (action != nil)
            return action;
    }

    CABasicAnimation *basic = [CABasicAnimation animationWithKeyPath: key];

    [basic setFromValue: [self valueForKey: key]];

    return basic;
}

- (NSNumber *) _textureId {
    return _textureId;
}

- (void) _setTextureId: (NSNumber *) value {
    value = [value copy];
    [_textureId release];
    _textureId = value;
}

@end
