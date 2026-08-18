/*
 * Declarations for the classes a modern application links against. See CiderModernAppKit.m for what
 * each one does and does not do; the short version is that a missing class here is not a missing
 * feature, it is a process that dyld refuses to start.
 */

#import <AppKit/AppKitExport.h>
#import <Foundation/Foundation.h>

@class NSWindow;

APPKIT_EXPORT NSString *const NSAccessibilityCustomTextAttribute;
APPKIT_EXPORT NSString *const NSApplicationDidFinishRestoringWindowsNotification;
APPKIT_EXPORT NSString *const NSSpellCheckerDidChangeAutomaticTextCompletionNotification;
APPKIT_EXPORT NSString *const NSTextContentTypeOneTimeCode;
APPKIT_EXPORT NSString *const NSTouchBarItemIdentifierCandidateList;

APPKIT_EXPORT NSDictionary *_NSDictionaryOfVariableBindings(
        NSString *commaSeparatedKeysString, id firstValue, ...) NS_REQUIRES_NIL_TERMINATION;

#define NSDictionaryOfVariableBindings(...) \
    _NSDictionaryOfVariableBindings(@ "" #__VA_ARGS__, __VA_ARGS__, nil)

@interface NSUserInterfaceCompressionOptions : NSObject <NSCopying>

- (instancetype) initWithIdentifier: (NSString *) identifier;
- (instancetype) initWithIdentifiers: (NSSet<NSString *> *) identifiers;
- (instancetype) initWithCompressionOptions:
        (NSSet<NSUserInterfaceCompressionOptions *> *) options;

- (NSSet<NSString *> *) identifiers;
- (BOOL) containsOptions: (NSUserInterfaceCompressionOptions *) options;
- (BOOL) intersectsOptions: (NSUserInterfaceCompressionOptions *) options;
- (BOOL) isEmpty;
- (NSUserInterfaceCompressionOptions *) optionsByAddingOptions:
        (NSUserInterfaceCompressionOptions *) options;
- (NSUserInterfaceCompressionOptions *) optionsByRemovingOptions:
        (NSUserInterfaceCompressionOptions *) options;

+ (NSUserInterfaceCompressionOptions *) hideImagesOption;
+ (NSUserInterfaceCompressionOptions *) hideTextOption;
+ (NSUserInterfaceCompressionOptions *) reduceMetricsOption;
+ (NSUserInterfaceCompressionOptions *) breakEqualWidthsOption;
+ (NSUserInterfaceCompressionOptions *) standardOptions;

@end

@interface NSWindowTabGroup : NSObject

- (instancetype) _initWithWindow: (NSWindow *) window;

- (NSString *) identifier;
- (NSArray<NSWindow *> *) windows;
- (NSWindow *) selectedWindow;
- (void) setSelectedWindow: (NSWindow *) window;
- (BOOL) isOverviewVisible;
- (void) setOverviewVisible: (BOOL) visible;
- (BOOL) isTabBarVisible;
- (void) addWindow: (NSWindow *) window;
- (void) insertWindow: (NSWindow *) window atIndex: (NSInteger) index;
- (void) removeWindow: (NSWindow *) window;

@end

@interface NSWindow (CiderTabGroup)
- (NSWindowTabGroup *) tabGroup;
@end

@interface NSTextCheckingController : NSObject

- (instancetype) initWithClient: (id) client;

- (id) client;
- (void) invalidate;
- (void) didChangeTextInRange: (NSRange) range;
- (void) insertedTextInRange: (NSRange) range;
- (void) didChangeSelectedRange;
- (void) considerTextCheckingForRange: (NSRange) range;
- (void) checkTextInRange: (NSRange) range
                    types: (NSTextCheckingTypes) checkingTypes
                  options: (NSDictionary *) options;
- (void) checkTextInSelection: (id) sender;
- (void) checkTextInDocument: (id) sender;
- (void) orderFrontSubstitutionsPanel: (id) sender;
- (void) checkSpelling: (id) sender;
- (void) showGuessPanel: (id) sender;
- (void) changeSpelling: (id) sender;
- (void) ignoreSpelling: (id) sender;
- (void) updateCandidates;
- (NSArray *) validAnnotations;

@end
