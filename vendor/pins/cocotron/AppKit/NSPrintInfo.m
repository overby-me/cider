/* Copyright (c) 2006-2007 Christopher J. W. Lloyd <cjwl@objc.net>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

#import <AppKit/NSPrintInfo.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>
#import <Foundation/NSThread.h>
#import <Foundation/NSValue.h>

NSPrintInfoAttributeKey const NSPrintPaperName = @"NSPaperName";
NSPrintInfoAttributeKey const NSPrintPaperSize = @"NSPaperSize";
NSPrintInfoAttributeKey const NSPrintOrientation = @"NSOrientation";
NSPrintInfoAttributeKey const NSPrintScalingFactor = @"NSScalingFactor";

NSPrintInfoAttributeKey const NSPrintLeftMargin = @"NSLeftMargin";
NSPrintInfoAttributeKey const NSPrintRightMargin = @"NSRightMargin";
NSPrintInfoAttributeKey const NSPrintTopMargin = @"NSTopMargin";
NSPrintInfoAttributeKey const NSPrintBottomMargin = @"NSBottomMargin";
NSPrintInfoAttributeKey const NSPrintHorizontallyCentered = @"NSHorizontallyCentered";
NSPrintInfoAttributeKey const NSPrintVerticallyCentered = @"NSVerticallyCentered";
NSPrintInfoAttributeKey const NSPrintHorizontalPagination = @"NSHorizonalPagination";
NSPrintInfoAttributeKey const NSPrintVerticalPagination = @"NSVerticalPagination";

NSPrintInfoAttributeKey const NSPrintAllPages = @"NSPrintAllPages";
NSPrintInfoAttributeKey const NSPrintCopies = @"NSCopies";
NSPrintInfoAttributeKey const NSPrintDetailedErrorReporting = @"NSDetailedErrorReporting";
NSPrintInfoAttributeKey const NSPrintFirstPage = @"NSFirstPage";
NSPrintInfoAttributeKey const NSPrintHeaderAndFooter = @"NSPrintHeaderAndFooter";
NSPrintInfoAttributeKey const NSPrintJobDisposition = @"NSJobDisposition";
/* THE REST OF THE PRINT DICTIONARY KEYS, which are strings and nothing else: an application that
 * fills in a print info by key needs them to LINK, whether or not anything here reads them back. */
NSPrintInfoAttributeKey const NSPrintTime = @"NSPrintTime";
NSPrintInfoAttributeKey const NSPrintFaxNumber = @"NSPrintFaxNumber";
NSPrintInfoAttributeKey const NSPrintPagesAcross = @"NSPagesAcross";
NSPrintInfoAttributeKey const NSPrintPagesDown = @"NSPagesDown";
NSPrintInfoAttributeKey const NSPrintReversePageOrder = @"NSPrintReversePageOrder";
NSPrintInfoAttributeKey const NSPrintJobSavingFileNameExtensionHidden = @"NSJobSavingFileNameExtensionHidden";
NSPrintInfoAttributeKey const NSPrintJobSavingURL = @"NSJobSavingURL";
NSPrintInfoAttributeKey const NSPrintLastPage = @"NSLastPage";
NSPrintInfoAttributeKey const NSPrintMustCollate = @"NSMustCollate";
NSPrintInfoAttributeKey const NSPrintPrinter = @"NSPrinter";
NSPrintInfoAttributeKey const NSPrintPrinterName = @"NSPrinterName";
NSPrintInfoAttributeKey const NSPrintSelectionOnly = @"NSPrintSelectionOnly";

NSPrintJobDispositionValue const NSPrintSpoolJob = @"NSPrintSpoolJob";
NSPrintJobDispositionValue const NSPrintPreviewJob = @"NSPrintPreviewJob";
NSPrintJobDispositionValue const NSPrintSaveJob = @"NSPrintSaveJob";
NSPrintJobDispositionValue const NSPrintCancelJob = @"NSPrintCancelJob";

NSString *const NSPrintSavePath = @"NSPrintSavePath";

@implementation NSPrintInfo

/*
 * THE DEFAULT PRINTER, which is nil here and has to be SAYABLE.
 *
 * There are no printers in this container, and this class method did not exist at all, so an
 * application asking the obvious question got an unrecognized selector instead of an answer.
 * LibreOffice asks it immediately after its no-default-printer dialog is dismissed, so the dialog
 * telling the user there is no printer could only be closed by killing the process.
 *
 * nil is the honest answer and the documented one for a machine with no printers.
 */
+ (NSPrinter *) defaultPrinter {
    return nil;
}

+ (NSPrintInfo *) sharedPrintInfo {
    return NSThreadSharedInstance(@"NSPrintInfo");
}

- initWithDictionary: (NSDictionary *) dictionary {
    _attributes = [[NSMutableDictionary alloc] initWithDictionary: dictionary];
    return self;
}

- init {
    NSDictionary *defaults = [NSDictionary
            dictionaryWithObjectsAndKeys:
                    [NSNumber numberWithInt: 1], NSPrintCopies,
                    [NSNumber numberWithBool: YES], NSPrintAllPages,
                    @"US Letter", NSPrintPaperName,
                    [NSValue valueWithSize: NSMakeSize(612, 792)],
                    NSPrintPaperSize, [NSNumber numberWithFloat: 36],
                    NSPrintTopMargin, [NSNumber numberWithFloat: 36],
                    NSPrintLeftMargin, [NSNumber numberWithFloat: 36],
                    NSPrintRightMargin, [NSNumber numberWithFloat: 36],
                    NSPrintBottomMargin,
                    [NSNumber numberWithInt: NSPortraitOrientation],
                    NSPrintOrientation, nil];

    return [self initWithDictionary: defaults];
}

- (void) dealloc {
    [_attributes release];
    [super dealloc];
}

- copyWithZone: (NSZone *) zone {
    NSPrintInfo *copy = NSCopyObject(self, 0, zone);

    copy->_attributes = [_attributes mutableCopy];

    return copy;
}

- (NSMutableDictionary *) dictionary {
    return _attributes;
}

- (NSPrinter *) printer {
    return [_attributes objectForKey: NSPrintPrinter];
}

- (NSString *) jobDisposition {
    return [_attributes objectForKey: NSPrintJobDisposition];
}

- (NSString *) paperName {
    return [_attributes objectForKey: NSPrintPaperName];
}

- (NSSize) paperSize {
    return [[_attributes objectForKey: NSPrintPaperSize] sizeValue];
}

- (NSPrintingOrientation) orientation {
    return [[_attributes objectForKey: NSPrintOrientation] intValue];
}

- (NSPrintingPaginationMode) horizontalPagination {
    return [[_attributes objectForKey: NSPrintHorizontalPagination] intValue];
}

- (NSPrintingPaginationMode) verticalPagination {
    return [[_attributes objectForKey: NSPrintVerticalPagination] intValue];
}

- (CGFloat) topMargin {
    return [[_attributes objectForKey: NSPrintTopMargin] floatValue];
}

- (CGFloat) bottomMargin {
    return [[_attributes objectForKey: NSPrintBottomMargin] floatValue];
}

- (CGFloat) leftMargin {
    return [[_attributes objectForKey: NSPrintLeftMargin] floatValue];
}

- (CGFloat) rightMargin {
    return [[_attributes objectForKey: NSPrintRightMargin] floatValue];
}

- (BOOL) isHorizontallyCentered {
    return [[_attributes objectForKey: NSPrintHorizontallyCentered] boolValue];
}

- (BOOL) isVerticallyCentered {
    return [[_attributes objectForKey: NSPrintVerticallyCentered] boolValue];
}

- (NSString *) localizedPaperName {
    return [self paperName];
}

- (NSRect) imageablePageBounds {
    NSRect result;
    NSValue *imageable = [_attributes objectForKey: @"_imageableRect"];

    if (imageable != nil)
        result = [imageable rectValue];
    else {
        result.origin.x = 0;
        result.origin.y = 0;
        result.size = [self paperSize];
    }

    if ([self orientation] == NSLandscapeOrientation) {
        NSRect portrait = result;

        result.origin.x = portrait.origin.y;
        result.size.width = portrait.size.height;
        result.origin.y = portrait.origin.x;
        result.size.height = portrait.size.width;
    }

    return result;
}

/*
 * NIL REMOVES THE KEY, it does not raise.
 *
 * A dictionary refuses a nil value, and these setters handed one straight through, so
 * [info setPrinter: [NSPrintInfo defaultPrinter]] on a machine with NO printers threw
 * "Cannot set nil objects nor nil keys" and killed the application. That is exactly what LibreOffice
 * does when its print dialog opens, and nil is a perfectly ordinary answer here: there is no
 * printer. An attribute that is absent reads back as nil, which is the same thing the caller meant.
 */
- (void) setPrinter: (NSPrinter *) printer {
    if (printer == nil) {
        [_attributes removeObjectForKey: NSPrintPrinter];
    } else {
        [_attributes setObject: printer forKey: NSPrintPrinter];
    }
}

- (void) setJobDisposition: (NSString *) value {
    if (value == nil) {
        [_attributes removeObjectForKey: NSPrintJobDisposition];
    } else {
        [_attributes setObject: value forKey: NSPrintJobDisposition];
    }
}

- (void) setPaperName: (NSString *) value {
    if (value == nil) {
        [_attributes removeObjectForKey: NSPrintPaperName];
    } else {
        [_attributes setObject: value forKey: NSPrintPaperName];
    }
}

- (void) setPaperSize: (NSSize) value {
    [_attributes setObject: [NSValue valueWithSize: value]
                    forKey: NSPrintPaperSize];
}

- (void) setOrientation: (NSPrintingOrientation) value {
    [_attributes setObject: [NSNumber numberWithInt: value]
                    forKey: NSPrintOrientation];
}

- (void) setHorizontalPagination: (NSPrintingPaginationMode) value {
    [_attributes setObject: [NSNumber numberWithInt: value]
                    forKey: NSPrintHorizontalPagination];
}

- (void) setVerticalPagination: (NSPrintingPaginationMode) value {
    [_attributes setObject: [NSNumber numberWithInt: value]
                    forKey: NSPrintVerticalPagination];
}

- (void) setTopMargin: (CGFloat) value {
    [_attributes setObject: [NSNumber numberWithFloat: value]
                    forKey: NSPrintTopMargin];
}

- (void) setBottomMargin: (CGFloat) value {
    [_attributes setObject: [NSNumber numberWithFloat: value]
                    forKey: NSPrintBottomMargin];
}

- (void) setLeftMargin: (CGFloat) value {
    [_attributes setObject: [NSNumber numberWithFloat: value]
                    forKey: NSPrintLeftMargin];
}

- (void) setRightMargin: (CGFloat) value {
    [_attributes setObject: [NSNumber numberWithFloat: value]
                    forKey: NSPrintRightMargin];
}

- (void) setHorizontallyCentered: (BOOL) value {
    [_attributes setObject: [NSNumber numberWithBool: value]
                    forKey: NSPrintHorizontallyCentered];
}

- (void) setVerticallyCentered: (BOOL) value {
    [_attributes setObject: [NSNumber numberWithBool: value]
                    forKey: NSPrintVerticallyCentered];
}

- (void) setUpPrintOperationDefaultValues {
    // do nothing ?
}

@end
