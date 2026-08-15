#import <AppKit/AppKitExport.h>
#import <Foundation/NSObject.h>

@class NSMutableDictionary, NSMutableArray, NSArray, NSViewController;

enum {

    NSPrintPanelShowsCopies = 1 << 0,
    NSPrintPanelShowsPageRange = 1 << 1,
    NSPrintPanelShowsPaperSize = 1 << 2,
    NSPrintPanelShowsOrientation = 1 << 3,
    NSPrintPanelShowsScaling = 1 << 4,
    NSPrintPanelShowsPrintSelection = 1 << 5,
    NSPrintPanelShowsPageSetupAccessory = 1 << 8,
    NSPrintPanelShowsPreview = 1 << 17
};

typedef NSInteger NSPrintPanelOptions;

@interface NSPrintPanel : NSObject {
    NSMutableDictionary *_attributes;
    NSInteger _options;
    /* The accessory controllers an application has added. See -addAccessoryController:. */
    NSMutableArray *_accessoryControllers;
}

+ (NSPrintPanel *) printPanel;

- (void) setOptions: (NSPrintPanelOptions) options;
- (NSPrintPanelOptions) options;

/*
 * THE ACCESSORY CONTROLLERS AN APPLICATION ADDS TO THE PRINT PANEL.
 *
 * This is how a Cocoa application puts its own options into the system print dialog, and
 * LibreOffice does exactly that: +[AquaPrintAccessoryView setupPrinterPanel:...] builds a
 * controller and adds it. The selector was missing entirely, so the print path did not fail, it
 * TERMINATED: doesNotRecognizeSelector raises, nothing in that call chain catches it, and the whole
 * application went down on Command and P with unsaved work in it.
 *
 * They are stored and handed back. The panel here does not yet DISPLAY them, which is a gap and is
 * said plainly rather than papered over, but storing them is the honest half of the contract and it
 * is the half that decides whether the application survives.
 */
- (void) addAccessoryController: (NSViewController *) controller;
- (void) removeAccessoryController: (NSViewController *) controller;
- (NSArray *) accessoryControllers;

- (int) runModal;

- (void) updateFromPrintInfo;
- (void) finalWritePrintInfo;

@end

@protocol NSPrintPanelAccessorizing

// TODO

@end

APPKIT_EXPORT NSString *const NSPrintPanelAccessorySummaryItemNameKey;
APPKIT_EXPORT NSString *const NSPrintPanelAccessorySummaryItemDescriptionKey;
