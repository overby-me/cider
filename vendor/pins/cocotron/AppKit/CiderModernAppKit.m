/*
 * THE CLASSES AND CONSTANTS A MODERN APPLICATION LINKS AGAINST, and nothing more elaborate.
 *
 * A missing Objective-C class is not a missing feature at runtime: it is a process that never
 * starts. dyld binds _OBJC_CLASS_$_ symbols before main, so an application that so much as mentions
 * one of these in a compiled file is refused, whatever it would have done with it. iA Writer is
 * refused by three of them, measured by diffing every undefined symbol in its 27 binaries against
 * everything our runtime exports.
 *
 * What is here is the documented shape of each class, doing the honest thing for a port with no
 * window tabbing and no system text checker: hold what it is given, answer what it can compute, and
 * do nothing where the real class would talk to a service we do not have. Each one says which of
 * the two it is.
 */

#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <AppKit/CiderModernAppKit.h>

/* ---- constants ------------------------------------------------------------------------------ */

/* Names only. A notification nobody posts is still a name an application can subscribe to, and a
 * text attribute nobody sets is still a key it can ask for. */
NSString *const NSAccessibilityCustomTextAttribute = @"AXCustomText";
NSString *const NSApplicationDidFinishRestoringWindowsNotification =
        @"NSApplicationDidFinishRestoringWindowsNotification";
NSString *const NSSpellCheckerDidChangeAutomaticTextCompletionNotification =
        @"NSSpellCheckerDidChangeAutomaticTextCompletionNotification";
NSString *const NSTextContentTypeOneTimeCode = @"NSTextContentTypeOneTimeCode";
NSString *const NSTouchBarItemIdentifierCandidateList =
        @"NSTouchBarItemIdentifierCandidateList";

/* ---- NSDictionaryOfVariableBindings ---------------------------------------------------------- */

/*
 * WHAT THE MACRO CALLS. NSDictionaryOfVariableBindings(a, b) compiles to a call with the variable
 * NAMES as one string and their VALUES as varargs, and the function pairs them up. That is the whole
 * job, so this is a real implementation and not a placeholder: the names are split on commas,
 * trimmed, and any receiver prefix dropped, because the macro passes the expression text verbatim
 * and `self.view` names the key `view`.
 */
NSDictionary *_NSDictionaryOfVariableBindings(NSString *commaSeparatedKeysString, id firstValue, ...)
{
    if (commaSeparatedKeysString == nil)
        return [NSDictionary dictionary];

    NSMutableDictionary *bindings = [NSMutableDictionary dictionary];
    NSArray *names = [commaSeparatedKeysString componentsSeparatedByString: @","];
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    va_list args;
    id value = firstValue;

    va_start(args, firstValue);

    for (NSString *rawName in names) {
        if (value == nil) /* fewer values than names: the caller ended the list early */
            break;

        NSString *name = [rawName stringByTrimmingCharactersInSet: space];
        NSRange dot = [name rangeOfString: @"." options: NSBackwardsSearch];

        if (dot.location != NSNotFound)
            name = [name substringFromIndex: NSMaxRange(dot)];

        if ([name length] > 0)
            [bindings setObject: value forKey: name];

        value = va_arg(args, id);
    }

    va_end(args);

    return bindings;
}

/* ---- NSUserInterfaceCompressionOptions ------------------------------------------------------- */

/*
 * A SET OF IDENTIFIERS, which is what this class actually is. A toolbar or a button asks whether it
 * may drop its image or its text when space runs short, and the options are compared, combined and
 * subtracted as sets. All of that is computable here and none of it needs the system, so this one
 * is implemented rather than stubbed.
 */
@implementation NSUserInterfaceCompressionOptions {
    NSSet<NSString *> *_identifiers;
}

- (instancetype) initWithIdentifier: (NSString *) identifier {
    return [self initWithIdentifiers: identifier != nil
                                              ? [NSSet setWithObject: identifier]
                                              : [NSSet set]];
}

- (instancetype) initWithIdentifiers: (NSSet<NSString *> *) identifiers {
    if ((self = [super init]) != nil)
        _identifiers = [identifiers copy];

    return self;
}

- (instancetype) initWithCompressionOptions: (NSSet<NSUserInterfaceCompressionOptions *> *) options {
    NSMutableSet *union_ = [NSMutableSet set];

    for (NSUserInterfaceCompressionOptions *option in options)
        [union_ unionSet: [option identifiers]];

    return [self initWithIdentifiers: union_];
}

- (instancetype) init {
    return [self initWithIdentifiers: [NSSet set]];
}

- (void) dealloc {
    [_identifiers release];
    [super dealloc];
}

- (NSSet<NSString *> *) identifiers {
    return _identifiers;
}

- (BOOL) containsOptions: (NSUserInterfaceCompressionOptions *) options {
    return [_identifiers isSupersetOfSet: [options identifiers]];
}

- (BOOL) intersectsOptions: (NSUserInterfaceCompressionOptions *) options {
    return [_identifiers intersectsSet: [options identifiers]];
}

- (BOOL) isEmpty {
    return [_identifiers count] == 0;
}

- (NSUserInterfaceCompressionOptions *) optionsByAddingOptions:
        (NSUserInterfaceCompressionOptions *) options
{
    NSMutableSet *result = [[_identifiers mutableCopy] autorelease];

    [result unionSet: [options identifiers]];

    return [[[NSUserInterfaceCompressionOptions alloc] initWithIdentifiers: result] autorelease];
}

- (NSUserInterfaceCompressionOptions *) optionsByRemovingOptions:
        (NSUserInterfaceCompressionOptions *) options
{
    NSMutableSet *result = [[_identifiers mutableCopy] autorelease];

    [result minusSet: [options identifiers]];

    return [[[NSUserInterfaceCompressionOptions alloc] initWithIdentifiers: result] autorelease];
}

- (id) copyWithZone: (NSZone *) zone {
    return [[NSUserInterfaceCompressionOptions alloc] initWithIdentifiers: _identifiers];
}

- (BOOL) isEqual: (id) other {
    if (![other isKindOfClass: [NSUserInterfaceCompressionOptions class]])
        return NO;

    return [_identifiers isEqualToSet: [(NSUserInterfaceCompressionOptions *) other identifiers]];
}

- (NSUInteger) hash {
    return [_identifiers hash];
}

+ (NSUserInterfaceCompressionOptions *) _optionWithIdentifier: (NSString *) identifier {
    return [[[NSUserInterfaceCompressionOptions alloc] initWithIdentifier: identifier] autorelease];
}

+ (NSUserInterfaceCompressionOptions *) hideImagesOption {
    return [self _optionWithIdentifier: @"NSUserInterfaceCompressionOptionsHideImages"];
}

+ (NSUserInterfaceCompressionOptions *) hideTextOption {
    return [self _optionWithIdentifier: @"NSUserInterfaceCompressionOptionsHideText"];
}

+ (NSUserInterfaceCompressionOptions *) reduceMetricsOption {
    return [self _optionWithIdentifier: @"NSUserInterfaceCompressionOptionsReduceMetrics"];
}

+ (NSUserInterfaceCompressionOptions *) breakEqualWidthsOption {
    return [self _optionWithIdentifier: @"NSUserInterfaceCompressionOptionsBreakEqualWidths"];
}

+ (NSUserInterfaceCompressionOptions *) standardOptions {
    return [[[NSUserInterfaceCompressionOptions alloc]
            initWithCompressionOptions: [NSSet setWithObjects: [self hideImagesOption],
                                                              [self hideTextOption],
                                                              [self reduceMetricsOption],
                                                              [self breakEqualWidthsOption], nil]]
            autorelease];
}

@end

/* ---- NSWindowTabGroup ------------------------------------------------------------------------ */

/*
 * WINDOW TABBING, WHICH THIS PORT DOES NOT DO. The group is real enough to answer questions: it
 * knows its window, reports one window in it, and says the tab bar and the overview are not
 * showing, which is the truth. Adding a window to it does nothing, and that is also the truth
 * rather than a pretence, because there is nowhere to put a tab.
 */
@implementation NSWindowTabGroup {
    NSWindow *_window;
}

- (instancetype) _initWithWindow: (NSWindow *) window {
    if ((self = [super init]) != nil)
        _window = window; /* not retained: the window owns its group */

    return self;
}

- (NSString *) identifier {
    return [NSString stringWithFormat: @"cider.tabgroup.%p", _window];
}

- (NSArray<NSWindow *> *) windows {
    return _window != nil ? [NSArray arrayWithObject: _window] : [NSArray array];
}

- (NSWindow *) selectedWindow {
    return _window;
}

- (void) setSelectedWindow: (NSWindow *) window {
    /* One window is always the selected one here, since there is only ever one. */
}

- (BOOL) isOverviewVisible {
    return NO;
}

- (void) setOverviewVisible: (BOOL) visible {
    /* No overview to show. */
}

- (BOOL) isTabBarVisible {
    return NO;
}

- (void) addWindow: (NSWindow *) window {
    /* No tabbing: the window stays where it is, on its own. */
}

- (void) insertWindow: (NSWindow *) window atIndex: (NSInteger) index {
}

- (void) removeWindow: (NSWindow *) window {
}

@end

@implementation NSWindow (CiderTabGroup)

/*
 * Every window answers with a group of its own, made once and kept, because an application that
 * asks twice expects the same object back.
 */
- (NSWindowTabGroup *) tabGroup {
    static const void *key = &key;
    NSWindowTabGroup *group = objc_getAssociatedObject(self, key);

    if (group == nil) {
        group = [[[NSWindowTabGroup alloc] _initWithWindow: self] autorelease];
        objc_setAssociatedObject(self, key, group, OBJC_ASSOCIATION_RETAIN);
    }

    return group;
}

@end

/* ---- NSTextCheckingController ----------------------------------------------------------------- */

/*
 * SPELLING AND GRAMMAR FOR A CUSTOM TEXT VIEW, which needs a checker this port does not have. It
 * holds its client and accepts every call without doing anything, so a view that installs one lays
 * out and draws exactly as it would with checking turned off.
 */
@implementation NSTextCheckingController {
    id _client;
}

- (instancetype) initWithClient: (id) client {
    if ((self = [super init]) != nil)
        _client = client; /* not retained: the client owns the controller */

    return self;
}

- (id) client {
    return _client;
}

- (void) invalidate {
}

- (void) didChangeTextInRange: (NSRange) range {
}

- (void) insertedTextInRange: (NSRange) range {
}

- (void) didChangeSelectedRange {
}

- (void) considerTextCheckingForRange: (NSRange) range {
}

- (void) checkTextInRange: (NSRange) range types: (NSTextCheckingTypes) checkingTypes options: (NSDictionary *) options {
}

- (void) checkTextInSelection: (id) sender {
}

- (void) checkTextInDocument: (id) sender {
}

- (void) orderFrontSubstitutionsPanel: (id) sender {
}

- (void) checkSpelling: (id) sender {
}

- (void) showGuessPanel: (id) sender {
}

- (void) changeSpelling: (id) sender {
}

- (void) ignoreSpelling: (id) sender {
}

- (void) updateCandidates {
}

- (NSArray *) validAnnotations {
    return [NSArray array];
}

@end
