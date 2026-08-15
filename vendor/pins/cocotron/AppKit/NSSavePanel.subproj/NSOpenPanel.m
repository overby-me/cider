/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

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
#import <AppKit/NSApplication.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSOpenPanel.h>
#import <Foundation/NSURL.h>

@interface NSSavePanel (Private)
- (void) _setFilename: (NSString *) filename;
@end

@implementation NSOpenPanel

- (id) resetToDefaultValues {
    self = [super resetToDefaultValues];
    _filenames = [NSArray new];
    [_dialogTitle release];
    _dialogTitle = [NSLocalizedStringFromTableInBundle(
            @"Open", nil, [NSBundle bundleForClass: [NSOpenPanel class]],
            @"The title of the open panel") copy];
    _allowsMultipleSelection = NO;
    _canChooseDirectories = NO;
    _canChooseFiles = YES;
    _resolvesAliases = YES;
    return self;
}

static NSOpenPanel *_newPanel = nil;

+ (void) set_newPanel: (NSOpenPanel *) newPanel {
    _newPanel = newPanel;
}

+ (NSSavePanel *) openPanel {
    if ([[NSDisplay currentDisplay] implementsCustomPanelForClass: self]) {
        _newPanel = [[self alloc]
                initWithContentRect: NSMakeRect(0, 0, 1, 1)
                          styleMask: NSTitledWindowMask | NSResizableWindowMask
                            backing: NSBackingStoreBuffered
                              defer: YES];
    } else {
        [NSBundle loadNibNamed: @"NSOpenPanel" owner: self];
    }
    // FIXME: release it?
    return [_newPanel resetToDefaultValues];
}

- init {
    [self release];
    return [[NSOpenPanel openPanel] retain];
}

- (void) dealloc {
    [_filenames release];
    [super dealloc];
}

- (NSArray *) filenames {
    id ret = nil;
    @synchronized(self) {
        ret = [[_filenames copy] autorelease];
    }
    return ret;
}

- (NSArray *) URLs {
    NSArray *paths = [self filenames];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity: [paths count]];
    int i, count = [paths count];

    for (i = 0; i < count; i++)
        [result addObject: [NSURL fileURLWithPath: [paths objectAtIndex: i]]];

    return result;
}

- (void) _setFilename: (NSString *) filename {
    [super _setFilename: filename];
    _filenames = [@[ filename ] retain];
}

/*
 * OPENING ANSWERS WITH THE ROW, and says so here rather than relying on the superclass.
 *
 * NSSavePanel's version now prefers the name field, because a file being SAVED does not exist yet
 * and has no row. An open panel is the opposite case: the row is the whole answer, and a stale name
 * left in the field must not override what the user picked.
 */
- (IBAction) _selectFile: (id) sender {
    NSURL *url = [_outlineView itemAtRow: [_outlineView selectedRow]];
    [self _setFilename: [url path]];

    [NSApp stopModalWithCode: NSOKButton];
}

- (NSInteger) runModalForDirectory: (NSString *) directory
                              file: (NSString *) file
                             types: (NSArray *) types
{
    [self _setFilename: file];
    [self setDirectory: directory];
    [self setAllowedFileTypes: types];
    return [self runModal];
}

- (NSInteger) runModalForTypes: (NSArray *) types {
    [self setAllowedFileTypes: types];
    return [self runModal];
}

- (NSInteger) runModalForDirectory: (NSString *) directory
                              file: (NSString *) file
{
    [self setDirectory: directory];
    [self _setFilename: file];
    return [self runModal];
}

/* AN OPEN PANEL HAS NO NAME FIELD on any platform: the row is the answer. Everything else about the
 * layout, including the accessory view an application gives it, is the same as a save panel. */
- (BOOL) _wantsNameField {
    return NO;
}

- (NSInteger) runModal {
    NSInteger res;
    if ([[NSDisplay currentDisplay]
                implementsCustomPanelForClass: [self class]]) {
        res = [[NSDisplay currentDisplay] openPanel: self
                               runModalForDirectory: [self directory]
                                               file: [self filename]
                                              types: [self allowedFileTypes]];
    } else {
        /* WHERE THE PANEL PUT ITS OWN CONTROLS. The Cancel and Open buttons are drawn cut in half
         * at the bottom edge of the panel in every screenshot, and a button that is half there is
         * either laid out below the content or laid out into a window shorter than the nib. The
         * two rects say which without another guess. */
        [self _ensurePanelLayout];
        if (getenv("CIDER_TRACE_PANEL") != NULL) {
            NSView *content = [self contentView];
            NSArray *subviews = [content subviews];
            NSInteger i, count = [subviews count];

            NSLog(@"CIDER_PANEL layout window=%@ content=%@ subviews=%ld",
                  NSStringFromRect([self frame]), NSStringFromRect([content frame]),
                  (long) count);
            for (i = 0; i < count; i++) {
                NSView *view = [subviews objectAtIndex: i];

                NSLog(@"CIDER_PANEL   sub=%@ frame=%@ mask=%lu", [view class],
                      NSStringFromRect([view frame]),
                      (unsigned long) [view autoresizingMask]);
            }
        }
        /* THE LIST IS WHAT THE KEYBOARD SHOULD DRIVE. An open panel has no name field, so with no
         * first responder set the characters went to the window and nowhere else, and typing a
         * file name selected nothing. NSTableView answers -insertText: with a type select now, and
         * this is what points the keyboard at it. */
        if (_outlineView != nil) {
            BOOL took = [self makeFirstResponder: _outlineView];

            if (getenv("CIDER_TRACE_PANEL") != NULL) {
                NSLog(@"CIDER_PANEL firstresponder took=%d outline=%p now=%@", (int) took,
                      (void *) _outlineView, [self firstResponder]);
            }
        } else if (getenv("CIDER_TRACE_PANEL") != NULL) {
            NSLog(@"CIDER_PANEL firstresponder outline=nil");
        }
        res = [NSApp runModalForWindow: self];
        [self close];
    }
    return res;
}

- (BOOL) allowsMultipleSelection {
    return _allowsMultipleSelection;
}

- (BOOL) canChooseDirectories {
    return _canChooseDirectories;
}

- (BOOL) canChooseFiles {
    return _canChooseFiles;
}

- (BOOL) resolvesAliases {
    return _resolvesAliases;
}

- (void) setAllowsMultipleSelection: (BOOL) flag {
    _allowsMultipleSelection = flag;
}

- (void) setCanChooseDirectories: (BOOL) flag {
    _canChooseDirectories = flag;
}

- (void) setCanChooseFiles: (BOOL) flag {
    _canChooseFiles = flag;
}

- (void) setResolvesAliases: (BOOL) value {
    _resolvesAliases = value;
}

#pragma mark -
#pragma mark Sheet methods
- (void) beginSheetForDirectory: (NSString *) path
                           file: (NSString *) name
                          types: (NSArray *) fileTypes
                 modalForWindow: (NSWindow *) docWindow
                  modalDelegate: (id) modalDelegate
                 didEndSelector: (SEL) didEndSelector
                    contextInfo: (void *) contextInfo
{
    id inv = [NSInvocation
            invocationWithMethodSignature:
                    [self methodSignatureForSelector: @selector
                            (_background_beginSheetForDirectory:
                                                           file:types
                                                               :modalForWindow
                                                               :modalDelegate
                                                               :didEndSelector
                                                               :contextInfo:)]];
    [inv setTarget: self];
    [inv setSelector: @selector
            (_background_beginSheetForDirectory:
                                           file:types:modalForWindow
                                               :modalDelegate:didEndSelector
                                               :contextInfo:)];
    [inv setArgument: &path atIndex: 2];
    [inv setArgument: &name atIndex: 3];
    [inv setArgument: &fileTypes atIndex: 4];
    [inv setArgument: &docWindow atIndex: 5];
    [inv setArgument: &modalDelegate atIndex: 6];
    [inv setArgument: &didEndSelector atIndex: 7];
    [inv setArgument: &contextInfo atIndex: 8];
    [inv retainArguments];
    [inv performSelectorInBackground: @selector(invoke) withObject: nil];
}

- (void) _background_beginSheetForDirectory: (NSString *) path
                                       file: (NSString *) name
                                      types: (NSArray *) fileTypes
                             modalForWindow: (NSWindow *) docWindow
                              modalDelegate: (id) modalDelegate
                             didEndSelector: (SEL) didEndSelector
                                contextInfo: (void *) contextInfo
{
    id pool = [NSAutoreleasePool new];
    int ret = [self runModalForDirectory: path file: name types: fileTypes];

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
                       waitUntilDone: NO];
    [pool release];
}

@end
