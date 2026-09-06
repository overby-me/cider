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
#import <AppKit/NSApplication.h>
#import <AppKit/NSDocument.h>
#import <AppKit/NSNib.h>
#import <AppKit/NSNibLoading.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSWindowController.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <objc/runtime.h>
#include <stdlib.h>

/*
 * THE NIB IS READ ONCE, WHATEVER IT PRODUCED.
 *
 * -window reloads whenever _window is still nil, so a nib that loads WITHOUT connecting the File
 * Owner window outlet is read again on every call, for ever: MoneyMoney ran 19,931 of those cycles
 * in a single run and never got past its main window.
 *
 * The flag is an ASSOCIATED OBJECT, and both of the obvious alternatives were tried and measured.
 * An ivar changes instanceSize, and an application subclass compiled against the real AppKit has
 * its own ivars laid out after ours: adding one BOOL here stopped MoneyMoney reaching its window
 * controller at all, which looked nothing like a layout problem. Clearing our own _nibPath does not
 * work either, because a subclass that overrides -windowNibName, the ordinary way to write one,
 * recomputes the path and loads again regardless.
 */
static const void *kCiderNibLoadedKey = &kCiderNibLoadedKey;

@implementation NSWindowController

- initWithWindow: (NSWindow *) window {
    _window = [window retain];
    [_window setWindowController: self];
    [_window setReleasedWhenClosed: NO];

    if (_window != nil)
        [[NSNotificationCenter defaultCenter]
                addObserver: self
                   selector: @selector(_windowWillClose:)
                       name: NSWindowWillCloseNotification
                     object: _window];

    _nibName = nil;
    _nibPath = nil;
    _owner = self;
    _document = nil;
    _shouldCloseDocument = NO;
    _shouldCascadeWindows = YES;
    _windowFrameAutosaveName = nil;
    return self;
}

- initWithWindowNibName: (NSString *) nibName {
    return [self initWithWindowNibName: nibName owner: self];
}

- initWithWindowNibName: (NSString *) nibName owner: owner {
    [self initWithWindow: nil];
    _nibName = [nibName copy];
    _nibPath = nil;
    _owner = owner;
    return self;
}

- initWithWindowNibPath: (NSString *) nibPath owner: owner {
    [self initWithWindow: nil];
    _nibName =
            [[[nibPath lastPathComponent] stringByDeletingPathExtension] copy];
    _nibPath = [nibPath copy];
    _owner = owner;
    return self;
}

- init {
    return [self initWithWindow: nil];
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    [_window setWindowController: nil];
    [_window release];
    _window = nil;
    [_nibName release];
    [_nibPath release];
    [_windowFrameAutosaveName release];
    [_topLevelObjects makeObjectsPerformSelector: @selector(release)];
    [_topLevelObjects release];
    [super dealloc];
}

/*
 * FIVE STEPS, EACH ANNOUNCED, because the method as a whole was known not to return and that says
 * nothing about which step is holding it.
 *
 * Swift Publisher enters -showWindow: for CAMainWindowController, Document2.nib decodes, its
 * toolbar images load, and the caller never sees a window. Any of these five can be the one that
 * does not come back: three of them are the application overriding a hook.
 */
#define CIDER_WC_STEP(name)                                                    \
    do {                                                                       \
        if (getenv("CIDER_TRACE_CONTROL") != NULL) {                           \
            fprintf(stderr, "CIDER_WC %s %s\n", class_getName([self class]),   \
                    (name));                                                   \
            fflush(stderr);                                                    \
        }                                                                      \
    } while (0)

- (NSWindow *) window {
    if (_window == nil && objc_getAssociatedObject(self, kCiderNibLoadedKey) == nil &&
        [self windowNibPath] != nil) {
        /* WHAT THE CONTROLLER ALREADY HOLDS WHEN ITS NIB LOADS. A nib load runs awakeFromNib, and
         * an application that fills the controller in BEFORE handing it to the document expects
         * its own state to be there by then. Swift Publisher writes the canvas zoom only when its
         * ftView is set, so if the nib loads first that write is skipped and the canvas scales by
         * zero. Printing the pointer at this exact step is what separates the two orders. */
        if (getenv("CIDER_TRACE_CONTROL") != NULL) {
            SEL ftSel = sel_getUid("ftView");
            void *ft = NULL;

            if ([self respondsToSelector: ftSel]) {
                void *(*send)(id, SEL) = (void *(*)(id, SEL)) objc_msgSend;

                ft = send(self, ftSel);
            }
            fprintf(stderr, "CIDER_WC %s nibLoadBegins ftView=%p document=%s\n",
                    class_getName([self class]), ft,
                    _document != nil ? object_getClassName(_document) : "nil");
            fflush(stderr);
        }

        CIDER_WC_STEP("windowWillLoad");
        [self windowWillLoad];

        CIDER_WC_STEP("windowControllerWillLoadNib");
        [_document windowControllerWillLoadNib: self];

        CIDER_WC_STEP("loadWindow");
        [self loadWindow];

        CIDER_WC_STEP("windowDidLoad");
        [self windowDidLoad];

        CIDER_WC_STEP("windowControllerDidLoadNib");
        [_document windowControllerDidLoadNib: self];

        CIDER_WC_STEP("done");
    }

    return _window;
}

- (void) setWindow: (NSWindow *) window {
    /* WHO GIVES A CONTROLLER ITS WINDOW. The iA Writer nib holds no window at all, the window is
     * built in code, and every controller ended up holding the FIRST window: only the caller says
     * whether that is the application reusing one window by design or a fallback of ours
     * misrouting. */
    if (getenv("CIDER_TRACE_CONTROL") != NULL) {
        Dl_info info;
        void *ret = __builtin_return_address(0);
        int have = dladdr(ret, &info);

        fprintf(stderr, "CIDER_WC %s(%p) setWindow %p (was %p) by %s +%#lx\n",
                class_getName([self class]), (void *) self, (void *) window, (void *) _window,
                (have != 0 && info.dli_sname != NULL) ? info.dli_sname : "?",
                (have != 0) ? (unsigned long) ((char *) ret - (char *) info.dli_fbase) : 0UL);
        fflush(stderr);
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    if (_window)
        [center removeObserver: self
                          name: NSWindowWillCloseNotification
                        object: _window];

    window = [window retain];

    [_window setWindowController: nil];
    [_window release];

    _window = window;

    [_window setWindowController: self];
    [_window setReleasedWhenClosed: NO];

    if (_window)
        [center addObserver: self
                   selector: @selector(_windowWillClose:)
                       name: NSWindowWillCloseNotification
                     object: _window];
}

- (void) _windowWillClose: (NSNotification *) note {
    [self setWindow: nil];

    if (_document) {
        [[self retain] autorelease];

        if ([self shouldCloseDocument] ||
            [[_document windowControllers] count] == 1)
            [_document close];
        else {
            [_document removeWindowController: self];
        }
    }
}

- (BOOL) isWindowLoaded {
    return (_window != nil) ? YES : NO;
}

- (void) loadWindow {
    if (![self isWindowLoaded]) {
        static NSPoint cascadeTopLeftSavedPoint = {0.0, 0.0};

        /* Marked BEFORE the nib is read, so that anything the load itself asks for does not start
         * another load underneath this one. */
        objc_setAssociatedObject(self, kCiderNibLoadedKey, self, OBJC_ASSOCIATION_ASSIGN);
        NSString *path = [self windowNibPath];
        NSDictionary *nameTable;

        _topLevelObjects = [[NSMutableArray alloc] init];
        nameTable = [NSDictionary
                dictionaryWithObjectsAndKeys: _owner, NSNibOwner,
                                              _topLevelObjects,
                                              NSNibTopLevelObjects, nil];

        /* THREE CALLS, EACH BRACKETED. loadWindow is known not to return for the Swift Publisher
         * document window while the same method finishes for two other controllers, and these are
         * the only three things in it. */
        CIDER_WC_STEP("loadNibFile enter");
        if (![NSBundle loadNibFile: path
                    externalNameTable: nameTable
                             withZone: NULL]) {
            NSLog(@"%s: unable to load nib from file '%@'", __PRETTY_FUNCTION__,
                  path);
        }
        CIDER_WC_STEP("loadNibFile leave");

        /*
         * A NIB LOADED WINDOW NEVER LEARNED ITS CONTROLLER, and the omission is silent.
         *
         * The nib connects its window outlet straight into the _window ivar, so -setWindow: does
         * not run and nothing calls -[NSWindow setWindowController:]. Every later
         * -[NSWindow windowController] then answers nil. On macOS a window loaded by a controller
         * always knows it.
         *
         * That nil is what kept the Swift Publisher canvas empty. -[CCDocView drawRect:] opens
         * with [[self window] windowController], asks it for the document, and returns without
         * drawing anything when it is nil, so the view was called ten times a run and issued zero
         * drawing operations while looking, from every read only instrument, exactly like a
         * document that had failed to load.
         */
        /* A CONTROLLER MUST ADOPT THE WINDOW ITS NIB MADE. The wiring above relies on the nib
         * window outlet landing in _window, and for a Swift subclass it does not: the outlet
         * stores into Swift side storage and _window stays nil. Every controller then answered
         * some other window from the fallbacks, which was RIGHT for the first controller by
         * coincidence and WRONG for every one after it: iA Writer opened each document into a
         * fresh window whose views held the text while showWindow ordered the first window front
         * again, so no document ever appeared. The nib top level objects still hold the window,
         * and on macOS the controller owns it either way. */
        if (_window == nil) {
            for (id topLevel in _topLevelObjects) {
                if ([topLevel isKindOfClass: [NSWindow class]]) {
                    [self setWindow: topLevel];
                    break;
                }
            }
        }

        if (_window != nil)
            [_window setWindowController: self];

        if (getenv("CIDER_TRACE_CONTROL") != NULL) {
            fprintf(stderr, "CIDER_WC %s adopted window=%p controller=%p\n",
                    class_getName([self class]), _window,
                    _window != nil ? [_window windowController] : NULL);
            fflush(stderr);
        }

        [self synchronizeWindowTitleWithDocumentName];
        CIDER_WC_STEP("synchronizeWindowTitle leave");

        if (_shouldCascadeWindows)
            cascadeTopLeftSavedPoint =
                    [_window cascadeTopLeftFromPoint: cascadeTopLeftSavedPoint];
        CIDER_WC_STEP("cascade leave");
    }
}

- (void) windowWillLoad {
    // do nothing
}

- (void) windowDidLoad {
    // do nothing
}

- (void) showWindow: sender {
    /*
     * A NIL WINDOW HERE IS SILENT, and that is the whole of a document that does not open.
     * Swift Publisher gets as far as loading Document2.nib and then nothing appears; a controller
     * whose window outlet was never connected sends makeKeyAndOrderFront: to nil and returns
     * without a word, which from outside is identical to a window that opened offscreen.
     */
    /*
     * BEFORE AND AFTER, because one print cannot tell the two failures apart.
     *
     * A single line after [self window] is silent both when showWindow: was never called and when
     * it was called and the window never came back. Swift Publisher is the second: the enter line
     * prints, Document2.nib loads, its toolbar builds, and the leave line never arrives, so
     * -[NSWindowController window] does not return and makeKeyAndOrderFront: below is never
     * reached. That is why the document window is not on screen.
     */
    if (getenv("CIDER_TRACE_CONTROL") != NULL) {
        fprintf(stderr, "CIDER_DOC showWindow ENTER controller=%s\n",
                class_getName([self class]));
        fflush(stderr);
    }

    NSWindow *window = [self window];

    if (getenv("CIDER_TRACE_CONTROL") != NULL) {
        fprintf(stderr, "CIDER_DOC showWindow HAVE-WINDOW controller=%s window=%p\n",
                class_getName([self class]), window);
        fflush(stderr);
    }

    [window makeKeyAndOrderFront: sender];

    if (getenv("CIDER_TRACE_CONTROL") != NULL) {
        fprintf(stderr, "CIDER_DOC showWindow ORDERED controller=%s\n",
                class_getName([self class]));

        /* THE SAME PROBE AS IN -[NSDocument addWindowController:], BUT LATER. The one there runs
         * before the window is on screen, so a value that is filled in during the nib load or on
         * first display would read as nil there and mislead. Pointers only: these answer C++
         * objects, and object_getClassName on one of them segfaults. */
        {
            static const char *const probes[] = {"ftView", "currentDesignElement",
                                                 "designElementsArrayController"};
            size_t i;

            for (i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                SEL probe = sel_getUid(probes[i]);

                if ([self respondsToSelector: probe])
                    fprintf(stderr, "CIDER_DOC showWindow %s -> %p\n", probes[i],
                            (void *) [self performSelector: probe]);
            }
        }
        fflush(stderr);
    }
}

- (void) setDocument: (NSDocument *) document {
    _document = document;
}

- (id) document {
    return _document;
}

- (void) setDocumentEdited: (BOOL) flag {
    [_window setDocumentEdited: flag];
}

- (void) close {
    [_window close];
}

- (BOOL) shouldCloseDocument {
    return _shouldCloseDocument;
}

- (void) setShouldCloseDocument: (BOOL) flag {
    _shouldCloseDocument = flag;
}

- owner {
    return _owner;
}

- (NSString *) windowNibName {
    return _nibName;
}

- (NSString *) windowNibPath {
    if (_nibPath != nil)
        return _nibPath;
    else {
        NSString *name = [self windowNibName];
        NSBundle *bundle = [NSBundle bundleForClass: [_owner class]];
        NSString *path = [bundle pathForResource: name ofType: @"nib"];

        if (path == nil)
            path = [[NSBundle mainBundle] pathForResource: name ofType: @"nib"];

        return path;
    }
}

- (void) setShouldCascadeWindows: (BOOL) flag {
    _shouldCascadeWindows = flag;
}

- (BOOL) shouldCascadeWindows {
    return _shouldCascadeWindows;
}

- (void) setWindowFrameAutosaveName: (NSString *) name {
    name = [name copy];
    [_windowFrameAutosaveName release];
    _windowFrameAutosaveName = name;
}

- (NSString *) windowFrameAutosaveName {
    return _windowFrameAutosaveName;
}

- (void) synchronizeWindowTitleWithDocumentName {
    if (_document != nil && _window != nil) {
        NSString *displayName = [_document displayName];
        NSString *title = [self windowTitleForDocumentDisplayName: displayName];
        NSString *path = [_document fileName];

        [_window setTitle: title];
    }
}

- (NSString *) windowTitleForDocumentDisplayName: (NSString *) displayName {
    NSString *appName = [[[NSBundle mainBundle] infoDictionary]
            objectForKey: @"CFBundleName"];
    if (appName)
        return [NSString stringWithFormat: @"%@ - %@", displayName, appName];
    else
        return displayName;
}

@end
