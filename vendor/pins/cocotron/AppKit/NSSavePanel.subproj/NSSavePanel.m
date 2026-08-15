/* Copyright (c) 2006-2007 Christopher J. W. Lloyd <cjwl@objc.net>, 2008
Johannes Fortmann

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

#include <stdlib.h>

#import <AppKit/NSApplication.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSSavePanel.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSView.h>

@implementation NSSavePanel

@synthesize showsHiddenFiles=_showsHiddenFiles;

- (id) resetToDefaultValues {
    _dialogTitle = @"Save";
    _nameFieldStringValue = @"";
    _filename = @"";
    _directory = [NSHomeDirectory() copy];
    _requiredFileType = @"";
    _treatsFilePackagesAsDirectories = NO;
    _accessoryView = nil;
    _showsHiddenFiles = false;
    return self;
}

static NSSavePanel *_newPanel = nil;

+ (void) set_newPanel: (NSSavePanel *) newPanel {
    _newPanel = newPanel;
}

+ (NSSavePanel *) savePanel {
    if ([[NSDisplay currentDisplay] implementsCustomPanelForClass: self]) {
        _newPanel = [[self alloc]
                initWithContentRect: NSMakeRect(0, 0, 1, 1)
                          styleMask: NSTitledWindowMask | NSResizableWindowMask
                            backing: NSBackingStoreBuffered
                              defer: YES];
    } else {
        [NSBundle loadNibNamed: @"NSSavePanel" owner: self];
    }
    // FIXME: release it?
    return [_newPanel resetToDefaultValues];
}

- init {
    [self release];
    return [[NSSavePanel savePanel] retain];
}

- (void) dealloc {
    [_dialogTitle release];
    [_nameFieldStringValue release];
    [_filename release];
    [_directory release];
    [_requiredFileType release];
    [_accessoryView release];
    [_nameField release];
    [super dealloc];
}

- (void) _setFilename: (NSString *) filename {
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL setFilename=%@", filename);
    }
    @synchronized(self) {
        if (filename != _filename) {
            [_filename release];
            _filename = [filename copy];
            if (_filename == nil) {
                _filename = @"";
            }
        }
    }
}

- (NSURL *) URL {
    return [NSURL fileURLWithPath: [self filename]];
}

- (NSString *) filename {
    id ret = nil;
    @synchronized(self) {
        ret = [[_filename copy] autorelease];
    }
    return ret;
}

/*
 * WHAT IS IN THE FIELD, not what was put there.
 *
 * An application sets this before showing the panel and READS IT BACK afterwards to learn what the
 * user chose; LibreOffice names its PDF export that way and never asks the panel for a filename at
 * all. Returning the stored property would mean the user could type whatever they liked and always
 * get the name the application suggested, which is what happened.
 */
- (NSString *) nameFieldStringValue {
    NSString *name = nil;

    if (_nameField != nil) {
        NSString *typed = [_nameField stringValue];

        if ([typed length] > 0) {
            name = typed;
        }
    }
    if (name == nil) {
        name = _nameFieldStringValue;
    }
    return [[[self _nameWithRequiredExtension: name] copy] autorelease];
}

/*
 * THE EXTENSION THE PANEL WAS TOLD TO REQUIRE, applied to a name that has none.
 *
 * A save panel on Apple systems appends the extension for the type being written, and an
 * application relies on that: LibreOffice hands the panel its allowed types and then uses the name
 * verbatim, so a PDF export typed as myfile landed on disk as myfile with no extension at all,
 * which no file manager and no other application will recognise.
 *
 * A name that ALREADY has an extension is left alone, including one the panel would not have
 * chosen: the user typed it on purpose, and second-guessing that is how a save dialog ends up
 * writing report.pdf.pdf.
 */
- (NSString *) _nameWithRequiredExtension: (NSString *) name {
    if ([name length] == 0) {
        return name;
    }
    if ([[name pathExtension] length] > 0) {
        return name;
    }

    NSString *wanted = nil;

    if ([_requiredFileType length] > 0) {
        wanted = _requiredFileType;
    } else if ([_allowedFileTypes count] > 0) {
        wanted = [_allowedFileTypes objectAtIndex: 0];
    }
    if ([wanted length] == 0) {
        return name;
    }
    /* An allowed type can be a UTI rather than an extension on Apple systems. One that looks like a
     * reverse domain name is not an extension and appending it would produce nonsense. */
    if ([wanted rangeOfString: @"."].location != NSNotFound) {
        return name;
    }
    return [name stringByAppendingPathExtension: wanted];
}

- (void) setNameFieldStringValue: (NSString *) value {
    [_nameFieldStringValue release];
    _nameFieldStringValue = [value copy];

    if (_nameFieldStringValue == nil) {
        _nameFieldStringValue = @"";
    }

    [_nameField setStringValue: _nameFieldStringValue];
}

/*
 * WHAT A SAVE PANEL RETURNS, and why saving a document did nothing at all.
 *
 * This took the filename from the SELECTED ROW. That is right for an open panel and cannot be right
 * for a save panel: the file being saved does not exist yet, so there is no row to select, and with
 * no selection -itemAtRow: is handed -1, answers nil, and the panel returned NSOKButton with an
 * empty filename. LibreOffice asked for a save location, got "", and quietly did nothing -- the
 * panel closed, the document stayed unsaved, and no error was raised anywhere.
 *
 * THE NAME COMES FROM THE NAME FIELD, which is what an application sets before it shows the panel
 * (-setNameFieldStringValue:, already stored here) and what a name field would write into. It is
 * joined to the directory the panel is showing, or to a selected DIRECTORY row when there is one,
 * which is how a save panel picks a destination.
 *
 * With no name set, the old behaviour stands, so an open panel and a save panel used as a picker
 * both still answer with the row. NSOpenPanel overrides this anyway, deliberately: nothing about
 * opening should change because saving was fixed.
 */
/*
 * THE FIELD YOU TYPE THE FILENAME INTO, which this panel did not have at all.
 *
 * The nib content view holds a scroll view and two buttons and nothing else, so the only name a
 * save panel could ever return was the one the application set on it. Saving worked, but Save As
 * did not: there was nowhere to type.
 *
 * BUILT HERE RATHER THAN IN THE NIB on purpose. The nib is a binary in the pin, so a patch cannot
 * touch it in a way anyone could review, and a panel that builds its own field also works for any
 * caller that never loaded the nib. The list gives up the height the field takes, so nothing
 * overlaps at any window size.
 *
 * NOT FOR AN OPEN PANEL: NSOpenPanel has its own -runModal and never calls this, which is the same
 * reason its OK action is its own.
 */
- (void) _ensureNameField {
    if (_nameField != nil) {
        return;
    }

    NSView *content = [self contentView];

    if (content == nil) {
        return;
    }

    NSRect bounds = [content bounds];
    NSArray *subviews = [content subviews];
    NSScrollView *list = nil;
    NSInteger i, count = [subviews count];

    for (i = 0; i < count; i++) {
        NSView *view = [subviews objectAtIndex: i];

        if ([view isKindOfClass: [NSScrollView class]]) {
            list = (NSScrollView *) view;
        }
    }

    CGFloat fieldBottom = 56.0;
    CGFloat fieldHeight = 24.0;
    CGFloat labelWidth = 72.0;
    CGFloat margin = 18.0;
    CGFloat fieldLeft = margin + labelWidth + 6.0;

    NSTextField *label = [[[NSTextField alloc]
            initWithFrame: NSMakeRect(margin, fieldBottom, labelWidth, fieldHeight)] autorelease];

    [label setStringValue: @"Save As:"];
    [label setEditable: NO];
    [label setSelectable: NO];
    [label setBordered: NO];
    [label setDrawsBackground: NO];
    [label setAutoresizingMask: NSViewMaxYMargin];
    [content addSubview: label];

    _nameField = [[NSTextField alloc]
            initWithFrame: NSMakeRect(fieldLeft, fieldBottom,
                                      bounds.size.width - fieldLeft - margin, fieldHeight)];
    [_nameField setEditable: YES];
    [_nameField setStringValue: (_nameFieldStringValue != nil) ? _nameFieldStringValue : @""];
    [_nameField setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
    [content addSubview: _nameField];

    /* The list keeps its top edge and gives up the bottom, so the field never lands on top of it. */
    if (list != nil) {
        NSRect frame = [list frame];
        CGFloat top = NSMaxY(frame);
        CGFloat wanted = fieldBottom + fieldHeight + 12.0;

        if (top > wanted) {
            frame.origin.y = wanted;
            frame.size.height = top - wanted;
            [list setFrame: frame];
        }
    }
}

- (IBAction) _selectFile: (id) sender {
    NSURL *url = [_outlineView itemAtRow: [_outlineView selectedRow]];
    NSString *path = [url path];
    /* -nameFieldStringValue is what the field holds, with the required extension applied. Reading
     * the field directly here instead would take the raw text and throw that away, which is how an
     * export typed as cider-noext landed on disk with no extension while the panel had been told
     * the allowed type was pdf. */
    NSString *name = [self nameFieldStringValue];

    if ([name length] > 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDirectory = NO;
        NSString *directory = path;

        if (directory == nil ||
            ![fm fileExistsAtPath: directory isDirectory: &isDirectory] || !isDirectory) {
            directory = [self directory];
        }
        if ([directory length] == 0) {
            directory = NSHomeDirectory();
        }
        path = [directory stringByAppendingPathComponent: name];
    }

    [self _setFilename: path];

    /* WHAT THE PANEL ANSWERED, which is otherwise unobservable: a save that produces no file looks
     * exactly the same whether the panel returned the wrong path, an empty one, or the right one
     * and the application declined to write it. Set CIDER_TRACE_PANEL to tell those apart. */
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL ok filename=%@ nameField=%@ property=%@ directory=%@", path,
              (_nameField != nil) ? [_nameField stringValue] : @"(none)", _nameFieldStringValue,
              _directory);
    }

    [NSApp stopModalWithCode: NSOKButton];
}

- (IBAction) _cancel: (id) sender {
    [NSApp stopModalWithCode: NSCancelButton];
}

- (void) beginWithCompletionHandler: (void (^)(NSModalResponse result)) handler {
    NSUnimplementedMethod();
}

- (NSInteger) runModalForDirectory: (NSString *) directory
                              file: (NSString *) file
{
    [self _setFilename: file];
    [self setDirectory: directory];

    return [self runModal];
}

- (NSInteger) runModal {
    NSInteger res;
    if ([[NSDisplay currentDisplay]
                implementsCustomPanelForClass: [self class]]) {
        res = [[NSDisplay currentDisplay] savePanel: self
                               runModalForDirectory: [self directory]
                                               file: [self filename]];
    } else {
        /* A WINDOW WITH NO TITLE is a blank entry in every window list and task switcher on the
         * desktop, and this panel had none: the compositor reported it as the empty string. The
         * dialog title is what it is called on screen anyway. */
        if ([[self title] length] == 0 && [_dialogTitle length] > 0) {
            [self setTitle: _dialogTitle];
        }
        [self _ensureNameField];
        if (_nameField != nil) {
            [self makeFirstResponder: _nameField];
        }
        res = [NSApp runModalForWindow: self];
        [self close];
    }
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL runModal returned=%ld filename=%@ required=%@ allowed=%@", (long) res,
              [self filename], _requiredFileType, _allowedFileTypes);
    }
    return res;
}

- (NSString *) directory {
    return _directory;
}

- (BOOL) treatsFilePackagesAsDirectories {
    return _treatsFilePackagesAsDirectories;
}

- (NSView *) accessoryView {
    return _accessoryView;
}

- (void) setTitle: (NSString *) title {
    title = [title copy];
    [_dialogTitle release];
    _dialogTitle = title;
}

- (void) setDirectory: (NSString *) directory {
    directory = [directory copy];
    [_directory release];
    _directory = directory;
}

- (void) setDirectoryURL: (NSURL *) url {
    [self setDirectory: [url path]];
}

- (NSURL *) directoryURL {
    return [NSURL fileURLWithPath: [self directory]];
}

- (void) setRequiredFileType: (NSString *) type {
    @synchronized(self) {
        type = [type copy];
        [_requiredFileType release];
        _requiredFileType = type;
    }
}

- (NSString *) requiredFileType {
    id ret = nil;
    @synchronized(self) {
        ret = [[_requiredFileType copy] autorelease];
    }
    return ret;
}

- (void) setMessage: (NSString *) message; {
    @synchronized(self) {
        if (_message != message) {
            [_message release];
            _message = [message copy];
        }
    }
}

- (NSString *) message; {
    id ret = nil;
    @synchronized(self) {
        ret = [[_message copy] autorelease];
    }
    return ret;
}

- (void) setPrompt: (NSString *) prompt; {
    @synchronized(self) {
        if (_prompt != prompt) {
            [_prompt release];
            _prompt = [prompt copy];
        }
    }
}

- (NSString *) prompt; {
    id ret = nil;
    @synchronized(self) {
        ret = [[_prompt copy] autorelease];
    }
    return ret;
}

- (void) setTreatsFilePackagesAsDirectories: (BOOL) flag {
    _treatsFilePackagesAsDirectories = flag;
}

- (void) setAccessoryView: (NSView *) view {
    view = [view retain];
    [_accessoryView release];
    _accessoryView = view;
}

- (void) setCanCreateDirectories: (BOOL) value {
    NSUnimplementedMethod();
}

/*
 * THE THREE A SAVE PANEL HAS TO ANSWER, and the first one is why Command S killed LibreOffice.
 *
 * An application configures the panel before it shows it, so an unrecognized selector here is fatal
 * BEFORE anything is drawn: the whole dialog was built -- outline view, scrollers, table corner --
 * and then -setCanSelectHiddenExtension: raised and the process reported Unspecified Application
 * Error. Saving a document was impossible and nothing said which selector it was until the
 * exception was caught.
 *
 * The flag is STORED rather than dropped: it decides whether the panel offers the "Hide extension"
 * checkbox, and a caller that sets it reads it back to lay out its accessory view.
 *
 * -validateVisibleColumns asks a panel to re-read what it is showing, which is a refresh HINT and
 * not a command; this panel builds its list when it opens and has no browser columns to re-read, so
 * doing nothing is the correct answer rather than a stub for one.
 *
 * -cancel: is the standard action name for the dismiss button and is what an application sends to
 * close a panel it opened itself. The panel already has -_cancel: for its own button, so this is
 * the public name for the same thing rather than a second implementation of it.
 */
- (void) setCanSelectHiddenExtension: (BOOL) value {
    _canSelectHiddenExtension = value;
}

- (BOOL) canSelectHiddenExtension {
    return _canSelectHiddenExtension;
}

- (void) validateVisibleColumns {
}

- (IBAction) cancel: (id) sender {
    [self _cancel: sender];
}

- (void) setAllowedFileTypes: (NSArray *) value {
    [_allowedFileTypes release];
    _allowedFileTypes = [value copy];
}

- (NSArray *) allowedFileTypes {
    return [[_allowedFileTypes copy] autorelease];
}

- (void) setAllowsOtherFileTypes: (BOOL) value {
    NSUnimplementedMethod();
}

- (void) beginSheetForDirectory: (NSString *) path
                           file: (NSString *) name
                 modalForWindow: (NSWindow *) docWindow
                  modalDelegate: (id) modalDelegate
                 didEndSelector: (SEL) didEndSelector
                    contextInfo: (void *) contextInfo
{
    id inv = [NSInvocation
            invocationWithMethodSignature:
                    [self methodSignatureForSelector: @selector
                            (_background_beginSheetForDirectory:
                                                           file:modalForWindow
                                                               :modalDelegate
                                                               :didEndSelector
                                                               :contextInfo:)]];
    [inv setTarget: self];
    [inv setSelector: @selector
            (_background_beginSheetForDirectory:
                                           file:modalForWindow:modalDelegate
                                               :didEndSelector:contextInfo:)];
    [inv setArgument: &path atIndex: 2];
    [inv setArgument: &name atIndex: 3];
    [inv setArgument: &docWindow atIndex: 4];
    [inv setArgument: &modalDelegate atIndex: 5];
    [inv setArgument: &didEndSelector atIndex: 6];
    [inv setArgument: &contextInfo atIndex: 7];
    [inv retainArguments];
    [inv performSelectorInBackground: @selector(invoke) withObject: nil];
}

- (void) _selector_savePanelDidEnd: (NSSavePanel *) sheet
                        returnCode: (int) returnCode
                       contextInfo: (void *) contextInfo;
{
}

- (void) _background_beginSheetForDirectory: (NSString *) path
                                       file: (NSString *) name
                             modalForWindow: (NSWindow *) docWindow
                              modalDelegate: (id) modalDelegate
                             didEndSelector: (SEL) didEndSelector
                                contextInfo: (void *) contextInfo
{
    id pool = [NSAutoreleasePool new];
    int ret = [self runModalForDirectory: path file: name];

    id inv = [NSInvocation
            invocationWithMethodSignature:
                    [self methodSignatureForSelector: @selector
                            (_selector_savePanelDidEnd:
                                            returnCode:contextInfo:)]];

    [inv setTarget: modalDelegate];
    [inv setSelector: didEndSelector];
    [inv setArgument: &self atIndex: 2];
    [inv setArgument: &ret atIndex: 3];
    [inv setArgument: &contextInfo atIndex: 4];
    [inv retainArguments];

    [inv performSelectorOnMainThread: @selector(invoke)
                          withObject: nil
                       waitUntilDone: YES];
    [pool release];
}

@end
