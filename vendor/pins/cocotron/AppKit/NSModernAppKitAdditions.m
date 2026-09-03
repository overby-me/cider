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
#import <AppKit/NSResponder.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSView.h>
#import <AppKit/NSGraphics.h>
#import <Foundation/NSLayoutAnchor.h>
#import <AppKit/NSAppearance.h>
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
    NSArray *_paletteColors;
    NSColor *_hierarchicalColor;
    NSInteger _renderingMode;
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

/*
 * THE COLOUR CONFIGURATIONS.
 *
 * Missing, +configurationWithPaletteColors: raised, NSApplication caught it per event, and the only
 * sign iA Writer left was a window that never appeared.
 *
 * Rendering mode is STORED, NOT APPLIED: nothing in this stack draws SF Symbols. Callers read these
 * back and combine them, which is what makes carrying the choice worth doing.
 */
+ (instancetype) configurationWithPaletteColors: (NSArray *) paletteColors {
    NSImageSymbolConfiguration *configuration = [[[self alloc] init] autorelease];

    configuration->_paletteColors = [paletteColors copy];
    configuration->_renderingMode = NSImageSymbolRenderingModePalette;
    return configuration;
}

+ (instancetype) configurationWithHierarchicalColor: (NSColor *) hierarchicalColor {
    NSImageSymbolConfiguration *configuration = [[[self alloc] init] autorelease];

    configuration->_hierarchicalColor = [hierarchicalColor retain];
    configuration->_renderingMode = NSImageSymbolRenderingModeHierarchical;
    return configuration;
}

+ (instancetype) configurationPreferringMonochrome {
    NSImageSymbolConfiguration *configuration = [[[self alloc] init] autorelease];

    configuration->_renderingMode = NSImageSymbolRenderingModeMonochrome;
    return configuration;
}

+ (instancetype) configurationPreferringHierarchical {
    NSImageSymbolConfiguration *configuration = [[[self alloc] init] autorelease];

    configuration->_renderingMode = NSImageSymbolRenderingModeHierarchical;
    return configuration;
}

+ (instancetype) configurationPreferringMulticolor {
    NSImageSymbolConfiguration *configuration = [[[self alloc] init] autorelease];

    configuration->_renderingMode = NSImageSymbolRenderingModeMulticolor;
    return configuration;
}

/* The argument wins wherever it says anything, which is what makes these composable. */
- (NSImageSymbolConfiguration *) configurationByApplyingConfiguration:
        (NSImageSymbolConfiguration *) configuration
{
    if (configuration == nil) return self;

    NSImageSymbolConfiguration *combined = [[[[self class] alloc] init] autorelease];

    combined->_pointSize = configuration->_pointSize != 0 ? configuration->_pointSize : _pointSize;
    combined->_weight = configuration->_weight != 0 ? configuration->_weight : _weight;
    combined->_scale = configuration->_scale != 0 ? configuration->_scale : _scale;
    combined->_paletteColors = [(configuration->_paletteColors != nil
            ? configuration->_paletteColors : _paletteColors) copy];
    combined->_hierarchicalColor = [(configuration->_hierarchicalColor != nil
            ? configuration->_hierarchicalColor : _hierarchicalColor) retain];
    combined->_renderingMode = configuration->_renderingMode != NSImageSymbolRenderingModeAutomatic
            ? configuration->_renderingMode : _renderingMode;
    return combined;
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

- (NSArray *) paletteColors {
    return _paletteColors;
}

- (NSColor *) hierarchicalColor {
    return _hierarchicalColor;
}

- (NSInteger) renderingMode {
    return _renderingMode;
}

- (void) dealloc {
    [_paletteColors release];
    [_hierarchicalColor release];
    [super dealloc];
}

@end

/* No SF Symbol rendering here, so there is nothing to apply; raising instead would cost the caller
 * its window. */
@implementation NSImage (NSImageSymbolConfiguration)

- (NSImage *) imageWithSymbolConfiguration: (NSImageSymbolConfiguration *) configuration {
    return self;
}

/*
 * A SYMBOL BY NAME, which for an application's OWN symbols is a real answer.
 *
 * SF Symbols are an Apple font that is not here, so a system symbol name has nothing behind it. A
 * name from an application bundle is different: custom symbols are ordinary artwork in the same
 * asset catalog as everything else, and +imageNamed: already reads those. So look it up, and answer
 * nil when there is nothing, which is what an unavailable symbol is.
 *
 * NIL RATHER THAN AN EXCEPTION IS THE POINT. Unimplemented, this selector raised, NSApplication
 * caught it, and iA Writer finished launching with zero windows: whatever was building the window
 * was abandoned mid-construction. A caller handed nil draws no icon and keeps its window.
 */
+ (NSImage *) imageWithSymbolName: (NSString *) name
                           bundle: (NSBundle *) bundle
                    variableValue: (double) variableValue
{
    if (name == nil)
        return nil;
    return [self imageNamed: name];
}

+ (NSImage *) imageWithSystemSymbolName: (NSString *) name
               accessibilityDescription: (NSString *) description
{
    if (name == nil)
        return nil;
    return [self imageNamed: name];
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

/*
 * THE TITLEBAR SEPARATOR, carried rather than drawn.
 *
 * macOS 11 added the hairline between a titlebar and the content below it, and an application sets
 * the style while it builds its window. Nothing here draws that line, so the value is stored and
 * read back; what matters is that asking does not raise. Unimplemented, it did: iTerm2 built its
 * window, set the style, and the process terminated on an uncaught exception with the window it had
 * just made still on screen.
 */
@implementation NSWindow (NSTitlebarSeparator)

static NSMapTable *_ciderSeparatorStyles = nil;

- (NSTitlebarSeparatorStyle) titlebarSeparatorStyle {
    if (_ciderSeparatorStyles == nil)
        return NSTitlebarSeparatorStyleAutomatic;
    return (NSTitlebarSeparatorStyle) (NSInteger) (intptr_t)
            NSMapGet(_ciderSeparatorStyles, (const void *) self);
}

- (void) setTitlebarSeparatorStyle: (NSTitlebarSeparatorStyle) style {
    if (_ciderSeparatorStyles == nil) {
        _ciderSeparatorStyles = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                                 NSIntegerMapValueCallBacks, 0);
    }
    NSMapInsert(_ciderSeparatorStyles, (const void *) self, (const void *) (intptr_t) style);
}

@end

/*
 * THE USER ACTIVITY A RESPONDER CARRIES, which is Handoff and does not happen here.
 *
 * Nothing continues an activity on another device, so the object is stored and handed back and no
 * more. Storing it is not optional though: the setter is what a window controller calls while it
 * builds its window, and unimplemented it raised. iA Writer terminated on
 * -[IALibraryWindowController setUserActivity:] with its library window half built.
 *
 * NSResponder rather than NSWindowController, because that is where the property lives and any
 * responder in a chain may be asked.
 */
@implementation NSResponder (NSUserActivityCarrying)

static NSMapTable *_ciderUserActivities = nil;

- (id) userActivity {
    if (_ciderUserActivities == nil)
        return nil;
    return (id) NSMapGet(_ciderUserActivities, (const void *) self);
}

- (void) setUserActivity: (id) activity {
    if (_ciderUserActivities == nil) {
        _ciderUserActivities = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                                NSObjectMapValueCallBacks, 0);
    }
    if (activity == nil)
        NSMapRemove(_ciderUserActivities, (const void *) self);
    else
        NSMapInsert(_ciderUserActivities, (const void *) self, (const void *) activity);
}

- (void) updateUserActivityState: (id) activity {
}

@end

/*
 * THE MODERN NSVIEW SWITCHES, carried and answered rather than acted on.
 *
 * Each of these is a setter an application calls while building a view, and each one unimplemented
 * takes the whole application rather than the effect it asked for: iA Writer raised on
 * -[NSView setClipsToBounds:] with its split view already assembled.
 *
 * What they mean here:
 *   clipsToBounds       drawing is clipped to the view's bounds already, so the flag is stored and
 *                       reported. YES by default is what this implementation actually does.
 *   canDrawSubviewsIntoLayer, layerContentsRedrawPolicy
 *                       hints about layer-backed drawing, which is a performance choice and changes
 *                       nothing about what appears.
 *   needsLayout, layoutSubtreeIfNeeded
 *                       there is no deferred layout pass here; laying out now is the honest answer
 *                       and leaves the view hierarchy in the state the caller is about to read.
 *   hugging and compression resistance
 *                       Auto Layout priorities, carried per orientation so that a view asked for
 *                       one back gets what it set.
 */
@implementation NSView (NSModernViewSwitches)

static NSMapTable *_ciderViewFlags = nil;

enum {
    _CiderViewClipsToBounds = 1 << 0,
    _CiderViewClipsSet = 1 << 1,
    _CiderViewSubviewsIntoLayer = 1 << 2,
};

static NSInteger _CiderViewFlagsOf(id view) {
    if (_ciderViewFlags == nil)
        return 0;
    return (NSInteger) (intptr_t) NSMapGet(_ciderViewFlags, (const void *) view);
}

static void _CiderSetViewFlags(id view, NSInteger flags) {
    if (_ciderViewFlags == nil) {
        _ciderViewFlags = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                           NSIntegerMapValueCallBacks, 0);
    }
    NSMapInsert(_ciderViewFlags, (const void *) view, (const void *) (intptr_t) flags);
}

- (BOOL) clipsToBounds {
    NSInteger flags = _CiderViewFlagsOf(self);

    if ((flags & _CiderViewClipsSet) == 0)
        return YES;
    return (flags & _CiderViewClipsToBounds) != 0;
}

- (void) setClipsToBounds: (BOOL) clips {
    NSInteger flags = _CiderViewFlagsOf(self) | _CiderViewClipsSet;

    if (clips)
        flags |= _CiderViewClipsToBounds;
    else
        flags &= ~_CiderViewClipsToBounds;
    _CiderSetViewFlags(self, flags);
}

- (BOOL) canDrawSubviewsIntoLayer {
    return (_CiderViewFlagsOf(self) & _CiderViewSubviewsIntoLayer) != 0;
}

- (void) setCanDrawSubviewsIntoLayer: (BOOL) canDraw {
    NSInteger flags = _CiderViewFlagsOf(self);

    if (canDraw)
        flags |= _CiderViewSubviewsIntoLayer;
    else
        flags &= ~_CiderViewSubviewsIntoLayer;
    _CiderSetViewFlags(self, flags);
}

- (void) setNeedsLayout: (BOOL) needsLayout {
    if (needsLayout) {
        [self _ciderMarkNeedsConstraintSolve];
        [self setNeedsDisplay: YES];
    }
}

- (BOOL) needsLayout {
    return [self _ciderNeedsLayout];
}

- (void) layoutSubtreeIfNeeded {
    /* Constraints first, then the view's own layout, then whatever it left degenerate. */
    [self _ciderSolveConstraints];
    [self layout];
    [self _ciderSizeDegenerateSubviews];
    for (NSView *subview in [self subviews])
        [subview layoutSubtreeIfNeeded];
}

static NSMapTable *_ciderViewPriorities = nil;

static NSString *_CiderPriorityKey(id view, NSInteger orientation, BOOL hugging) {
    return [NSString stringWithFormat: @"%p-%ld-%d", view, (long) orientation, hugging ? 1 : 0];
}

static void _CiderSetPriority(id view, NSInteger orientation, BOOL hugging, float priority) {
    if (_ciderViewPriorities == nil) {
        _ciderViewPriorities = NSCreateMapTable(NSObjectMapKeyCallBacks,
                                                NSIntegerMapValueCallBacks, 0);
    }
    NSMapInsert(_ciderViewPriorities, (const void *) _CiderPriorityKey(view, orientation, hugging),
                (const void *) (intptr_t) (NSInteger) priority);
}

static float _CiderPriority(id view, NSInteger orientation, BOOL hugging, float fallback) {
    if (_ciderViewPriorities == nil)
        return fallback;

    NSString *key = _CiderPriorityKey(view, orientation, hugging);
    if (NSMapGet(_ciderViewPriorities, (const void *) key) == NULL)
        return fallback;
    return (float) (NSInteger) (intptr_t) NSMapGet(_ciderViewPriorities, (const void *) key);
}

- (void) setContentHuggingPriority: (float) priority forOrientation: (NSInteger) orientation {
    _CiderSetPriority(self, orientation, YES, priority);
}

- (float) contentHuggingPriorityForOrientation: (NSInteger) orientation {
    return _CiderPriority(self, orientation, YES, 250);
}

- (void) setContentCompressionResistancePriority: (float) priority
                                  forOrientation: (NSInteger) orientation
{
    _CiderSetPriority(self, orientation, NO, priority);
}

- (float) contentCompressionResistancePriorityForOrientation: (NSInteger) orientation {
    return _CiderPriority(self, orientation, NO, 750);
}

@end

/*
 * SCROLL VIEW CONTENT INSETS, carried and honoured where it is cheap to do so.
 *
 * macOS 10.10 let a scroll view hold its content clear of a titlebar or a toolbar. Nothing here
 * overlays a scroll view that way, so the insets are stored and reported rather than applied to the
 * document view, and automaticallyAdjustsContentInsets is NO because nothing adjusts them.
 *
 * Storing is not optional: iA Writer sets them on its document scroll view while building the
 * library window, and unimplemented the setter raised and took the application.
 */
@interface NSScrollView (NSModernScrollInsets)
- (NSEdgeInsets) contentInsets;
- (void) setContentInsets: (NSEdgeInsets) insets;
- (NSEdgeInsets) scrollerInsets;
- (void) setScrollerInsets: (NSEdgeInsets) insets;
- (BOOL) automaticallyAdjustsContentInsets;
- (void) setAutomaticallyAdjustsContentInsets: (BOOL) adjusts;
@end

@implementation NSScrollView (NSModernScrollInsets)

static NSMapTable *_ciderContentInsets = nil;
static NSMapTable *_ciderScrollerInsets = nil;

static NSEdgeInsets _CiderInsetsFor(NSMapTable *table, id view) {
    NSEdgeInsets zero = { 0, 0, 0, 0 };
    NSValue *value;

    if (table == nil)
        return zero;

    value = (NSValue *) NSMapGet(table, (const void *) view);
    if (value == nil)
        return zero;
    [value getValue: &zero];
    return zero;
}

static void _CiderSetInsets(NSMapTable **table, id view, NSEdgeInsets insets) {
    if (*table == nil) {
        *table = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks, NSObjectMapValueCallBacks, 0);
    }
    NSMapInsert(*table, (const void *) view,
                (const void *) [NSValue valueWithBytes: &insets objCType: @encode(NSEdgeInsets)]);
}

- (NSEdgeInsets) contentInsets {
    return _CiderInsetsFor(_ciderContentInsets, self);
}

- (void) setContentInsets: (NSEdgeInsets) insets {
    _CiderSetInsets(&_ciderContentInsets, self, insets);
}

- (NSEdgeInsets) scrollerInsets {
    return _CiderInsetsFor(_ciderScrollerInsets, self);
}

- (void) setScrollerInsets: (NSEdgeInsets) insets {
    _CiderSetInsets(&_ciderScrollerInsets, self, insets);
}

- (BOOL) automaticallyAdjustsContentInsets {
    return NO;
}

- (void) setAutomaticallyAdjustsContentInsets: (BOOL) adjusts {
}

@end

/*
 * TEXT VIEW SWITCHES a modern editor sets, carried rather than acted on.
 *
 * A link tooltip, a completion popover and the dark-appearance colour mapping are all things this
 * implementation does not do, so the flags are stored and reported and the link attributes are kept
 * for whoever asks. Each setter unimplemented raised: iA Writer stopped at
 * -[IAEditorTextView setDisplaysLinkToolTips:] with its editor otherwise built.
 */
@interface NSTextView (NSModernTextViewSwitches)
- (BOOL) displaysLinkToolTips;
- (void) setDisplaysLinkToolTips: (BOOL) displays;
- (BOOL) usesAdaptiveColorMappingForDarkAppearance;
- (void) setUsesAdaptiveColorMappingForDarkAppearance: (BOOL) uses;
- (BOOL) isAutomaticTextCompletionEnabled;
- (void) setAutomaticTextCompletionEnabled: (BOOL) enabled;
- (NSDictionary *) linkTextAttributes;
- (void) setLinkTextAttributes: (NSDictionary *) attributes;
@end

@implementation NSTextView (NSModernTextViewSwitches)

static NSMapTable *_ciderTextViewFlags = nil;
static NSMapTable *_ciderLinkAttributes = nil;

enum {
    _CiderTextViewLinkToolTips = 1 << 0,
    _CiderTextViewAdaptiveColor = 1 << 1,
    _CiderTextViewTextCompletion = 1 << 2,
};

static BOOL _CiderTextViewFlag(id view, NSInteger bit) {
    if (_ciderTextViewFlags == nil)
        return NO;
    return ((NSInteger) (intptr_t) NSMapGet(_ciderTextViewFlags, (const void *) view) & bit) != 0;
}

static void _CiderSetTextViewFlag(id view, NSInteger bit, BOOL on) {
    NSInteger flags;

    if (_ciderTextViewFlags == nil) {
        _ciderTextViewFlags = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                               NSIntegerMapValueCallBacks, 0);
    }
    flags = (NSInteger) (intptr_t) NSMapGet(_ciderTextViewFlags, (const void *) view);
    if (on)
        flags |= bit;
    else
        flags &= ~bit;
    NSMapInsert(_ciderTextViewFlags, (const void *) view, (const void *) (intptr_t) flags);
}

- (BOOL) displaysLinkToolTips {
    return _CiderTextViewFlag(self, _CiderTextViewLinkToolTips);
}

- (void) setDisplaysLinkToolTips: (BOOL) displays {
    _CiderSetTextViewFlag(self, _CiderTextViewLinkToolTips, displays);
}

- (BOOL) usesAdaptiveColorMappingForDarkAppearance {
    return _CiderTextViewFlag(self, _CiderTextViewAdaptiveColor);
}

- (void) setUsesAdaptiveColorMappingForDarkAppearance: (BOOL) uses {
    _CiderSetTextViewFlag(self, _CiderTextViewAdaptiveColor, uses);
}

- (BOOL) isAutomaticTextCompletionEnabled {
    return _CiderTextViewFlag(self, _CiderTextViewTextCompletion);
}

- (void) setAutomaticTextCompletionEnabled: (BOOL) enabled {
    _CiderSetTextViewFlag(self, _CiderTextViewTextCompletion, enabled);
}

- (NSDictionary *) linkTextAttributes {
    if (_ciderLinkAttributes == nil)
        return nil;
    return (NSDictionary *) NSMapGet(_ciderLinkAttributes, (const void *) self);
}

- (void) setLinkTextAttributes: (NSDictionary *) attributes {
    if (_ciderLinkAttributes == nil) {
        _ciderLinkAttributes = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                                NSObjectMapValueCallBacks, 0);
    }
    if (attributes == nil)
        NSMapRemove(_ciderLinkAttributes, (const void *) self);
    else
        NSMapInsert(_ciderLinkAttributes, (const void *) self, (const void *) attributes);
}

@end

/*
 * A COLOUR THAT ASKS THE APPEARANCE, resolved once instead of on every use.
 *
 * macOS 10.15 lets an application supply a block that answers a colour for whatever appearance is
 * current, which is how a light and a dark value live under one name. Nothing here switches
 * appearance while running, so the block is called once with the appearance in force and the answer
 * IS the colour. That is a real colour rather than a placeholder, and it is right for as long as the
 * appearance does not change.
 *
 * Unimplemented it raised, and it is a class method, so iA Writer went with it while building the
 * colours for its editor.
 */
@interface NSColor (NSDynamicColor)
+ (NSColor *) colorWithName: (NSString *) name
            dynamicProvider: (NSColor * (^)(NSAppearance *appearance)) provider;
@end

@implementation NSColor (NSDynamicColor)

+ (NSColor *) colorWithName: (NSString *) name
            dynamicProvider: (NSColor * (^)(NSAppearance *appearance)) provider
{
    NSAppearance *appearance;
    NSColor *resolved;

    if (provider == NULL)
        return [NSColor clearColor];

    appearance = [NSAppearance currentAppearance];
    if (appearance == nil)
        appearance = [NSAppearance appearanceNamed: NSAppearanceNameAqua];

    resolved = provider(appearance);
    return resolved != nil ? resolved : [NSColor clearColor];
}

@end

/*
 * THE ANCHORS A VIEW HANDS OUT, which is how a modern application states its layout.
 *
 * Each is the view paired with one attribute, and the anchor makes constraints from that pair. As
 * with the constraints themselves there is no solver here, so the objects are real and record what
 * was asked for while the actual layout still comes from the autoresizing masks. iA Writer builds
 * its library window this way and raised on -[NSView topAnchor] with everything else in place.
 *
 * leading and trailing are left and right: nothing here lays out right to left.
 */
@interface NSView (NSViewAnchors)
- (NSLayoutXAxisAnchor *) leadingAnchor;
- (NSLayoutXAxisAnchor *) trailingAnchor;
- (NSLayoutXAxisAnchor *) leftAnchor;
- (NSLayoutXAxisAnchor *) rightAnchor;
- (NSLayoutXAxisAnchor *) centerXAnchor;
- (NSLayoutYAxisAnchor *) topAnchor;
- (NSLayoutYAxisAnchor *) bottomAnchor;
- (NSLayoutYAxisAnchor *) centerYAnchor;
- (NSLayoutYAxisAnchor *) firstBaselineAnchor;
- (NSLayoutYAxisAnchor *) lastBaselineAnchor;
- (NSLayoutDimension *) widthAnchor;
- (NSLayoutDimension *) heightAnchor;
@end

@implementation NSView (NSViewAnchors)

- (NSLayoutXAxisAnchor *) leadingAnchor {
    return [NSLayoutXAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeLeading];
}

- (NSLayoutXAxisAnchor *) trailingAnchor {
    return [NSLayoutXAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeTrailing];
}

- (NSLayoutXAxisAnchor *) leftAnchor {
    return [NSLayoutXAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeLeft];
}

- (NSLayoutXAxisAnchor *) rightAnchor {
    return [NSLayoutXAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeRight];
}

- (NSLayoutXAxisAnchor *) centerXAnchor {
    return [NSLayoutXAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeCenterX];
}

- (NSLayoutYAxisAnchor *) topAnchor {
    return [NSLayoutYAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeTop];
}

- (NSLayoutYAxisAnchor *) bottomAnchor {
    return [NSLayoutYAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeBottom];
}

- (NSLayoutYAxisAnchor *) centerYAnchor {
    return [NSLayoutYAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeCenterY];
}

- (NSLayoutYAxisAnchor *) firstBaselineAnchor {
    return [NSLayoutYAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeFirstBaseline];
}

- (NSLayoutYAxisAnchor *) lastBaselineAnchor {
    return [NSLayoutYAxisAnchor anchorWithItem: self attribute: NSLayoutAttributeLastBaseline];
}

- (NSLayoutDimension *) widthAnchor {
    return [NSLayoutDimension anchorWithItem: self attribute: NSLayoutAttributeWidth];
}

- (NSLayoutDimension *) heightAnchor {
    return [NSLayoutDimension anchorWithItem: self attribute: NSLayoutAttributeHeight];
}

@end
