/* See NSModernAppKitAdditions.m: classes and a constant a current binary links against. */

#import <AppKit/NSView.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSWindow.h>
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

typedef NS_ENUM(NSInteger, NSImageSymbolRenderingMode) {
    NSImageSymbolRenderingModeAutomatic = 0,
    NSImageSymbolRenderingModeMonochrome = 1,
    NSImageSymbolRenderingModeHierarchical = 2,
    NSImageSymbolRenderingModePalette = 3,
    NSImageSymbolRenderingModeMulticolor = 4,
};

@interface NSImageSymbolConfiguration : NSObject
+ (instancetype) configurationWithPointSize: (CGFloat) pointSize
                                     weight: (NSInteger) weight
                                      scale: (NSInteger) scale;
+ (instancetype) configurationWithPointSize: (CGFloat) pointSize weight: (NSInteger) weight;
+ (instancetype) configurationWithScale: (NSInteger) scale;
+ (instancetype) configurationWithTextStyle: (NSString *) style;
+ (instancetype) configurationWithPaletteColors: (NSArray *) paletteColors;
+ (instancetype) configurationWithHierarchicalColor: (NSColor *) hierarchicalColor;
+ (instancetype) configurationPreferringMonochrome;
+ (instancetype) configurationPreferringHierarchical;
+ (instancetype) configurationPreferringMulticolor;
- (NSImageSymbolConfiguration *) configurationByApplyingConfiguration:
        (NSImageSymbolConfiguration *) configuration;
@property (readonly) CGFloat pointSize;
@property (readonly) NSInteger weight;
@property (readonly) NSInteger scale;
@property (readonly, copy) NSArray *paletteColors;
@property (readonly, retain) NSColor *hierarchicalColor;
@property (readonly) NSInteger renderingMode;
@end

@interface NSImage (NSImageSymbolConfiguration)
- (NSImage *) imageWithSymbolConfiguration: (NSImageSymbolConfiguration *) configuration;
+ (NSImage *) imageWithSymbolName: (NSString *) name
                           bundle: (NSBundle *) bundle
                    variableValue: (double) variableValue;
+ (NSImage *) imageWithSystemSymbolName: (NSString *) name
               accessibilityDescription: (NSString *) description;
@end


typedef NS_ENUM(NSInteger, NSTitlebarSeparatorStyle) {
    NSTitlebarSeparatorStyleAutomatic = 0,
    NSTitlebarSeparatorStyleNone = 1,
    NSTitlebarSeparatorStyleLine = 2,
    NSTitlebarSeparatorStyleShadow = 3,
};

@interface NSWindow (NSTitlebarSeparator)
@property NSTitlebarSeparatorStyle titlebarSeparatorStyle;
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
