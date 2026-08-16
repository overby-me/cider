/* See NSModernAppKitAdditions.m: classes and a constant a current binary links against. */

#import <AppKit/NSView.h>
#import <AppKit/NSToolbarItem.h>
#import <Foundation/Foundation.h>

@class NSSearchField, NSColor;

APPKIT_EXPORT NSString *const NSTextMovementUserInfoKey;

@interface NSFilePromiseReceiver : NSObject
+ (NSArray *) readableDraggedTypes;
- (NSArray<NSString *> *) fileTypes;
- (NSArray<NSString *> *) fileNames;
- (void) receivePromisedFilesAtDestination: (NSURL *) destinationDir
                                   options: (NSDictionary *) options
                            operationQueue: (NSOperationQueue *) operationQueue
                                    reader: (void (^)(NSURL *, NSError *)) reader;
@end

@interface NSGlassEffectView : NSView
@property (retain) NSView *contentView;
@property (retain) NSColor *tintColor;
@property CGFloat cornerRadius;
@end

@interface NSImageSymbolConfiguration : NSObject
+ (instancetype) configurationWithPointSize: (CGFloat) pointSize
                                     weight: (NSInteger) weight
                                      scale: (NSInteger) scale;
+ (instancetype) configurationWithPointSize: (CGFloat) pointSize weight: (NSInteger) weight;
+ (instancetype) configurationWithScale: (NSInteger) scale;
+ (instancetype) configurationWithTextStyle: (NSString *) style;
@property (readonly) CGFloat pointSize;
@property (readonly) NSInteger weight;
@property (readonly) NSInteger scale;
@end

@interface NSSearchToolbarItem : NSToolbarItem
@property (retain) NSSearchField *searchField;
@property CGFloat preferredWidthForSearchField;
@property BOOL resignsFirstResponderWithCancel;
- (void) beginSearchInteraction;
- (void) endSearchInteraction;
@end

@interface NSTouch : NSObject
@property (readonly) id identity;
@property (readonly) NSInteger phase;
@property (readonly) NSPoint normalizedPosition;
@property (readonly, getter=isResting) BOOL resting;
@property (readonly) id device;
@property (readonly) NSSize deviceSize;
@end
