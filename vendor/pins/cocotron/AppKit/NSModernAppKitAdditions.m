/*
 * CLASSES AND A CONSTANT A MODERN APPLICATION LINKS AGAINST.
 *
 * These are together in one file because they have one thing in common and nothing else: each is a
 * SYMBOL that stops a current binary at load time, before any behaviour could matter. iTerm2 3.6.10
 * links all six, and dyld refuses to start the process while any one of them is missing.
 *
 * Each is written as the smallest HONEST version of itself rather than a forwarding stub, because a
 * stub whose method signature says the method returns void hands a caller whatever was in the
 * return register. Where the behaviour needs a system this tree does not have, the answer is the
 * one macOS gives when that system is unavailable: no files promised, no touches, no glass.
 */

#import <AppKit/NSModernAppKitAdditions.h>
#import <AppKit/NSView.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSToolbarItem.h>
#import <AppKit/NSSearchField.h>
#import <AppKit/NSImage.h>
#import <Foundation/Foundation.h>

/* The key under which a text field puts the movement that ended editing, in the notification user
 * info. It is a string constant and it has been in AppKit since 10.11. */
NSString *const NSTextMovementUserInfoKey = @"NSTextMovement";

/*
 * A promised file receiver: the drag destination side of a promise. Nothing in this tree implements
 * file promises, so it names no types, promises no files, and calls the completion handler with an
 * error, which is what a receiver does when the promise cannot be honoured.
 */
@implementation NSFilePromiseReceiver

+ (NSArray *) readableDraggedTypes {
    return [NSArray array];
}

- (NSArray<NSString *> *) fileTypes {
    return [NSArray array];
}

- (NSArray<NSString *> *) fileNames {
    return [NSArray array];
}

- (void) receivePromisedFilesAtDestination: (NSURL *) destinationDir
                                   options: (NSDictionary *) options
                            operationQueue: (NSOperationQueue *) operationQueue
                                    reader: (void (^)(NSURL *, NSError *)) reader
{
    if (reader == NULL)
        return;

    NSError *error = [NSError errorWithDomain: NSCocoaErrorDomain
                                         code: NSFeatureUnsupportedError
                                     userInfo: nil];

    [operationQueue addOperationWithBlock: ^{
        reader(nil, error);
    }];
}

@end

/*
 * The glass background view of macOS 26. There is no glass here and there is no vibrancy behind an
 * arbitrary view either, so it is an ordinary view: it draws its tint colour if it has been given
 * one and otherwise nothing, which leaves whatever is behind it visible.
 */
@implementation NSGlassEffectView {
    NSView *_contentView;
    NSColor *_tintColor;
    CGFloat _cornerRadius;
}

- (NSView *) contentView {
    return _contentView;
}

- (void) setContentView: (NSView *) view {
    if (_contentView == view)
        return;

    [_contentView removeFromSuperview];
    _contentView = view;
    if (view != nil) {
        [view setFrame: [self bounds]];
        [self addSubview: view];
    }
}

- (NSColor *) tintColor {
    return _tintColor;
}

- (void) setTintColor: (NSColor *) color {
    color = [color retain];
    [_tintColor release];
    _tintColor = color;
    [self setNeedsDisplay: YES];
}

- (CGFloat) cornerRadius {
    return _cornerRadius;
}

- (void) setCornerRadius: (CGFloat) radius {
    _cornerRadius = radius;
    [self setNeedsDisplay: YES];
}

- (void) drawRect: (NSRect) rect {
    if (_tintColor != nil) {
        [_tintColor set];
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
    }
}

- (void) dealloc {
    [_tintColor release];
    [super dealloc];
}

@end

/*
 * A symbol image configuration. The symbol images themselves are an Apple font this tree does not
 * have, so nothing here draws; what the class does is CARRY the configuration, which is what a
 * caller reads back and passes around.
 */
@implementation NSImageSymbolConfiguration {
    CGFloat _pointSize;
    NSInteger _weight;
    NSInteger _scale;
}

+ (instancetype) configurationWithPointSize: (CGFloat) pointSize
                                     weight: (NSInteger) weight
                                      scale: (NSInteger) scale
{
    NSImageSymbolConfiguration *configuration = [[[self alloc] init] autorelease];

    configuration->_pointSize = pointSize;
    configuration->_weight = weight;
    configuration->_scale = scale;
    return configuration;
}

+ (instancetype) configurationWithPointSize: (CGFloat) pointSize weight: (NSInteger) weight {
    return [self configurationWithPointSize: pointSize weight: weight scale: 0];
}

+ (instancetype) configurationWithScale: (NSInteger) scale {
    return [self configurationWithPointSize: 0 weight: 0 scale: scale];
}

+ (instancetype) configurationWithTextStyle: (NSString *) style {
    return [self configurationWithPointSize: 0 weight: 0 scale: 0];
}

- (CGFloat) pointSize {
    return _pointSize;
}

- (NSInteger) weight {
    return _weight;
}

- (NSInteger) scale {
    return _scale;
}

@end

/*
 * The toolbar item that holds a search field. It is a real toolbar item with a real search field in
 * it, which is all this class is on macOS as well; what it adds there is the collapsing behaviour in
 * a narrow toolbar, and that is not implemented.
 */
@implementation NSSearchToolbarItem {
    NSSearchField *_searchField;
    CGFloat _preferredWidthForSearchField;
    BOOL _resignsFirstResponderWithCancel;
}

- (NSSearchField *) searchField {
    if (_searchField == nil) {
        _searchField = [[NSSearchField alloc] initWithFrame: NSMakeRect(0, 0, 180, 22)];
        [self setView: _searchField];
    }
    return _searchField;
}

- (void) setSearchField: (NSSearchField *) field {
    field = [field retain];
    [_searchField release];
    _searchField = field;
    [self setView: field];
}

- (CGFloat) preferredWidthForSearchField {
    return _preferredWidthForSearchField;
}

- (void) setPreferredWidthForSearchField: (CGFloat) width {
    _preferredWidthForSearchField = width;
}

- (BOOL) resignsFirstResponderWithCancel {
    return _resignsFirstResponderWithCancel;
}

- (void) setResignsFirstResponderWithCancel: (BOOL) value {
    _resignsFirstResponderWithCancel = value;
}

- (void) beginSearchInteraction {
    [[[self searchField] window] makeFirstResponder: [self searchField]];
}

- (void) endSearchInteraction {
    [[[self searchField] window] makeFirstResponder: nil];
}

- (void) dealloc {
    [_searchField release];
    [super dealloc];
}

@end

/*
 * A touch on a trackpad. There is no multitouch device behind this backend, so no NSTouch is ever
 * created: the class exists for the link, and its accessors describe the empty touch it would be.
 */
@implementation NSTouch

- (id) identity {
    return self;
}

- (NSInteger) phase {
    return 0;
}

- (NSPoint) normalizedPosition {
    return NSMakePoint(0, 0);
}

- (BOOL) isResting {
    return NO;
}

- (id) device {
    return nil;
}

- (NSSize) deviceSize {
    return NSMakeSize(0, 0);
}

@end
