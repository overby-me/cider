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
#import <AppKit/NSButton.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSOutlineView.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSSavePanel.h>
#import <AppKit/NSScreen.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSView.h>

/* THE HAIRLINE BETWEEN SECTIONS. macOS separates the name row, the accessory view and the buttons
 * with a one point rule the full width of the panel, and the reference screenshot has two of them.
 * A view rather than a drawn line because the sections move when the panel is resized. */
@interface _CiderPanelSeparator : NSView
@end

@implementation _CiderPanelSeparator

- (void) drawRect: (NSRect) rect {
    [[NSColor colorWithCalibratedWhite: 0.84 alpha: 1.0] setFill];
    NSRectFill([self bounds]);
}

@end

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
 * WHAT THE PANEL LOOKS LIKE, and two things the nib never had.
 *
 * THE NAME FIELD. The nib content view holds a scroll view and two buttons and nothing else, so the
 * only name a save panel could ever return was the one the application set on it. Saving worked,
 * Save As did not: there was nowhere to type.
 *
 * THE ACCESSORY VIEW. -setAccessoryView: stored the view and no more, so it was never on screen. It
 * is not decoration: LibreOffice puts File type and the save options in it, and it measures 300 by
 * 153 with seven subviews, which the panel trace says on every save. Without it there is no way to
 * choose what a document is saved AS, and the reference screenshot from macOS is close to half
 * accessory view by area.
 *
 * BUILT HERE RATHER THAN IN THE NIB on purpose. The nib is a keyed archive, so an edit to it is not
 * reviewable, and a panel that lays itself out also works for a caller that never loaded one.
 *
 * The order, bottom to top, is the macOS order: buttons at the bottom right, a hairline, the
 * accessory view, a hairline, the name row, and the file list taking whatever is left.
 */
- (BOOL) _wantsNameField {
    return YES;
}

- (void) _ensurePanelLayout {
    NSView *content = [self contentView];

    if (content == nil || _laidOut) {
        return;
    }
    _laidOut = YES;
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(_panelDidResize:)
                                                 name: NSWindowDidResizeNotification
                                               object: self];

    NSArray *subviews = [content subviews];
    NSScrollView *list = nil;
    NSButton *okButton = nil, *cancelButton = nil;
    NSInteger i, count = [subviews count];

    for (i = 0; i < count; i++) {
        NSView *view = [subviews objectAtIndex: i];

        if ([view isKindOfClass: [NSScrollView class]]) {
            list = (NSScrollView *) view;
        } else if ([view isKindOfClass: [NSButton class]]) {
            /* BY ACTION, NOT BY POSITION OR TITLE. The prompt is localized and either button can be
             * moved; what it DOES is the one thing that cannot change. */
            if ([(NSButton *) view action] == @selector(_cancel:)) {
                cancelButton = (NSButton *) view;
            } else {
                okButton = (NSButton *) view;
            }
        }
    }

    const CGFloat margin = 20.0;
    const CGFloat gap = 14.0;
    const CGFloat rowHeight = 24.0;
    const CGFloat labelWidth = 76.0;
    const CGFloat minimumList = 180.0;

    CGFloat width = [content bounds].size.width;
    CGFloat buttonHeight = (okButton != nil) ? [okButton frame].size.height : 32.0;
    CGFloat accessoryHeight = 0.0, accessoryWidth = 0.0;

    if (_accessoryView != nil) {
        accessoryHeight = [_accessoryView frame].size.height;
        accessoryWidth = [_accessoryView frame].size.width;
    }

    /* HOW TALL THE PANEL HAS TO BE for all of that plus a usable list. The nib is 400 points of
     * content and an accessory view is another 150 with its rule and its margins, so a panel that
     * did not grow would show the list as a slit. */
    /* A SAVE PANEL IS COLLAPSED UNTIL ASKED, and an OPEN panel is nothing without its list, so the
     * list is optional for one and not for the other. */
    BOOL showsList = ![self _wantsNameField] || _expanded;

    CGFloat needed = gap + buttonHeight + gap;

    if (_accessoryView != nil) {
        needed += 1.0 + gap + accessoryHeight + gap;
    }
    if ([self _wantsNameField]) {
        /* The rule, then the Where row, then the Save As row. */
        needed += 1.0 + gap + rowHeight + gap + rowHeight + gap;
    }
    if (showsList) {
        needed += minimumList + gap;
    }

    /* THE PANEL IS EXACTLY AS TALL AS WHAT IS IN IT, in both directions. It used only to GROW,
     * which was right while the list was always there; a collapsed panel that kept the nib height
     * would be a name field with a field of empty grey under it. */
    _neededHeight = needed;
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL height content=%.0f needed=%.0f window=%.0f showsList=%d expanded=%d",
              [content bounds].size.height, needed, [self frame].size.height, (int) showsList,
              (int) _expanded);
    }
    if (fabs([content bounds].size.height - needed) >= 1.0) {
        NSRect frame = [self frame];
        CGFloat grow = needed - [content bounds].size.height;
        NSScreen *screen = [self screen];

        if (screen == nil) {
            screen = [NSScreen mainScreen];
        }
        if (grow > 0.0 && screen != nil) {
            CGFloat room = [screen visibleFrame].size.height - frame.size.height - 20.0;

            if (grow > room) {
                grow = (room > 0.0) ? room : 0.0;
            }
        }
        /* THE TOP EDGE STAYS PUT, which is what a window that grows looks like on any desktop. */
        frame.size.height += grow;
        frame.origin.y -= grow;
        [self setFrame: frame display: NO];
        if (getenv("CIDER_TRACE_PANEL") != NULL) {
            NSLog(@"CIDER_PANEL resized grow=%.0f window=%.0f content=%.0f", grow,
                  [self frame].size.height, [[self contentView] bounds].size.height);
        }
    }

    CGFloat height = [content bounds].size.height;
    CGFloat y = gap;

    if (okButton != nil) {
        NSRect frame = [okButton frame];

        [okButton setBezelStyle: NSRoundedBezelStyle];
        frame.origin.x = width - margin - frame.size.width;
        frame.origin.y = y;
        [okButton setFrame: frame];
        [okButton setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];

        if (cancelButton != nil) {
            NSRect cancel = [cancelButton frame];

            /* BOTH BUTTONS AT THE RIGHT, cancel then the default one. The nib has cancel in the far
             * bottom left corner, which is a Windows dialog. */
            [cancelButton setBezelStyle: NSRoundedBezelStyle];
            cancel.origin.x = frame.origin.x - 12.0 - cancel.size.width;
            cancel.origin.y = y;
            [cancelButton setFrame: cancel];
            [cancelButton setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
        }
        y += frame.size.height + gap;
    }

    if (_accessoryView != nil) {
        _CiderPanelSeparator *rule = [[[_CiderPanelSeparator alloc]
                initWithFrame: NSMakeRect(0.0, y, width, 1.0)] autorelease];

        [rule setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
        [content addSubview: rule];
        y += 1.0 + gap;

        NSRect frame = [_accessoryView frame];

        frame.origin.x = floor((width - accessoryWidth) / 2.0);
        frame.origin.y = y;
        [_accessoryView setFrame: frame];
        [_accessoryView setAutoresizingMask:
                                NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin];
        [content addSubview: _accessoryView];
        y += accessoryHeight + gap;
    }

    if ([self _wantsNameField] && _nameField == nil) {
        _CiderPanelSeparator *rule = [[[_CiderPanelSeparator alloc]
                initWithFrame: NSMakeRect(0.0, y, width, 1.0)] autorelease];

        [rule setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
        [content addSubview: rule];
        y += 1.0 + gap;

        /*
         * WHERE THE FILE GOES, which is the row a macOS save panel has and this one did not.
         *
         * The reference screenshot the user sent opens COLLAPSED: Save As, then Where, then a
         * chevron at the end of the Where row for anyone who wants the file system. Ours always
         * showed the whole tree, which is the panel a Mac only shows after you ask for it.
         *
         * The chevron toggles the list rather than replacing it, so nothing that already worked is
         * taken away: the tree is still where a file is chosen out of a directory the popup does
         * not offer.
         */
        NSTextField *whereLabel = [[[NSTextField alloc]
                initWithFrame: NSMakeRect(margin, y, labelWidth, rowHeight)] autorelease];

        [whereLabel setStringValue: @"Where:"];
        [whereLabel setEditable: NO];
        [whereLabel setSelectable: NO];
        [whereLabel setBordered: NO];
        [whereLabel setDrawsBackground: NO];
        [whereLabel setAlignment: NSRightTextAlignment];
        [whereLabel setTextColor: [NSColor colorWithCalibratedWhite: 0.32 alpha: 1.0]];
        [whereLabel setAutoresizingMask: NSViewMaxYMargin];
        [content addSubview: whereLabel];

        CGFloat whereLeft = margin + labelWidth + 8.0;
        CGFloat chevronWidth = 30.0;

        _whereButton = [[NSPopUpButton alloc]
                initWithFrame: NSMakeRect(whereLeft, y,
                                          width - whereLeft - margin - chevronWidth - 8.0,
                                          rowHeight)
                    pullsDown: NO];
        [_whereButton setTarget: self];
        [_whereButton setAction: @selector(_whereChanged:)];
        [_whereButton setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
        [content addSubview: _whereButton];
        [self _rebuildWhereMenu];

        _disclosureButton = [[NSButton alloc]
                initWithFrame: NSMakeRect(width - margin - chevronWidth, y, chevronWidth,
                                          rowHeight)];
        [_disclosureButton setBezelStyle: NSRoundedBezelStyle];
        [_disclosureButton setTitle: _expanded ? @"^" : @"v"];
        [_disclosureButton setTarget: self];
        [_disclosureButton setAction: @selector(_toggleBrowser:)];
        [_disclosureButton setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
        [content addSubview: _disclosureButton];
        y += rowHeight + gap;

        NSTextField *label = [[[NSTextField alloc]
                initWithFrame: NSMakeRect(margin, y, labelWidth, rowHeight)] autorelease];

        /* RIGHT ALIGNED AND GREY, which is what every label in a macOS form is. */
        [label setStringValue: @"Save As:"];
        [label setEditable: NO];
        [label setSelectable: NO];
        [label setBordered: NO];
        [label setDrawsBackground: NO];
        [label setAlignment: NSRightTextAlignment];
        [label setTextColor: [NSColor colorWithCalibratedWhite: 0.32 alpha: 1.0]];
        [label setAutoresizingMask: NSViewMaxYMargin];
        [content addSubview: label];

        CGFloat fieldLeft = margin + labelWidth + 8.0;

        _nameField = [[NSTextField alloc]
                initWithFrame: NSMakeRect(fieldLeft, y, width - fieldLeft - margin, rowHeight)];
        [_nameField setEditable: YES];
        [_nameField setStringValue: (_nameFieldStringValue != nil) ? _nameFieldStringValue : @""];
        [_nameField setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
        [content addSubview: _nameField];
        y += rowHeight + gap;
    }

    /* WHAT THE LIST SHOWS, and it is not what a Mac shows. Rows banded in light blue are a
     * Cocotron default; the open panel in macOS is plain white with a blue pill on the selected
     * row. And a panel that lists dot files opens on .ciderd.sock and .init.pid, above anything a
     * person would want, so the data source is told which the panel is. */
    if (_outlineView != nil) {
        id source = [_outlineView dataSource];

        /* AND THE BACKGROUND WITH IT. Turning the banding off drops the table back on its own
         * background colour, which is the control grey: the list came out grey on a white panel.
         * A file list is white on macOS. */
        [_outlineView setUsesAlternatingRowBackgroundColors: NO];
        [_outlineView setBackgroundColor: [NSColor whiteColor]];
        if ([source respondsToSelector: @selector(setShowsHiddenFiles:)]) {
            [source setShowsHiddenFiles: _showsHiddenFiles];
            [_outlineView reloadData];
        }
    }

    /* THE LIST TAKES WHAT IS LEFT, top edge at the top margin. Everything below it has a fixed
     * height, so this is the only view whose size depends on the panel. */
    if (list != nil) {
        /* HIDDEN RATHER THAN REMOVED when the panel is collapsed. The outline view is the nib
         * view every other method here reaches for, and taking it out of the hierarchy would make
         * -_revealDirectory and -_selectFile answer nil instead of a path. */
        [list setHidden: !showsList];
        if ([list isHidden]) {
            NSRect frame = [list frame];

            frame.origin.x = margin;
            frame.origin.y = y;
            frame.size.width = width - margin * 2.0;
            frame.size.height = 1.0;
            [list setFrame: frame];
        } else {
            NSRect frame = [list frame];

            frame.origin.x = margin;
            frame.origin.y = y;
            frame.size.width = width - margin * 2.0;
            frame.size.height = height - y - gap;
            if (frame.size.height < 40.0) {
                frame.size.height = 40.0;
            }
            [list setFrame: frame];
            [list setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
        }
    }
}

/*
 * THE PLACES THE POPUP OFFERS: the directory the panel was told to open in, then the usual four.
 * Each one is checked to exist, because a container whose home has no Desktop should not offer one,
 * and each is offered once, so a panel opened in Documents does not list it twice.
 */
- (void) _rebuildWhereMenu {
    if (_whereButton == nil) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *current = [self directory];

    if ([current length] > 0) {
        [paths addObject: current];
    }
    for (NSString *p in [NSArray arrayWithObjects: NSHomeDirectory(),
                                  [NSHomeDirectory() stringByAppendingPathComponent: @"Documents"],
                                  [NSHomeDirectory() stringByAppendingPathComponent: @"Desktop"],
                                  [NSHomeDirectory() stringByAppendingPathComponent: @"Downloads"],
                                  nil]) {
        BOOL isDirectory = NO;

        if ([fm fileExistsAtPath: p isDirectory: &isDirectory] && isDirectory
            && ![paths containsObject: p]) {
            [paths addObject: p];
        }
    }

    [_whereButton removeAllItems];
    for (NSString *p in paths) {
        NSString *title = [p lastPathComponent];

        if ([title length] == 0 || [title isEqualToString: @"/"]) {
            title = @"Computer";
        }
        [_whereButton addItemWithTitle: title];
        [[_whereButton lastItem] setRepresentedObject: p];
    }
    if ([_whereButton numberOfItems] > 0) {
        [_whereButton selectItemAtIndex: 0];
    }
}

- (IBAction) _whereChanged: (id) sender {
    NSString *path = [[_whereButton selectedItem] representedObject];

    if ([path length] == 0) {
        return;
    }
    [self setDirectory: path];
    if (_expanded) {
        [self _revealDirectory];
    }
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL where=%@", path);
    }
}

/*
 * THE CHEVRON, which grows the panel by the height of the list and shrinks it back. The layout runs
 * once and then guards itself, so this moves the views it owns rather than running it again.
 */
/*
 * A PANEL THAT CANNOT BE SMALL SHOWS THE BROWSER RATHER THAN AN EMPTY BAND.
 *
 * A collapsed save panel is 355 points tall here and the compositor may say otherwise: sway hands
 * this one 500x422 and CONFIGURES IT BACK every time it is asked to shrink, which is the
 * compositor prerogative and not something a client argues with. Measured, three lines:
 *
 *     setframe  number=48 asked=500x355 current=500x422
 *     backing   number=48 was=0x0       now=500x355
 *     configure number=48 asked=500x422 frame=500x355
 *
 * Obeying it left 67 points of empty grey above the first row. So the surplus goes to the list: if
 * the window ends up taller than the collapsed form needs, the browser is shown and fills it, which
 * is both the useful thing and the only arrangement with nothing empty in it.
 */
- (void) _panelDidResize: (NSNotification *) note {
    if (!_laidOut || _neededHeight <= 0.0) {
        return;
    }

    CGFloat have = [[self contentView] bounds].size.height;
    BOOL wantsList = (have > _neededHeight + 60.0);

    if (wantsList == _expanded) {
        return;
    }
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL resize have=%.0f needed=%.0f expanding=%d", have, _neededHeight,
              (int) wantsList);
    }
    _expanded = wantsList;
    [_disclosureButton setTitle: _expanded ? @"^" : @"v"];
    [self _placeBrowser];
    if (_expanded) {
        [self _revealDirectory];
    }
}

/* Where the list goes, given whatever height the window has ended up with. */
- (void) _placeBrowser {
    NSView *content = [self contentView];
    NSScrollView *list = nil;

    for (NSView *view in [content subviews]) {
        if ([view isKindOfClass: [NSScrollView class]]) {
            list = (NSScrollView *) view;
        }
    }
    if (list == nil) {
        return;
    }

    CGFloat top = (_nameField != nil) ? NSMaxY([_nameField frame]) + 14.0 : 20.0;
    NSRect frame = NSMakeRect(20.0, top, [content bounds].size.width - 40.0,
                              [content bounds].size.height - top - 14.0);

    if (frame.size.height < 40.0) {
        frame.size.height = 40.0;
    }
    [list setHidden: !_expanded];
    [list setFrame: frame];
    [content setNeedsDisplay: YES];
}

- (IBAction) _toggleBrowser: (id) sender {
    NSView *content = [self contentView];
    NSScrollView *list = nil;

    for (NSView *view in [content subviews]) {
        if ([view isKindOfClass: [NSScrollView class]]) {
            list = (NSScrollView *) view;
        }
    }

    _expanded = !_expanded;
    [_disclosureButton setTitle: _expanded ? @"^" : @"v"];

    /* THE VIEWS ARE MOVED RATHER THAN LAID OUT AGAIN. -_ensurePanelLayout ADDS the hairlines and
     * the rows, and it guards itself against running twice for exactly that reason: calling it
     * again here would leave a second rule under the accessory view on every toggle. Everything
     * below the list has a fixed height and is pinned to the bottom, so only the window and the
     * list itself have to change. */
    NSRect frame = [self frame];
    CGFloat delta = 240.0;

    if (_expanded) {
        frame.size.height += delta;
        frame.origin.y -= delta;
    } else {
        frame.size.height -= delta;
        frame.origin.y += delta;
    }
    [self setFrame: frame display: YES];

    (void) list;
    [self _placeBrowser];
    if (_expanded) {
        [self _revealDirectory];
    }
}

/*
 * SHOW THE DIRECTORY THE PANEL IS ACTUALLY SAVING INTO.
 *
 * The list is rooted at / and stayed there, so a save panel opened on /Users/root/Documents showed
 * Applications, bin, dev and the rest of the prefix root, and the file landed somewhere the panel
 * had never displayed. The trace said it plainly on every run: directory=/Users/root/Documents with
 * the list showing /.
 *
 * There is no path popup to navigate with, so the tree is not RE-ROOTED, which would trap a caller
 * inside one directory. Each component is expanded in turn and the target scrolled into view, which
 * leaves everything else reachable.
 *
 * The item objects belong to the data source, so they are found by path among the rows that are
 * currently visible rather than constructed here: expanding a level makes its children rows, which
 * is what the next component is looked up in.
 */
- (id) _itemForPath: (NSString *) path {
    NSInteger i, count = [_outlineView numberOfRows];

    for (i = 0; i < count; i++) {
        NSURL *item = [_outlineView itemAtRow: i];

        if ([[item path] isEqualToString: path]) {
            return item;
        }
    }
    return nil;
}

- (void) _revealDirectory {
    NSString *directory = [self directory];

    if (_outlineView == nil || [directory length] == 0) {
        return;
    }

    /* STARTS AT THE ROOT, not at the empty string. -pathComponents gives "/" as its first element
     * and skipping it without seeding the path built Users rather than /Users, which matches no row
     * and made the whole walk stop on its first step. */
    NSArray *parts = [directory pathComponents];
    NSString *path = @"/";
    NSInteger i, count = [parts count];

    for (i = 0; i < count; i++) {
        NSString *part = [parts objectAtIndex: i];

        if ([part isEqualToString: @"/"]) {
            continue;
        }
        path = [path stringByAppendingPathComponent: part];

        id item = [self _itemForPath: path];

        /* PER COMPONENT, because a walk that stops has one place it stopped and the path it was
         * looking for at the time. The first version built Users rather than /Users and this line
         * is what said so. */
        if (getenv("CIDER_TRACE_PANEL") != NULL) {
            NSLog(@"CIDER_PANEL reveal step=%@ item=%@", path, item);
        }
        if (item == nil) {
            break;
        }
        [_outlineView expandItem: item];
    }

    id target = [self _itemForPath: directory];

    if (target != nil) {
        NSInteger row = [_outlineView rowForItem: target];

        if (row >= 0) {
            /* SELECTED ONLY FOR A SAVE, where the row IS the destination. An open panel answers
             * with the selected row, so selecting a directory there would answer with a directory
             * for a caller that asked for a file. */
            if ([self _wantsNameField]) {
                [_outlineView selectRow: row byExtendingSelection: NO];
            }
            /* THE CONTENTS OF IT, not just the row. -scrollRowToVisible: scrolls the MINIMUM, so
             * the directory landed on the bottom edge with everything in it below the fold, which
             * is the one thing the panel is meant to be showing. Scrolling past it first and then
             * back puts it near the top with its files under it. */
            NSInteger last = [_outlineView numberOfRows] - 1;
            NSInteger below = (row + 8 < last) ? row + 8 : last;

            [_outlineView scrollRowToVisible: below];
            [_outlineView scrollRowToVisible: row];
        }
    }
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL reveal directory=%@ found=%d rows=%ld", directory, (int) (target != nil),
              (long) [_outlineView numberOfRows]);
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
        [self _ensurePanelLayout];
        [self _revealDirectory];
        if (getenv("CIDER_TRACE_PANEL") != NULL) {
            NSView *content = [self contentView];
            NSArray *subviews = [content subviews];
            NSInteger i, count = [subviews count];

            NSLog(@"CIDER_PANEL save window=%@ content=%@ subviews=%ld accessory=%@",
                  NSStringFromRect([self frame]), NSStringFromRect([content frame]), (long) count,
                  [_accessoryView class]);
            for (i = 0; i < count; i++) {
                NSView *view = [subviews objectAtIndex: i];

                NSLog(@"CIDER_PANEL   sub=%@ frame=%@", [view class],
                      NSStringFromRect([view frame]));
            }
        }
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
    /* WHETHER THE CALLER SENDS ONE AT ALL decides whether the panel needs a section for it. On
     * macOS this is where LibreOffice puts File type and the save options, and the reference
     * screenshot is half accessory view by area. */
    if (getenv("CIDER_TRACE_PANEL") != NULL) {
        NSLog(@"CIDER_PANEL accessory=%@ frame=%@ subviews=%lu", [view class],
              (view != nil) ? NSStringFromRect([view frame]) : @"(nil)",
              (unsigned long) [[view subviews] count]);
    }
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
