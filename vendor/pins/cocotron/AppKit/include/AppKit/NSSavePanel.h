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

#import <AppKit/NSNibLoading.h>
#import <AppKit/NSPanel.h>
#import <Foundation/NSURL.h>

@class NSView, NSOutlineView;

enum {
    NSFileHandlingPanelCancelButton = NSCancelButton,
    NSFileHandlingPanelOKButton = NSOKButton,
};

@class NSTextField;

@interface NSSavePanel : NSPanel {
    NSString *_dialogTitle;

    NSString *_nameFieldStringValue;
    NSString *_filename;
    NSString *_directory;
    NSString *_requiredFileType;
    NSArray *_allowedFileTypes;
    NSString *_message;
    NSString *_prompt;

    BOOL _showsHiddenFiles;

    /* Whether the panel offers the "Hide extension" checkbox. Stored rather than ignored because
     * the caller that sets it also reads it back. */
    BOOL _canSelectHiddenExtension;

    BOOL _treatsFilePackagesAsDirectories;
    NSView *_accessoryView;

    IBOutlet NSOutlineView *_outlineView;

    /* The editable filename field. The nib has no such view, so a save panel could not be given a
     * name by TYPING one; this is built when the panel is about to run. Never built for an open
     * panel, which has no name field on any platform. */
    NSTextField *_nameField;

    /* Whether the panel has already been laid out. The layout adds views, so running it twice would
     * put two hairlines and two name fields in the panel. */
    BOOL _laidOut;
}

@property (copy) NSString *nameFieldStringValue;
@property BOOL showsHiddenFiles;

+ (NSSavePanel *) savePanel;

- (NSURL *) URL;
- (NSString *) filename;

- (void) beginWithCompletionHandler: (void (^)(NSModalResponse result)) handler;

- (NSInteger) runModalForDirectory: (NSString *) directory
                              file: (NSString *) file;
- (NSInteger) runModal;

- (NSString *) directory;
- (BOOL) treatsFilePackagesAsDirectories;
- (NSView *) accessoryView;

- (void) setTitle: (NSString *) title;

- (void) setDirectory: (NSString *) directory;

- (void) setRequiredFileType: (NSString *) type;
- (void) setTreatsFilePackagesAsDirectories: (BOOL) flag;

- (void) setDirectoryURL: (NSURL *) url;
- (NSURL *) directoryURL;

- (NSArray *) allowedFileTypes;

- (void) setAccessoryView: (NSView *) view;
- (void) setCanCreateDirectories: (BOOL) value;

/* THE THREE AN APPLICATION SENDS TO A SAVE PANEL THAT WERE NOT HERE. Sending any of them to a panel
 * that does not answer raises, and an application that configures its panel before showing it dies
 * before the panel appears. See the implementation. */
- (void) setCanSelectHiddenExtension: (BOOL) value;
/* Lays the panel out the way macOS does: buttons bottom right, the accessory view above them, then
 * the name row, then the file list. Builds the name field and adds the accessory view, both of
 * which the nib lacks. Called once, before the panel runs. */
- (void) _ensurePanelLayout;
/* NO for an open panel, which has no name field on any platform. */
- (BOOL) _wantsNameField;
/* Expands the list down to the directory the panel is set to and scrolls it into view, so the panel
 * shows where it is actually saving rather than the root of the file system. */
- (void) _revealDirectory;
- (BOOL) canSelectHiddenExtension;
- (void) validateVisibleColumns;
- (IBAction) cancel: (id) sender;
- (void) setAllowedFileTypes: (NSArray *) value;
- (void) setAllowsOtherFileTypes: (BOOL) value;

- (void) setMessage: (NSString *) message;
- (NSString *) message;

- (void) setPrompt: (NSString *) message;
- (NSString *) prompt;

- (void) beginSheetForDirectory: (NSString *) path
                           file: (NSString *) name
                 modalForWindow: (NSWindow *) docWindow
                  modalDelegate: (id) modalDelegate
                 didEndSelector: (SEL) didEndSelector
                    contextInfo: (void *) contextInfo;

- (IBAction) _selectFile: (id) sender;
- (IBAction) _cancel: (id) sender;
@end

@protocol NSOpenSavePanelDelegate <NSObject>

// TODO

@end
