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

#import <AppKit/NSAlert.h>
#include <stdio.h>

#import <AppKit/NSApplication.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/ucontext.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <objc/runtime.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#import <AppKit/NSColorPanel.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSDockTile.h>
#import <AppKit/NSDocumentController.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSImageView.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSModalSessionX.h>
#import <AppKit/NSNibLoading.h>
#import <AppKit/NSPageLayout.h>
#import <AppKit/NSPanel.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSScreen.h>
#import <AppKit/NSSheetContext.h>
#import <AppKit/NSSpellChecker.h>
#import <AppKit/NSSystemInfoPanel.h>
#import <AppKit/NSWindow-Private.h>
#import <AppKit/NSWorkspace.h>
#import <CoreGraphics/CGWindow.h>
#import <objc/message.h>
#import <pthread.h>

const NSRunLoopMode NSModalPanelRunLoopMode = @"NSModalPanelRunLoopMode";
const NSRunLoopMode NSEventTrackingRunLoopMode = @"NSEventTrackingRunLoopMode";

const NSNotificationName NSApplicationWillFinishLaunchingNotification =
        @"NSApplicationWillFinishLaunchingNotification";
const NSNotificationName NSApplicationDidFinishLaunchingNotification =
        @"NSApplicationDidFinishLaunchingNotification";

const NSNotificationName NSApplicationWillBecomeActiveNotification =
        @"NSApplicationWillBecomeActiveNotification";
const NSNotificationName NSApplicationDidBecomeActiveNotification =
        @"NSApplicationDidBecomeActiveNotification";
const NSNotificationName NSApplicationWillResignActiveNotification =
        @"NSApplicationWillResignActiveNotification";
const NSNotificationName NSApplicationDidResignActiveNotification =
        @"NSApplicationDidResignActiveNotification";

const NSNotificationName NSApplicationWillUpdateNotification =
        @"NSApplicationWillUpdateNotification";
const NSNotificationName NSApplicationDidUpdateNotification =
        @"NSApplicationDidUpdateNotification";

const NSNotificationName NSApplicationWillHideNotification =
        @"NSApplicationWillHideNotification";
const NSNotificationName NSApplicationDidHideNotification =
        @"NSApplicationDidHideNotification";
const NSNotificationName NSApplicationWillUnhideNotification =
        @"NSApplicationWillUnhideNotification";
const NSNotificationName NSApplicationDidUnhideNotification =
        @"NSApplicationDidUnhideNotification";

const NSNotificationName NSApplicationWillTerminateNotification =
        @"NSApplicationWillTerminateNotification";

const NSNotificationName NSApplicationDidChangeScreenParametersNotification =
        @"NSApplicationDidChangeScreenParametersNotification";

NSString *const NSApplicationLaunchIsDefaultLaunchKey =
        @"NSApplicationLaunchIsDefaultLaunchKey";
NSString *const NSApplicationLaunchUserNotificationKey =
        @"NSApplicationLaunchUserNotificationKey";

/*
 * THE VERSION APPLICATIONS BRANCH ON, and 10.12 is still deliberate. What changed is WHY.
 *
 * It used to be pinned here because anything newer than 10.15 made MoneyMoney build its wizard with
 * Auto Layout and die on +constraintWithItem: before drawing. There is a real NSLayoutConstraint
 * now (in Foundation, where the class already lived), and +[NSScreen screensHaveSeparateSpaces]
 * answers as well, so 2022 no longer throws: zero unrecognized selectors, zero uncaught exceptions,
 * and the menu titles gain the two characters the 35 point metric buys them.
 *
 * THE MENU BAR WAS OUR BUG AND IS FIXED. At 2022 the window is created with
 * NSWindowStyleMaskFullSizeContentView, so it calls -setStyleMask:, and that method used to hide the
 * menu view of every window it touched. It now hides only a window that no longer qualifies, and the
 * menu bar draws at 2022 exactly as it does at 1504.
 *
 * THE TOOLBAR IS THE ONE THAT IS STILL EMPTY, and it is the application taking a path this AppKit
 * does not draw, silently rather than by raising. Both versions build the same three
 * NSToolbarItemView frames, but at 1504 the icon strip draws as 41 NSSegmentedControl cells and 42
 * MMPopUpButton cells, and at 2022 neither class ever draws once. The item views are there and empty.
 *
 * So: raise this when the Big Sur toolbar is drawn, not before, and check the capture rather than the
 * exception count.
 */
const NSAppKitVersion NSAppKitVersionNumber = 1504; // macOS 10.12 Sierra

NSApplication *NSApp = nil;

@interface NSDocumentController (forward)
- (void) _updateRecentDocumentsMenu;
@end

@interface NSMenu (private)
- (NSMenu *) _menuWithName: (NSString *) name;
@end

@interface NSDockTile (private)
- initWithOwner: owner;
@end


/* WHICH DEATH IS IT. MoneyMoney ends silently mid nib load with no -terminate: and no core. A dylib
 * destructor runs on a normal exit() and never on a fatal signal, so this one line separates a
 * deliberate exit from a kill. */
/* A CRASH STACK THAT WORKS. The injected crash reporter faults inside itself, so a process that
 * dies in app code says nothing at all and no core is written. backtrace and dladdr do work in the
 * guest, so a plain fatal signal handler prints the one thing that was missing: where it died. */
/* ASK THE KERNEL WHETHER A PAGE IS THERE. Reading the stack of a process that has just hit its
 * guard page faults again and takes the report with it. A write of the page to /dev/null answers
 * the same question with EFAULT instead of a signal, so nothing in the scan can crash. */
static int _CiderProbeFd = -1;

static int _CiderPageReadable(const void *page)
{
    char resident = 0;

    /* mincore ANSWERS WITHOUT READING. A write to /dev/null looked like a safe probe and is not:
     * the buffer crosses the syscall emulation, which touches it, so probing an unmapped page with
     * it faults exactly like the read it was meant to replace. mincore only consults the mapping
     * tables and returns ENOMEM when there is nothing there. */
    return mincore((void *) page, 4096, &resident) == 0;
}

/*
 * WHICH LIBRARY, when dladdr says nothing.
 *
 * dladdr only knows Mach-O images, so an unresolved program counter is evidence in itself: the
 * fault is in a HOST ELF library reached through the bridge, or in memory belonging to no image at
 * all. /proc is the host's here, so its own maps name the region.
 */
static void _CiderAppNameMapping(const void *pc)
{
    FILE *maps = fopen("/proc/self/maps", "r");
    char line[512];

    if (maps == NULL)
        return;

    while (fgets(line, sizeof(line), maps) != NULL) {
        unsigned long long low = 0, high = 0;

        if (sscanf(line, "%llx-%llx", &low, &high) != 2)
            continue;
        if ((unsigned long long) (uintptr_t) pc < low || (unsigned long long) (uintptr_t) pc >= high)
            continue;
        fprintf(stderr, "CIDER_APP mapping %s", line);
        break;
    }
    fclose(maps);
}

static void _CiderAppFatalSignal(int signo, siginfo_t *info, void *ucontextIn)
{
    void *frames[32];
    int count = backtrace(frames, 32);

    /* THE PC IS THE ANSWER, not the walk. Signal delivery hands over a fresh stack with no frame
     * chain to follow, so backtrace comes back empty here; the register state does not, and the
     * program counter in it names the instruction that faulted. */
    fprintf(stderr, "CIDER_APP fatal signal %d at address %p, depth=%d\n", signo,
            info ? info->si_addr : NULL, count);

    ucontext_t *uc = (ucontext_t *) ucontextIn;
    if (uc != NULL && uc->uc_mcontext != NULL) {
#if defined(__x86_64__)
        void *pc = (void *) (uintptr_t) uc->uc_mcontext->__ss.__rip;
#else
        void *pc = (void *) (uintptr_t) uc->uc_mcontext->__ss.__pc;
#endif
        Dl_info pcinfo;

        if (dladdr(pc, &pcinfo) != 0 && pcinfo.dli_sname != NULL)
            fprintf(stderr, "CIDER_APP faulted at %s + %ld in %s\n", pcinfo.dli_sname,
                    (long) ((char *) pc - (char *) pcinfo.dli_saddr),
                    pcinfo.dli_fname ? pcinfo.dli_fname : "?");
        else if (dladdr(pc, &pcinfo) != 0)
            fprintf(stderr, "CIDER_APP faulted at %p, offset %ld into %s\n", pc,
                    (long) ((char *) pc - (char *) pcinfo.dli_fbase),
                    pcinfo.dli_fname ? pcinfo.dli_fname : "?");
        else {
            fprintf(stderr, "CIDER_APP faulted at %p, unresolved\n", pc);
            _CiderAppNameMapping(pc);
        }

        /* HISTOGRAM THE STACK INSTEAD OF WALKING IT. The frame pointer is omitted in the code
         * that faulted, so there is no chain to follow; a stack that ran out of room is however
         * full of the cycle that filled it, so count the code addresses lying in it and the
         * repeating callers come out on top. */
#if defined(__x86_64__)
        uintptr_t sp = (uintptr_t) uc->uc_mcontext->__ss.__rsp;
#else
        uintptr_t sp = (uintptr_t) uc->uc_mcontext->__ss.__sp;
#endif
        uintptr_t scanned = 0;

        fprintf(stderr, "CIDER_APP scan starting, rsp=%p probefd=%d\n", (void *) sp, _CiderProbeFd);
        fflush(stderr);
        /* STATIC ON PURPOSE. There is no stack left to put this on, which is the very condition
         * being reported. */
        static struct {
            void *symbol;
            const char *name;
            int count;
        } seen[24];
        int distinct = 0;

        memset(seen, 0, sizeof(seen));

        for (uintptr_t slot = (sp + 7) & ~(uintptr_t) 7; scanned < (2 * 1024 * 1024); slot += 8) {
            scanned += 8;

            if ((slot & 0xFFF) < 8 || scanned == 8) {
                if (!_CiderPageReadable((const void *) (slot & ~(uintptr_t) 0xFFF))) {
                    slot = (slot | 0xFFF) - 7;
                    continue;
                }
            }

            void *candidate = *(void **) slot;
            Dl_info slotinfo;

            /* ONE CYCLE, IN ORDER. The counts say which frames repeat but not what sits between
             * them, and a caller from the application itself would be dropped by the dedup below.
             * The first few kilobytes hold a whole turn of the loop. */
            if (scanned <= (12 * 1024) && candidate != NULL && (uintptr_t) candidate > 0x1000) {
                Dl_info orderinfo;

                if (dladdr(candidate, &orderinfo) != 0 && orderinfo.dli_sname != NULL) {
                    const char *image = orderinfo.dli_fname ? strrchr(orderinfo.dli_fname, (int) 47) : NULL;

                    fprintf(stderr, "CIDER_APP   order +%lu %s [%s]\n",
                            (unsigned long) (slot - sp), orderinfo.dli_sname,
                            image ? image + 1 : "?");
                    fflush(stderr);
                }
            }

            if (candidate == NULL || (uintptr_t) candidate < 0x1000)
                continue;
            if (dladdr(candidate, &slotinfo) == 0 || slotinfo.dli_sname == NULL)
                continue;

            int found = 0;
            for (int i = 0; i < distinct; i++) {
                if (seen[i].symbol == slotinfo.dli_saddr) {
                    seen[i].count++;
                    found = 1;
                    break;
                }
            }
            if (!found && distinct < 24) {
                seen[distinct].symbol = slotinfo.dli_saddr;
                seen[distinct].name = slotinfo.dli_sname;
                seen[distinct].count = 1;
                distinct++;
                /* PRINTED THE MOMENT IT IS SEEN. Scanning a stack that has just hit its guard page
                 * can fault again, and a summary printed at the end would then be lost, so each new
                 * name goes out immediately. */
                fprintf(stderr, "CIDER_APP   found %s at +%lu\n", slotinfo.dli_sname,
                        (unsigned long) (slot - sp));
                fflush(stderr);
            }
        }

        fprintf(stderr, "CIDER_APP stack histogram over %lu bytes, %d distinct\n",
                (unsigned long) scanned, distinct);
        for (int shown = 0; shown < 12; shown++) {
            int best = -1;

            for (int i = 0; i < distinct; i++)
                if (seen[i].count > 0 && (best < 0 || seen[i].count > seen[best].count))
                    best = i;
            if (best < 0)
                break;
            fprintf(stderr, "CIDER_APP   %6d x %s\n", seen[best].count, seen[best].name);
            seen[best].count = 0;
        }
    }

    for (int i = 0; i < count; i++) {
        Dl_info info;

        if (dladdr(frames[i], &info) != 0 && info.dli_sname != NULL)
            fprintf(stderr, "CIDER_APP   #%d %s + %ld in %s\n", i, info.dli_sname,
                    (long) ((char *) frames[i] - (char *) info.dli_saddr),
                    info.dli_fname ? info.dli_fname : "?");
        else
            fprintf(stderr, "CIDER_APP   #%d %p\n", i, frames[i]);
    }
    fflush(stderr);
    _exit(128 + signo);
}

__attribute__((constructor)) static void _CiderAppAtLoad(void)
{
    if (getenv("CIDER_TRACE_APP") == NULL)
        return;

    /* THE HANDLER NEEDS A STACK OF ITS OWN. The crash being caught is the stack running out, so a
     * handler running on that same stack faults again before it can say anything useful. */
    static char alternateStack[512 * 1024];
    stack_t altstack;

    altstack.ss_sp = alternateStack;
    altstack.ss_size = sizeof(alternateStack);
    altstack.ss_flags = 0;
    sigaltstack(&altstack, NULL);

    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = _CiderAppFatalSignal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);

    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);

    _CiderProbeFd = open("/dev/null", O_WRONLY);

    fprintf(stderr, "CIDER_APP dylib constructor ran, fatal signal handlers installed\n");
    fflush(stderr);
}

__attribute__((destructor)) static void _CiderAppAtExit(void)
{
    if (getenv("CIDER_TRACE_APP") == NULL)
        return;
    fprintf(stderr, "CIDER_APP dylib destructor ran, this was a normal exit\n");
    fflush(stderr);
}

@implementation NSApplication

/*
 * The application appearance, which macOS 10.14 added and current applications set as soon as they
 * become active. LibreOffice does it from its own activation handler, so the FIRST time a window
 * is made key the process dies on an unrecognized selector, and the failure is nowhere near the
 * code that caused it.
 *
 * A FILE STATIC RATHER THAN AN IVAR, deliberately. Applications SUBCLASS NSApplication, and
 * LibreOffice is one of them: adding an ivar here would move every ivar in VCL_NSApplication,
 * which was compiled against the real layout. There is exactly one application object per process,
 * so a static holds the same information with none of that risk.
 */
static NSAppearance *_ciderApplicationAppearance = nil;

- (void) setAppearance: (NSAppearance *) appearance {
    if (_ciderApplicationAppearance == appearance)
        return;
    [appearance retain];
    [_ciderApplicationAppearance release];
    _ciderApplicationAppearance = appearance;
}

- (NSAppearance *) appearance {
    return _ciderApplicationAppearance;
}

/*
 * The EFFECTIVE appearance is what an application reads back to decide its colours, and it is
 * never nil on macOS: with nothing set it is the system one. Answering nil sends applications down
 * a path they never take on a real system.
 */
- (NSAppearance *) effectiveAppearance {
    if (_ciderApplicationAppearance != nil)
        return _ciderApplicationAppearance;
    return [NSAppearance currentAppearance];
}

+ (NSApplication *) sharedApplication {
    if (NSApp == nil) {
        [[self alloc] init]; // NSApp must be nil inside init
    }
    return NSApp;
}

+ (void) detachDrawingThread: (SEL) selector
                    toTarget: target
                  withObject: object
{
    NSUnimplementedMethod();
}

- (void) _showSplashImage {
    NSImage *image = [NSImage imageNamed: @"splash"];

    if (image != nil) {
        NSSize imageSize = [image size];
        NSRect rect = NSMakeRect(0, 0, imageSize.width, imageSize.height);
        NSWindow *splash =
                [[NSWindow alloc] initWithContentRect: rect
                                            styleMask: NSBorderlessWindowMask
                                              backing: NSBackingStoreBuffered
                                                defer: NO];
        [splash setLevel: NSFloatingWindowLevel];

        NSImageView *view = [[NSImageView alloc] initWithFrame: rect];
        [view setImage: image];
        [splash setContentView: view];
        [view release];
        [splash setReleasedWhenClosed: YES];
        [splash center];
        [splash orderFront: nil];
        [splash display];
    }
}

- (void) _closeSplashImage {
    for (NSWindow *window in _windows) {
        NSView *contentView = [window contentView];

        if ([contentView isKindOfClass: [NSImageView class]])
            if ([[[(NSImageView *) contentView image] name]
                        isEqual: @"splash"]) {
                [window close];
                return;
            }
    }
}

- (instancetype) init {
    if (NSApp)
        NSAssert(!NSApp, @"NSApplication is a singleton");
    NSApp = self;
    _display = [[NSDisplay currentDisplay] retain];

    _windows = [NSMutableArray new];
    _mainMenu = nil;
    _servicesMenu = nil;
    _helpMenu = nil;

    _dockTile = [[NSDockTile alloc] initWithOwner: self];
    _modalStack = [NSMutableArray new];

    _lock = NSZoneMalloc(NULL, sizeof(pthread_mutex_t));

    CFRunLoopAddCommonMode(CFRunLoopGetCurrent(),
                           (CFStringRef) NSModalPanelRunLoopMode);
    CFRunLoopAddCommonMode(CFRunLoopGetCurrent(),
                           (CFStringRef) NSEventTrackingRunLoopMode);

    pthread_mutex_init(_lock, NULL);

    [self _showSplashImage];

    return NSApp;
}

- (NSGraphicsContext *) context {
    NSUnimplementedMethod();
    return nil;
}

- delegate {
    return _delegate;
}

- (NSArray *) windows {
    return _windows;
}

- (NSWindow *) windowWithWindowNumber: (NSInteger) number {
    for (NSWindow *window in _windows) {
        if ([window windowNumber] == number) {
            return window;
        }
    }
    return nil;
}

- (NSMenu *) mainMenu {
    return _mainMenu;
}

- (NSMenu *) menu {
    return [self mainMenu];
}

- (NSMenu *) windowsMenu {
    if (_windowsMenu == nil) {
        _windowsMenu = [[NSApp mainMenu] _menuWithName: @"_NSWindowsMenu"];
        NSMenuItem *lastItem = [[_windowsMenu itemArray] lastObject];
        if (_windowsMenu && ![lastItem isSeparatorItem])
            [_windowsMenu addItem: [NSMenuItem separatorItem]];
    }

    return _windowsMenu;
}

- (NSWindow *) mainWindow {
    return _mainWindow;
}

- (void) _setMainWindow: (NSWindow *) window {
    _mainWindow = window;
}

- (NSWindow *) keyWindow {
    return _keyWindow;
}

- (void) _setKeyWindow: (NSWindow *) window {
    _keyWindow = window;
}

- (NSImage *) applicationIconImage {
    return _applicationIconImage;
}

- (BOOL) isActiveExcludingWindow: (NSWindow *) exclude {
    int count = [_windows count];

    while (--count >= 0) {
        NSWindow *check = [_windows objectAtIndex: count];

        if (check == exclude)
            continue;

        if ([check _isActive])
            return YES;
    }

    return NO;
}

/*
 * AN APPLICATION IS ACTIVE BECAUSE IT WAS LAUNCHED, not because it already has a window.
 *
 * isActive was derived purely from the windows: active meant "some window of mine is active". That
 * is a deadlock for any application that waits to become active before building its FIRST window,
 * because with no windows there is nothing to be active. On macOS the activation comes from outside
 * the process entirely, at launch, and applicationDidBecomeActive: is where a great many
 * applications open what they show.
 *
 * A FILE STATIC RATHER THAN AN IVAR, for the same reason the appearance is one: applications
 * SUBCLASS NSApplication, and adding an ivar here would move every ivar in a subclass compiled
 * against the real layout.
 */
static BOOL _ciderApplicationActive = NO;

/* Set when a window CLOSES, which is the event macOS attaches this question to. Registration is not
 * enough: an application builds windows during launch and shows them a moment later, and asking
 * before any of them has been shown answers "no visible windows" for a perfectly healthy start. */
static BOOL _ciderApplicationWindowClosed = NO;

- (BOOL) isActive {
    return _ciderApplicationActive || [self isActiveExcludingWindow: nil];
}

- (BOOL) isHidden {
    return _isHidden;
}

- (BOOL) isRunning {
    return _isRunning;
}

- (NSWindow *) makeWindowsPerform: (SEL) selector inOrder: (BOOL) inOrder {
    NSUnimplementedMethod();
    return nil;
}

- (void) miniaturizeAll: sender {
    int count = [_windows count];

    while (--count >= 0)
        [[_windows objectAtIndex: count] miniaturize: sender];
}

- (NSArray *) orderedDocuments {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *orderedWindows = [self orderedWindows];

    for (NSWindow *checkWindow in orderedWindows) {
        NSDocument *checkDocument = [[checkWindow windowController] document];

        if (checkDocument != nil)
            [result addObject: checkDocument];
    }

    return result;
}

- (NSArray *) orderedWindows {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *numbers = [_display orderedWindowNumbers];

    for (NSNumber *number in numbers) {
        NSWindow *window = [self windowWithWindowNumber: [number integerValue]];

        if (window != nil && ![window isKindOfClass: [NSPanel class]])
            [result addObject: window];
    }

    return result;
}

- (void) preventWindowOrdering {
    NSUnimplementedMethod();
}

- (void) unregisterDelegate {
    if ([_delegate respondsToSelector: @selector
                   (applicationWillFinishLaunching:)]) {
        [[NSNotificationCenter defaultCenter]
                removeObserver: _delegate
                          name: NSApplicationWillFinishLaunchingNotification
                        object: self];
    }
    if ([_delegate respondsToSelector: @selector
                   (applicationDidFinishLaunching:)]) {
        [[NSNotificationCenter defaultCenter]
                removeObserver: _delegate
                          name: NSApplicationDidFinishLaunchingNotification
                        object: self];
    }
    if ([_delegate
                respondsToSelector: @selector(applicationDidBecomeActive:)]) {
        [[NSNotificationCenter defaultCenter]
                removeObserver: _delegate
                          name: NSApplicationDidBecomeActiveNotification
                        object: self];
    }
    if ([_delegate respondsToSelector: @selector(applicationWillTerminate:)]) {
        [[NSNotificationCenter defaultCenter]
                removeObserver: _delegate
                          name: NSApplicationWillTerminateNotification
                        object: self];
    }
}

- (void) registerDelegate {
    if ([_delegate respondsToSelector: @selector
                   (applicationWillFinishLaunching:)]) {
        [[NSNotificationCenter defaultCenter]
                addObserver: _delegate
                   selector: @selector(applicationWillFinishLaunching:)
                       name: NSApplicationWillFinishLaunchingNotification
                     object: self];
    }
    if ([_delegate respondsToSelector: @selector
                   (applicationDidFinishLaunching:)]) {
        [[NSNotificationCenter defaultCenter]
                addObserver: _delegate
                   selector: @selector(applicationDidFinishLaunching:)
                       name: NSApplicationDidFinishLaunchingNotification
                     object: self];
    }
    if ([_delegate
                respondsToSelector: @selector(applicationDidBecomeActive:)]) {
        [[NSNotificationCenter defaultCenter]
                addObserver: _delegate
                   selector: @selector(applicationDidBecomeActive:)
                       name: NSApplicationDidBecomeActiveNotification
                     object: self];
    }
    if ([_delegate respondsToSelector: @selector(applicationWillTerminate:)]) {
        [[NSNotificationCenter defaultCenter]
                addObserver: _delegate
                   selector: @selector(applicationWillTerminate:)
                       name: NSApplicationWillTerminateNotification
                     object: self];
    }
}

- (void) setDelegate: delegate {
    if (delegate != _delegate) {
        [self unregisterDelegate];
        _delegate = delegate;
        [self registerDelegate];
    }
}

- (void) setMainMenu: (NSMenu *) menu {
    int i, count = [_windows count];

    if (getenv("CIDER_TRACE_MENU") != NULL && getenv("CIDER_TRACE_MENU")[0] != '\0') {
        NSMutableString *titles = [NSMutableString string];

        for (NSMenuItem *item in [menu itemArray]) {
            [titles appendFormat: @"[%@ sub=%d] ", [item title],
                                  (int) ([item submenu] != nil)];
        }
        NSLog(@"CIDER_MAINMENU set items=%ld windows=%d titles=%@",
              (long) [[menu itemArray] count], count, titles);
    }

    [_mainMenu autorelease];
    _mainMenu = [menu retain];

    for (i = 0; i < count; i++) {
        NSWindow *window = [_windows objectAtIndex: i];

        if (![window isKindOfClass: [NSPanel class]])
            [window setMenu: _mainMenu];
    }
}

- (void) setMenu: (NSMenu *) menu {
    [self setMainMenu: menu];
}

/*
 * WHETHER THE NEXT LAUNCH SHOULD RESTORE STATE, which an application asks NSApp and this had not.
 *
 * iTerm2 sends it to the application object and dies on the unrecognized selector, with the process
 * ending there. NO is the answer a fresh start wants and it is the safe one: restoring state that
 * was never saved is the failure mode with consequences.
 *
 * IT CANNOT MASK AN APPLICATION OF ITS OWN. Every caller subclasses NSApplication, so an
 * implementation in the subclass wins over this one; this only answers when nothing else does.
 */
- (BOOL) shouldRestoreStateOnNextLaunch {
    return NO;
}

- (void) setShouldRestoreStateOnNextLaunch: (BOOL) value {
}

- (void) setApplicationIconImage: (NSImage *) image {
    image = [image retain];
    [_applicationIconImage release];
    _applicationIconImage = image;

    [image setName: NSImageNameApplicationIcon];
}

- (NSApplicationActivationPolicy) activationPolicy {
    // TODO: Implement
    return NSApplicationActivationPolicyRegular;
}

- (BOOL) setActivationPolicy: (NSApplicationActivationPolicy) activationPolicy {
    // TODO: Implement
    return NO;
}

- (void) setWindowsMenu: (NSMenu *) menu {
    [_windowsMenu autorelease];
    _windowsMenu = [menu retain];
}

- (void) addWindowsItem: (NSWindow *) window
                  title: (NSString *) title
               filename: (BOOL) isFilename
{
    NSMenuItem *item;

    if ([[self windowsMenu]
                indexOfItemWithTarget: window
                            andAction: @selector(makeKeyAndOrderFront:)] != -1)
        return;

    if (isFilename)
        title = [NSString
                stringWithFormat: @"%@  --  %@", [title lastPathComponent],
                                  [title stringByDeletingLastPathComponent]];

    item = [[[NSMenuItem alloc] initWithTitle: title
                                       action: @selector(makeKeyAndOrderFront:)
                                keyEquivalent: @""] autorelease];
    [item setTarget: window];

    [[self windowsMenu] addItem: item];
}

- (void) changeWindowsItem: (NSWindow *) window
                     title: (NSString *) title
                  filename: (BOOL) isFilename
{

    if ([title length] == 0) {
        // Windows with no name aren't in the Windows menu
        [self removeWindowsItem: window];
    } else {
        int itemIndex = [[self windowsMenu]
                indexOfItemWithTarget: window
                            andAction: @selector(makeKeyAndOrderFront:)];

        if (itemIndex != -1) {
            NSMenuItem *item = [[self windowsMenu] itemAtIndex: itemIndex];

            if (isFilename)
                title = [NSString
                        stringWithFormat:
                                @"%@  --  %@", [title lastPathComponent],
                                [title stringByDeletingLastPathComponent]];

            [item setTitle: title];
            [[self windowsMenu] itemChanged: item];
        } else
            [self addWindowsItem: window title: title filename: isFilename];
    }
}

- (void) removeWindowsItem: (NSWindow *) window {
    int itemIndex = [[self windowsMenu]
            indexOfItemWithTarget: window
                        andAction: @selector(makeKeyAndOrderFront:)];

    if (itemIndex != -1) {
        [[self windowsMenu] removeItemAtIndex: itemIndex];

        if ([[[[self windowsMenu] itemArray] lastObject] isSeparatorItem]) {
            [[self windowsMenu]
                    removeItem: [[[self windowsMenu] itemArray] lastObject]];
        }
    }
}

- (void) updateWindowsItem: (NSWindow *) window {
#if 0
    NSUnimplementedMethod();
#else
    NSMenu *menu = [self windowsMenu];
    int itemIndex = [[self windowsMenu]
            indexOfItemWithTarget: window
                        andAction: @selector(makeKeyAndOrderFront:)];

    if (itemIndex != -1) {
        NSMenuItem *item = [menu itemAtIndex: itemIndex];
    }
#endif
}

- (BOOL) openFiles {
    BOOL opened = NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    id nsOpen = [defaults objectForKey: @"NSOpen"];
    NSArray *openFiles = nil;

    if ([nsOpen isKindOfClass: [NSString class]] && [nsOpen length]) {
        openFiles = [NSArray arrayWithObject: nsOpen];
    } else if ([nsOpen isKindOfClass: [NSArray class]]) {
        openFiles = nsOpen;
    }

    if ([openFiles count] == 0) {
        return NO;
    }

    if ([openFiles count] == 1 &&
        [_delegate respondsToSelector: @selector(application:openFile:)]) {
        opened = [_delegate application: self openFile: [openFiles lastObject]];
    } else if ([_delegate respondsToSelector: @selector(application:
                                                          openFiles:)]) {
        [_delegate application: self openFiles: openFiles];
        opened = YES;
    } else {
        id target = _delegate;
        if (![_delegate respondsToSelector: @selector(application:openFile:)]) {
            target = [NSDocumentController sharedDocumentController];
        }
        for (NSString *aFile in openFiles) {
            opened |= [target application: self openFile: aFile];
        }
    }
    [defaults removeObjectForKey: @"NSOpen"];

    return opened;
}

- (void) finishLaunching {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    BOOL needsUntitled = YES;

    NS_DURING [[NSNotificationCenter defaultCenter]
            postNotificationName: NSApplicationWillFinishLaunchingNotification
                          object: self];
    NS_HANDLER [self reportException: localException];
    NS_ENDHANDLER

    // Load the application icon if we have one
    NSString *iconName = [[[NSBundle mainBundle] infoDictionary]
            objectForKey: @"CFBundleIconFile"];
    if (iconName) {
        iconName = [iconName stringByAppendingPathExtension: @"icns"];
        NSImage *image = [NSImage imageNamed: iconName];
        [self setApplicationIconImage: image];
    }

    // Give us a first event
    [NSTimer scheduledTimerWithTimeInterval: 0.1
                                     target: nil
                                   selector: NULL
                                   userInfo: nil
                                    repeats: NO];

    [self _closeSplashImage];

    NSDocumentController *controller = nil;
    id types = [[[NSBundle mainBundle] infoDictionary]
            objectForKey: @"CFBundleDocumentTypes"];
    if ([types count] > 0)
        controller = [NSDocumentController sharedDocumentController];

    if ([self openFiles]) {
        needsUntitled = NO;
    }

    BOOL askedShould = NO, answeredShould = NO, askedOpen = NO, answeredOpen = NO;

    if (needsUntitled && _delegate &&
        [_delegate respondsToSelector: @selector
                   (applicationShouldOpenUntitledFile:)]) {
        askedShould = YES;
        answeredShould = [_delegate applicationShouldOpenUntitledFile: self];
        needsUntitled = answeredShould;
    }

    if (needsUntitled && _delegate &&
        [_delegate
                respondsToSelector: @selector(applicationOpenUntitledFile:)]) {
        askedOpen = YES;
        answeredOpen = [_delegate applicationOpenUntitledFile: self];
        needsUntitled = !answeredOpen;
    }

    if (needsUntitled && controller &&
        ![controller documentClassForType: [controller defaultType]]) {
        needsUntitled = NO;
    }

    /* WHOSE DECISION IT WAS THAT NO DOCUMENT OPENS. An application that shows nothing after
     * launching has either declined an untitled document, intending to open its own window, or was
     * never asked because it registered no document types. Those want opposite work and the
     * absence of a window looks identical either way. */
    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB untitled needed=%d controller=%s types=%lu openfiles=%lu"
                " should=%s open=%s\n",
                (int) needsUntitled, (controller != nil) ? "yes" : "no",
                (unsigned long) [types count], (unsigned long) [[self openFiles] count],
                askedShould ? (answeredShould ? "YES" : "NO") : "notasked",
                askedOpen ? (answeredOpen ? "YES" : "NO") : "notasked");
        fflush(stderr);
    }

    if (needsUntitled && controller) {
        [controller _updateRecentDocumentsMenu];
        [controller newDocument: self];
    }

    NS_DURING [[NSNotificationCenter defaultCenter]
            postNotificationName: NSApplicationDidFinishLaunchingNotification
                          object: self];
    NS_HANDLER [self reportException: localException];
    NS_ENDHANDLER

    /* AND THEN IT IS ACTIVE, which is what launching an application does. Sent after
     * DidFinishLaunching, in the order macOS uses. */
    [self _ciderBecomeActive];

            [pool release];
}

- (void) _checkForReleasedWindows {
    int count = [_windows count];

    while (--count >= 0) {
        NSWindow *check = [_windows objectAtIndex: count];

        if ([check retainCount] == 1) {

            // Use the setters here - give a chance to the observer to notice
            // something happened
            if (check == _keyWindow) {
                [self _setKeyWindow: nil];
            }

            if (check == _mainWindow) {
                [self _setMainWindow: nil];
            }

            [_windows removeObjectAtIndex: count];
        }
    }
}

/*
 * QUITTING BECAUSE THE LAST WINDOW CLOSED IS A DELEGATE'S DECISION, AND ONLY AFTER ONE HAS CLOSED.
 *
 * This ran on every pass of the run loop and terminated the application whenever no window was
 * visible, which includes the whole of startup before the first window exists. An application that
 * takes a moment to open its window was therefore asked to quit immediately and repeatedly:
 * iTerm2 reached the loop with no window and left with status 0 on the first pass, and iA Writer
 * was asked on every pass for as long as it ran and only survived because its delegate says no.
 *
 * macOS asks applicationShouldTerminateAfterLastWindowClosed:, the answer is NO when the delegate
 * does not implement it, and the question is only ever asked after a window has CLOSED. Both halves
 * matter: the default keeps an application alive while it is still starting, and the ordering keeps
 * it alive if it never opens a window at all.
 */
/* Called by -[NSWindow close], which is the only thing that should arm the check below. */
- (void) _ciderWindowDidClose {
    _ciderApplicationWindowClosed = YES;
}

- (void) _checkForTerminate {
    if (!_ciderApplicationWindowClosed) {
        return;
    }

    int count = [_windows count];

    while (--count >= 0) {
        NSWindow *check = [_windows objectAtIndex: count];

        if (![check isKindOfClass: [NSPanel class]] && [check isVisible]) {
            return;
        }
    }

    if (_delegate == nil ||
        ![_delegate respondsToSelector: @selector(applicationShouldTerminateAfterLastWindowClosed:)] ||
        ![_delegate applicationShouldTerminateAfterLastWindowClosed: self]) {
        return;
    }

    [self terminate: self];
}

- (void) _checkForAppActivation {
#if 1
    if ([self isActive])
        [_windows makeObjectsPerformSelector: @selector(_showForActivation)];
    else {
        [_windows makeObjectsPerformSelector: @selector(_hideForDeactivation)];
    }
#endif
}

/*
 * FINISH LAUNCHING ONCE, WHOEVER ASKS FIRST.
 *
 * -finishLaunching is what posts NSApplicationDidFinishLaunching, and that notification is where
 * most applications open their first window. Cocotron called it from -run and nowhere else, which
 * assumes every application reaches the loop through -run.
 *
 * iTerm2 does not. Its principal class is iTermApplication and it pumps events with its OWN loop:
 * measured, with entry probes on all three, NSApplicationMain is never entered, -[NSApplication run]
 * is never entered, and nextEventMatchingMask is called repeatedly. So the delegate was never told
 * the application had launched, and an application that opens its window from that notification
 * opens nothing at all, forever, while looking perfectly healthy.
 *
 * Asking here instead means the first event pump finishes launching, whichever loop is doing the
 * pumping. -run still asks first when it is used, so nothing changes for an ordinary application.
 */
static BOOL cider_did_finish_launching = NO;

static void cider_ensure_finish_launching(NSApplication *self)
{
    if (cider_did_finish_launching) {
        return;
    }
    cider_did_finish_launching = YES;

    /* BEFORE AND AFTER, not just after. A log placed only after the call cannot be told apart from
     * a call that was never made, and finishLaunching is exactly the kind of thing that can fail to
     * return: it posts notifications, and anything a delegate does in response happens inside it. */
    /* fprintf RATHER THAN NSLog, and this is not a style choice. Every probe in this hunt has been
     * silent, in a process that plainly runs: NSLog is a Foundation call with its own setup behind
     * it, and a probe that depends on the thing being investigated cannot report on it. stderr
     * needs nothing. */
    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB finishLaunching entering delegate=%s\n",
                ([self delegate] != nil) ? object_getClassName([self delegate]) : "nil");
        fflush(stderr);
    }
    @autoreleasepool {
        [self finishLaunching];
    }
    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB finishLaunching done delegate=%s windows=%lu\n",
                ([self delegate] != nil) ? object_getClassName([self delegate]) : "nil",
                (unsigned long) [[self windows] count]);
        fflush(stderr);
    }
}

/* WHO ENDED THE APPLICATION. MoneyMoney exits cleanly, status 0, right after windowDidLoad, with no
 * crash and no exception, so either something called -terminate: or -stop:, or the run loop simply
 * came back. These three lines tell which, and -stop: and -terminate: print who asked. */
static void _CiderAppNote(const char *what, id sender)
{
    if (getenv("CIDER_TRACE_APP") == NULL)
        return;
    fprintf(stderr, "CIDER_APP %s sender=%s\n", what,
            sender ? class_getName([sender class]) : "(nil)");
    fflush(stderr);
}

- (void) run {
    _CiderAppNote("run enter", nil);
    NSAutoreleasePool *pool;

    /* WHO STARTED THE LOOP, and whether the delegate was ever told. An application that pumps
     * events without going through NSApplicationMain got here some other way, and the two things
     * worth knowing are that it arrived and whether finishLaunching -- which is what posts
     * NSApplicationDidFinishLaunching, the notification most applications open their first window
     * from -- has run yet. */
    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB NSApplication run\n");
        fflush(stderr);
        NSLog(@"CIDER_NIB NSApplication run delegate=%s didlaunch=%d",
              ([self delegate] != nil) ? object_getClassName([self delegate]) : "nil",
              (int) cider_did_finish_launching);
    }

    _isRunning = YES;

    cider_ensure_finish_launching(self);

    do {
        pool = [NSAutoreleasePool new];
        NSEvent *event;

        event = [self nextEventMatchingMask: NSAnyEventMask
                                  untilDate: [NSDate distantFuture]
                                     inMode: NSDefaultRunLoopMode
                                    dequeue: YES];

        NS_DURING [self sendEvent: event];

        NS_HANDLER [self reportException: localException];
        NS_ENDHANDLER

                [self _checkForReleasedWindows];
        [self _checkForTerminate];

        [pool release];
    } while (_isRunning);

    /* THE LOOP ENDED, which means main is about to return and the process is about to leave with
     * status 0. Said out loud because a clean exit is otherwise indistinguishable from a process
     * that was killed quietly. */
    fprintf(stderr, "CIDER_APP run loop ended, _isRunning=%d\n", (int) _isRunning);
    fflush(stderr);
}

- (BOOL) _performKeyEquivalent: (NSEvent *) event {
    if (event.charactersIgnoringModifiers.length > 0) {
        /* order is important here, views may want to handle the event before
         * menu*/

        if ([[self keyWindow] performKeyEquivalent: event])
            return YES;
        if ([[self mainWindow] performKeyEquivalent: event])
            return YES;
        if ([[self mainMenu] performKeyEquivalent: event])
            return YES;
    }
    // documentation says to send it to all windows
    return NO;
}

- (void) sendEvent: (NSEvent *) event {
    if ([event type] == NSKeyDown) {
        unsigned modifierFlags = [event modifierFlags];

        if (getenv("CIDER_TRACE_KEYEQ") != NULL) {
            fprintf(stderr, "CIDER_KEYEQ sendEvent chars=%s mods=%#x keyWindow=%s mainMenu=%s\n",
                    [[event charactersIgnoringModifiers] UTF8String] ?: "(none)", modifierFlags,
                    [self keyWindow] != nil ? "yes" : "no",
                    [self mainMenu] != nil ? "yes" : "no");
        }
        if (modifierFlags & (NSCommandKeyMask | NSAlternateKeyMask))
            if ([self _performKeyEquivalent: event])
                return;
    }

    [[event window] sendEvent: event];
}

// This method is used by NSWindow
- (void) _displayAllWindowsIfNeeded {
    [[NSApp windows] makeObjectsPerformSelector: @selector(displayIfNeeded)];
}

- (NSEvent *) nextEventMatchingMask: (NSEventMask) mask
                          untilDate: (NSDate *) untilDate
                             inMode: (NSRunLoopMode) mode
                            dequeue: (BOOL) dequeue
{
    NSEvent *nextEvent = nil;

    cider_ensure_finish_launching(self);

    do {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];

        NS_DURING [NSClassFromString(@"Win32RunningCopyPipe")
                performSelector: @selector(createRunningCopyPipe)];

        /*
         * THE HOUSEKEEPING IS PER PASS, AND A POLL IS NOT A PASS.
         *
         * These four sweep every window the application has, and two of them send a selector to
         * each: with LibreOffice that is forty windows, and its own methods take the VCL yield
         * mutex on the way past. That is affordable when an event loop comes round sixty times a
         * second. It is not affordable when the application POLLS: AquaSalInstance::AnyInput asks
         * for an event with a date already in the past, nineteen thousand times a second while a
         * file picker is open, and the sweep then costs eight hundred thousand message sends a
         * second to discover nothing.
         *
         * A poll that arrives within two milliseconds of the last sweep skips it. A caller that
         * asked to WAIT never skips, so nothing that depends on the sweep can be starved by more
         * than two milliseconds.
         */
        static NSTimeInterval lastSweep = 0.0;
        NSTimeInterval nowInterval = [NSDate timeIntervalSinceReferenceDate];
        BOOL polling = ([untilDate timeIntervalSinceNow] <= 0.0);

        if (!polling || (nowInterval - lastSweep) >= 0.002) {
            lastSweep = nowInterval;

            // This should happen before _makeSureIsOnAScreen so we don't reposition
            // done windows
            [self _checkForReleasedWindows];

            [[NSApp windows]
                    makeObjectsPerformSelector: @selector(_makeSureIsOnAScreen)];

            [self _checkForAppActivation];
            [self _displayAllWindowsIfNeeded];
        }

        nextEvent = [[_display nextEventMatchingMask: mask
                                           untilDate: untilDate
                                              inMode: mode
                                             dequeue: dequeue] retain];

        if ([nextEvent type] == NSAppKitSystem) {
            [nextEvent release];
            nextEvent = nil;
        }

        NS_HANDLER [self reportException: localException];
        NS_ENDHANDLER

                [pool release];
    } while (nextEvent == nil && [untilDate timeIntervalSinceNow] > 0);

    if (nextEvent != nil) {
        nextEvent = [nextEvent retain];

        pthread_mutex_lock(_lock);
        [_currentEvent release];
        _currentEvent = nextEvent;
        pthread_mutex_unlock(_lock);
    }

    return [nextEvent autorelease];
}

- (NSEvent *) currentEvent {
    /* Apps do use currentEvent from secondary threads and it doesn't crash on
     * OS X, so we need to be safe here too. */
    NSEvent *result;

    pthread_mutex_lock(_lock);
    result = [_currentEvent retain];
    pthread_mutex_unlock(_lock);

    return [result autorelease];
}

- (void) discardEventsMatchingMask: (NSEventMask) mask
                       beforeEvent: (NSEvent *) event
{
    [_display discardEventsMatchingMask: mask beforeEvent: event];
}

- (void) postEvent: (NSEvent *) event atStart: (BOOL) atStart {
    [_display postEvent: event atStart: atStart];
}

- _searchForAction: (SEL) action responder: target {
    // Search a responder chain

    while (target != nil) {

        if ([target respondsToSelector: action])
            return target;

        if ([target respondsToSelector: @selector(nextResponder)])
            target = [target nextResponder];
        else
            break;
    }

    return nil;
}

- _searchForAction: (SEL) action window: (NSWindow *) window {
    // Search a windows responder chain and window
    // The window check is done seperately from the responder chain
    // in case the responder chain is broken

    // FIXME: should a windows delegate and windowController be checked if a
    // window is found in a responder chain too ? Document based facts:
    //  An NSWindow's next responder should be the window controller
    //  An NSWindow's delegate should be the document
    // - This probably means the windowController check is duplicative, but need
    // to make the next responder is window controller

    id check = [self _searchForAction: action
                            responder: [window firstResponder]];

    if (check != nil)
        return check;

    if ([[window delegate] respondsToSelector: action])
        return [window delegate];

    if ([[window windowController] respondsToSelector: action])
        return [window windowController];

    return nil;
}

- targetForAction: (SEL) action {
    return [self targetForAction: action to: nil from: nil];
}

- targetForAction: (SEL) action to: target from: sender {
    if (target == nil) {
        target = [self _searchForAction: action window: [self keyWindow]];
        if (target)
            return target;

        if ([self mainWindow] != [self keyWindow]) {
            target = [self _searchForAction: action window: [self mainWindow]];
            if (target)
                return target;
        }
    } else {
        target = [self _searchForAction: action responder: target];
        if (target)
            return target;
    }

    NSDocumentController *documentController =
            [NSDocumentController sharedDocumentController];
    if ([[documentController currentDocument] respondsToSelector: action])
        return [documentController currentDocument];

    if ([self respondsToSelector: action])
        return self;

    if ([[self delegate] respondsToSelector: action])
        return [self delegate];

    if ([documentController respondsToSelector: action])
        return documentController;

    return nil;
}

- (BOOL) sendAction: (SEL) action to: target from: sender {
    if ([target respondsToSelector: action]) {
        [target performSelector: action withObject: sender];
        return YES;
    }

    target = [self targetForAction: action to: target from: sender];
    if (target != nil) {
        [target performSelector: action withObject: sender];
        return YES;
    }

    return NO;
}

- (BOOL) tryToPerform: (SEL) selector with: object {
    if ([self respondsToSelector: selector]) {
        [self performSelector: selector withObject: object];
        return YES;
    }

    if ([[self delegate] respondsToSelector: selector]) {
        [[self delegate] performSelector: selector withObject: object];
        return YES;
    }

    return NO;
}

- (void) setWindowsNeedUpdate: (BOOL) value {
    _windowsNeedUpdate = value;
    NSUnimplementedMethod();
}

- (void) updateWindows {
    [_windows makeObjectsPerformSelector: @selector(update)];
}

- (void) activateIgnoringOtherApps: (BOOL) flag {
    [self _ciderBecomeActive];
}

/* The pair of notifications an activation carries, posted once. */
- (void) _ciderBecomeActive {
    if (_ciderApplicationActive)
        return;
    _ciderApplicationActive = YES;

    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB application became active\n");
        fflush(stderr);
    }

    NS_DURING [[NSNotificationCenter defaultCenter]
            postNotificationName: NSApplicationWillBecomeActiveNotification
                          object: self];
    NS_HANDLER [self reportException: localException];
    NS_ENDHANDLER

    NS_DURING [[NSNotificationCenter defaultCenter]
            postNotificationName: NSApplicationDidBecomeActiveNotification
                          object: self];
    NS_HANDLER [self reportException: localException];
    NS_ENDHANDLER
}

- (void) deactivate {
    NSUnimplementedMethod();
}

- (NSWindow *) modalWindow {
    return [[_modalStack lastObject] modalWindow];
}

- (NSModalSession) beginModalSessionForWindow: (NSWindow *) window {
    NSModalSessionX *session = [NSModalSessionX sessionWithWindow: window];

    [_modalStack addObject: session];

    [window _hideMenuViewIfNeeded];
    if (![window isVisible]) {
        [window center];
    }
    [window makeKeyAndOrderFront: self];

    return session;
}

- (NSModalResponse) runModalSession: (NSModalSession) session {
    while ([session stopCode] == NSRunContinuesResponse) {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        NSEvent *event = [self nextEventMatchingMask: NSAnyEventMask
                                           untilDate: [NSDate date]
                                              inMode: NSModalPanelRunLoopMode
                                             dequeue: YES];

        if (event == nil) {
            [pool release];
            break;
        }

        NSWindow *window = [event window];

        // In theory this could get weird, but all we want is the ESC-cancel
        // keybinding, afaik NSApp doesn't respond to any other
        // doCommandBySelectors...
        if ([event type] == NSKeyDown && window == [session modalWindow])
            [self interpretKeyEvents: @[ event ]];

        if (window == [session modalWindow] || [window worksWhenModal])
            [self sendEvent: event];
        else if ([event type] == NSLeftMouseDown)
            [[session modalWindow] makeKeyAndOrderFront: self];
        else {
            // We need to preserve some events which are not processed in the
            // modal loop and requeue them. The particular case we need to
            // handle is mouse down. run modal. then actually receive the mouse
            // up when the modal is done. So we know this works in Cocoa, save
            // the mouse up here. We don't want to save mouse moved or such.
            // There is kind of adhoc, probably a better way to do it, find out
            // which combinations should work (e.g. mouse enter, do we get mouse
            // exit?)
            if ([[session unprocessedEvents] count] == 0) {
                switch ([event type]) {
                case NSLeftMouseUp:
                case NSRightMouseUp:
                    [session addUnprocessedEvent: event];
                    break;
                default:
                    // don't save
                    break;
                }
            }
        }
        [pool release];
    }

    return [session stopCode];
}

- (void) endModalSession: (NSModalSession) session {
    if (session != [_modalStack lastObject])
        [NSException
                 raise: NSInvalidArgumentException
                format: @"-[%@ %s] modal session %@ is not the current one %@",
                        [self class], sel_getName(_cmd), session,
                        [_modalStack lastObject]];

    for (NSEvent *requeue in [session unprocessedEvents]) {
        [self postEvent: requeue atStart: YES];
    }

    [[session modalWindow] _showMenuViewIfNeeded];
    [_modalStack removeLastObject];
}

- (void) stopModalWithCode: (NSModalResponse) code {
    // This should silently ignore any attempt to end a session when there is
    // none.
    [[_modalStack lastObject] stopModalWithCode: code];
}

- (void) _mainThreadRunModalForWindow: (NSMutableDictionary *) values {
    NSWindow *window = [values objectForKey: @"NSWindow"];

    NSModalSession session = [self beginModalSessionForWindow: window];
    NSModalResponse result;

    while ((result = [NSApp runModalSession: session]) ==
           NSRunContinuesResponse)
        ;
    [self endModalSession: session];

    [values setObject: [NSNumber numberWithInteger: result] forKey: @"result"];
}

- (NSModalResponse) runModalForWindow: (NSWindow *) window {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    values[@"NSWindow"] = window;

    [self performSelectorOnMainThread: @selector(_mainThreadRunModalForWindow:)
                           withObject: values
                        waitUntilDone: YES
                                modes: @[
                                    NSDefaultRunLoopMode,
                                    NSModalPanelRunLoopMode
                                ]];

    NSNumber *result = values[@"result"];

    return [result integerValue];
}

- (void) stopModal {
    [self stopModalWithCode: NSRunStoppedResponse];
}

- (void) abortModal {
    [self stopModalWithCode: NSRunAbortedResponse];
}

// cancel modal windows
- (void) cancel: sender {
    if ([self modalWindow] != nil)
        [self abortModal];
}

- (void) beginSheet: (NSWindow *) sheet
        modalForWindow: (NSWindow *) window
         modalDelegate: (id) modalDelegate
        didEndSelector: (SEL) didEndSelector
           contextInfo: (void *) contextInfo
{
    NSSheetContext *context =
            [NSSheetContext sheetContextWithSheet: sheet
                                    modalDelegate: modalDelegate
                                   didEndSelector: didEndSelector
                                      contextInfo: contextInfo
                                            frame: [sheet frame]];

    if ([[NSUserDefaults standardUserDefaults]
                boolForKey: @"NSRunAllSheetsAsModalPanel"]) {
        // Center the sheet on the window.
        NSPoint windowCenter =
                NSMakePoint(NSMidX([window frame]), NSMidY([window frame]));
        NSPoint sheetCenter =
                NSMakePoint(NSMidX([sheet frame]), NSMidY([sheet frame]));
        NSPoint origin = [sheet frame].origin;
        origin.x += windowCenter.x - sheetCenter.x;
        origin.y += windowCenter.y - sheetCenter.y;
        [sheet setFrameOrigin: origin];
        [sheet _setSheetContext: context];
        [sheet setLevel: NSModalPanelWindowLevel];
        NSModalSession session = [self beginModalSessionForWindow: sheet];
        [context setModalSession: session];

        while ([NSApp runModalSession: session] == NSRunContinuesResponse) {
            [[NSRunLoop currentRunLoop] runMode: NSModalPanelRunLoopMode
                                     beforeDate: [NSDate distantFuture]];
        }
        [self endModalSession: session];
    } else {
        [window _attachSheetContextOrderFrontAndAnimate: context];
    }
}

- (void) endSheet: (NSWindow *) sheet returnCode: (NSModalResponse) returnCode {
    if ([[NSUserDefaults standardUserDefaults]
                boolForKey: @"NSRunAllSheetsAsModalPanel"]) {
        NSSheetContext *context = [sheet _sheetContext];
        NSModalSession session = [context modalSession];
        [session stopModalWithCode: NSRunStoppedResponse];

        IMP function = [[context modalDelegate]
                methodForSelector: [context didEndSelector]];
        if (function != NULL) {
            ((void (*)(id, SEL, id, NSInteger, void *)) function)(
                     [context modalDelegate], [context didEndSelector], sheet,
                     returnCode, [context contextInfo]);
        }
        [sheet _setSheetContext: nil];
    } else {
        NSUInteger count = [_windows count];

        while (--count >= 0) {
            NSWindow *check = _windows[count];
            NSSheetContext *context = [check _sheetContext];
            IMP function;

            if ([context sheet] == sheet) {
                [[context retain] autorelease];

                [check _detachSheetContextAnimateAndOrderOut];

                function = [[context modalDelegate]
                        methodForSelector: [context didEndSelector]];
                if (function != NULL)
                    ((void (*)(id, SEL, id, NSInteger, void *)) function)(
                             [context modalDelegate], [context didEndSelector],
                             sheet, returnCode, [context contextInfo]);

                return;
            }
        }
    }
}

- (void) endSheet: (NSWindow *) sheet {
    [self endSheet: sheet returnCode: 0];
}

- (void) reportException: (NSException *) exception {
    NSLog(@"NSApplication got exception: %@", exception);

    /*
     * WHERE IT CAME FROM, not only what it said.
     *
     * This is where an application's exceptions come to die: AppKit catches them per event, so the
     * feature that raised one silently does nothing and the log holds a single line with no caller
     * in it. "Cannot set nil objects nor nil keys" from MoneyMoney's add-account window is the case
     * that asked for this, and the message names neither the dictionary nor the code that filled it.
     *
     * The exception's own callStackSymbols is the RAISE point, which is what matters, and it
     * survives the unwind because NSException captures it when it is thrown.
     */
    const char *watch = getenv("CIDER_TRACE_EXCEPTIONS");

    if (watch != NULL && watch[0] != (char) 0) {
        NSArray *symbols = [exception callStackSymbols];

        if ([symbols count] > 0) {
            NSUInteger i, count = [symbols count];

            for (i = 0; i < count && i < 20; i++)
                fprintf(stderr, "CIDER_EXC   %s\n",
                        [[symbols objectAtIndex: i] UTF8String] ?: "?");
        } else {
            /* An exception thrown before anyone captured a stack still tells us where it is being
             * REPORTED, which is one frame short of useless. */
            void *frames[24];
            int count = backtrace(frames, 24);
            char **names = backtrace_symbols(frames, count);

            for (int i = 1; i < count && names != NULL; i++)
                fprintf(stderr, "CIDER_EXC   (report) %s\n", names[i]);
            if (names != NULL)
                free(names);
        }
        fflush(stderr);
    }
}

- (void) _attentionTimer: (NSTimer *) timer {
    [_windows makeObjectsPerformSelector: @selector(_flashWindow)];
}

- (int) requestUserAttention: (NSRequestUserAttentionType) attentionType {
    [_attentionTimer invalidate];
    _attentionTimer =
            [NSTimer scheduledTimerWithTimeInterval: 3
                                             target: self
                                           selector: @selector(_attentionTimer:)
                                           userInfo: nil
                                            repeats: YES];

    return 0;
}

- (void) cancelUserAttentionRequest: (int) requestNumber {
    NSUnimplementedMethod();
}

- (void) runPageLayout: sender {
    [[NSPageLayout pageLayout] runModal];
}

- (void) orderFrontColorPanel: (id) sender {
    [[NSColorPanel sharedColorPanel] orderFront: sender];
}

- (void) orderFrontCharacterPalette: sender {
    NSUnimplementedMethod();
}

- (void) hide: (id) sender {
    // Deactivates the application and hides all windows.
    if (_isHidden) {
        return;
    }
    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSApplicationWillHideNotification
                          object: self];
    // Do no use orderOut here ist causes the application to quit if no window
    // is visible.
    [_windows
            makeObjectsPerformSelector: @selector(_forcedHideForDeactivation)];
    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSApplicationDidHideNotification
                          object: self];
    _isHidden = YES;
}

- (void) hideOtherApplications: sender {
    NSUnimplementedMethod();
}

- (void) unhide: sender {

    if (_isHidden) {
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationWillUnhideNotification
                              object: self];
        [_windows makeObjectsPerformSelector: @selector
                  (_showForActivation)]; // only shows previously hidden windows
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationDidUnhideNotification
                              object: self];
    }
    _isHidden = NO;
    //[self activateIgnoringOtherApps:NO]
}

- (void) unhideAllApplications: sender {
    NSUnimplementedMethod();
}

- (void) unhideWithoutActivation {
    if (_isHidden) {

        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationWillUnhideNotification
                              object: self];
        [_windows makeObjectsPerformSelector: @selector
                  (_showForActivation)]; // only shows previously hidden windows
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationDidUnhideNotification
                              object: self];
    }
    _isHidden = NO;
}

- (void) stop: sender {
    _CiderAppNote("stop", sender);
    /*
     * THE OTHER WAY OUT, and the one left after terminate: was ruled out.
     *
     * -stop: clears _isRunning, -run falls out of its loop, main returns and the process leaves
     * with status 0 and no crash. That is exactly the shape of the Swift Publisher exit a few
     * seconds after Choose, and terminate: was proven not to be the path: its trace is in the
     * deployed binary and never printed.
     */
    {
        void *frames[24];
        int count = backtrace(frames, 24);

        fprintf(stderr, "CIDER_APP stop: sender=%s modal=%d\n",
                sender != nil ? object_getClassName(sender) : "(nil)",
                (int) ([_modalStack lastObject] != nil));
        for (int i = 1; i < count; i++) {
            Dl_info info;

            if (dladdr(frames[i], &info) != 0 && info.dli_sname != NULL) {
                const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;

                fprintf(stderr, "CIDER_APP   %-26s %s\n",
                        image ? image + 1 : "?", info.dli_sname);
            }
        }
        fflush(stderr);
    }

    if ([_modalStack lastObject] != nil) {
        [self stopModal];
        return;
    }

    _isRunning = NO;
}

- (void) terminate: sender {
    _CiderAppNote("terminate", sender);
    /*
     * WHO ASKED TO QUIT, always, not behind a gate.
     *
     * Swift Publisher exits cleanly with status 0 a few seconds after Choose, in the middle of
     * building its inspector, with no crash and no signal. A clean exit from an application that
     * was in the middle of opening a document is a DECISION, and the only paths to status 0 here
     * are this method and the exit(0) in replyToApplicationShouldTerminate: below it. The count of
     * calls says nothing; the frames name the caller.
     *
     * Not gated on an env var because a process that is about to leave has one chance to say so,
     * and this costs a dozen lines once per lifetime.
     */
    {
        void *frames[24];
        int count = backtrace(frames, 24);

        fprintf(stderr, "CIDER_APP terminate: sender=%s\n",
                sender != nil ? object_getClassName(sender) : "(nil)");
        for (int i = 1; i < count; i++) {
            Dl_info info;

            if (dladdr(frames[i], &info) != 0 && info.dli_sname != NULL) {
                const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;

                fprintf(stderr, "CIDER_APP   %-26s %s\n",
                        image ? image + 1 : "?", info.dli_sname);
            }
        }
        fflush(stderr);
    }

    [[NSDocumentController sharedDocumentController]
            closeAllDocumentsWithDelegate: self
                      didCloseAllSelector: @selector
                      (_documentController:didCloseAll:contextInfo:)
                              contextInfo: NULL];
}

- (void) _documentController: (NSDocumentController *) docController
                 didCloseAll: (BOOL) didCloseAll
                 contextInfo: (void *) info
{
    // callback method for terminate:
    if (didCloseAll) {
        if ([_delegate
                    respondsToSelector: @selector(applicationShouldTerminate:)])
            [self replyToApplicationShouldTerminate:
                            [_delegate applicationShouldTerminate: self] ==
                            NSTerminateNow];
        else
            [self replyToApplicationShouldTerminate: YES];
    }
}

- (void) replyToApplicationShouldTerminate: (BOOL) terminate {
    fprintf(stderr, "CIDER_APP replyToApplicationShouldTerminate: %d\n", (int) terminate);
    fflush(stderr);

    if (terminate == YES) {
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationWillTerminateNotification
                              object: self];

        [NSClassFromString(@"Win32RunningCopyPipe")
                performSelector: @selector(invalidateRunningCopyPipe)];

        exit(0);
    }
}

- (void) replyToOpenOrPrint: (NSApplicationDelegateReply) reply {
    NSUnimplementedMethod();
}

- (void) arrangeInFront: sender {
#define CASCADE_DELTA 20 // ? isn't there a call for this?
    NSMutableArray *visibleWindows = [NSMutableArray new];
    NSRect rect = [[[NSScreen screens] objectAtIndex: 0] frame], winRect;
    NSArray *windowsItems = [[self windowsMenu] itemArray];
    int i, count = [windowsItems count];

    for (i = 0; i < count; ++i) {
        id target = [[windowsItems objectAtIndex: i] target];

        if ([target isKindOfClass: [NSWindow class]])
            [visibleWindows addObject: target];
    }

    count = [visibleWindows count];
    if (count == 0)
        return;

    // find screen center.
    // subtract window w,h /2
    winRect = [[visibleWindows objectAtIndex: 0] frame];
    rect.origin.x = (rect.size.width / 2) - (winRect.size.width / 2);
    rect.origin.x -= count * CASCADE_DELTA / 2;
    rect.origin.x = floor(rect.origin.x);

    rect.origin.y = (rect.size.height / 2) + (winRect.size.height / 2);
    rect.origin.y += count * CASCADE_DELTA / 2;
    rect.origin.y = floor(rect.origin.y);

    for (i = 0; i < count; ++i) {
        [[visibleWindows objectAtIndex: i] setFrameTopLeftPoint: rect.origin];
        [[visibleWindows objectAtIndex: i] orderFront: nil];

        rect.origin.x += CASCADE_DELTA;
        rect.origin.y -= CASCADE_DELTA;
    }
}

// This is a method removed from official headers in 10.4,
// but it still exists and is widely used.
- (void) setAppleMenu: (NSMenu *) menu {
    NSUnimplementedMethod();
}

- (NSMenu *) servicesMenu {
    return [[NSApp mainMenu] _menuWithName: @"_NSServicesMenu"];
}

- (void) setServicesMenu: (NSMenu *) menu {
    [_servicesMenu autorelease];

    if ([menu _name] == nil) {
        [menu _setMenuName: @"_NSServicesMenu"];
    }

    _servicesMenu = [menu retain];
}

- (NSMenu *) helpMenu {
    return _helpMenu;
}

- (void) setHelpMenu: (NSMenu *) menu {
    [_helpMenu autorelease];

    [_helpMenu _setMenuName: @""];
    [menu _setMenuName: @"_NSHelpMenu"];

    _helpMenu = [menu retain];
}

- servicesProvider {
    return nil;
}

- (void) setServicesProvider: provider {
}

- (void) registerServicesMenuSendTypes: (NSArray *) sendTypes
                           returnTypes: (NSArray *) returnTypes
{
    // tiredofthesewarnings NSUnsupportedMethod();
}

- validRequestorForSendType: (NSString *) sendType
                 returnType: (NSString *) returnType
{
    NSUnimplementedMethod();
    return nil;
}

- (void) orderFrontStandardAboutPanel: sender {
    [self orderFrontStandardAboutPanelWithOptions: nil];
}

- (void) orderFrontStandardAboutPanelWithOptions: (NSDictionary *) options {
    NSSystemInfoPanel *standardAboutPanel =
            [[NSSystemInfoPanel standardAboutPanel] retain];
    [standardAboutPanel showInfoPanel: self withOptions: options];
}

- (void) activateContextHelpMode: sender {
    NSUnimplementedMethod();
}

- (void) showGuessPanel: sender {
    [[[NSSpellChecker sharedSpellChecker] spellingPanel]
            makeKeyAndOrderFront: self];
}

- (void) showHelp: sender {
    NSString *helpBookFolder = [[[NSBundle mainBundle] infoDictionary]
            objectForKey: @"CFBundleHelpBookFolder"];
    if (helpBookFolder != nil) {
        BOOL isDir;
        NSString *folder =
                [[NSBundle mainBundle] pathForResource: helpBookFolder
                                                ofType: nil];
        if (folder != nil &&
            [[NSFileManager defaultManager] fileExistsAtPath: folder
                                                 isDirectory: &isDir] &&
            isDir) {
            NSBundle *helpBundle = [NSBundle bundleWithPath: folder];
            if (helpBundle) {
                NSString *helpBookName = [[helpBundle infoDictionary]
                        objectForKey: @"CFBundleHelpTOCFile"];
                if (helpBookName != nil) {
                    NSString *helpFilePath =
                            [helpBundle pathForResource: helpBookName
                                                 ofType: nil];
                    if (helpFilePath) {
                        if ([[NSWorkspace sharedWorkspace]
                                           openFile: helpFilePath
                                    withApplication: @"Help Viewer"] == YES) {
                            return;
                        }
                    }
                }
                // Perhaps there's an index.html file that'll be usable?
                NSString *helpFilePath = [helpBundle pathForResource: @"index"
                                                              ofType: @"html"];
                if (helpFilePath) {
                    if ([[NSWorkspace sharedWorkspace]
                                       openFile: helpFilePath
                                withApplication: @"Help Viewer"] == YES) {
                        return;
                    }
                }
            }
        }
    }

    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText: NSLocalizedStringFromTableInBundle(
                                   @"Help", nil,
                                   [NSBundle bundleForClass: [NSApplication
                                                                     class]],
                                   @"Help alert title")];
    [alert setInformativeText:
                    [NSString stringWithFormat:
                                      NSLocalizedStringFromTableInBundle(
                                              @"Help isn't available for %@.",
                                              nil,
                                              [NSBundle bundleForClass:
                                                                [NSApplication
                                                                        class]],
                                              @""),
                                      processName]];
    [alert runModal];
    [alert release];
}

- (NSDockTile *) dockTile {
    return _dockTile;
}

- (void) doCommandBySelector: (SEL) selector {
    if ([_delegate respondsToSelector: selector])
        [_delegate performSelector: selector withObject: nil];
    else
        [super doCommandBySelector: selector];
}

- (void) _addWindow: (NSWindow *) window {
    [_windows addObject: window];

    /*
     * WHO HAS THE MENU, traced because the obvious theory about the empty menu bar was wrong.
     *
     * setMainMenu: does run before any window exists, items=9 windows=0, so a window created
     * afterwards looked like it could never receive the menu. It receives it anyway: this trace
     * reports windowMenu=9 the moment the window is added. The menu is installed and the menu bar
     * still draws one item, so the fault is in DRAWING it, not in installing it.
     */
    if (getenv("CIDER_TRACE_MENU") != NULL && getenv("CIDER_TRACE_MENU")[0] != '\0') {
        NSLog(@"CIDER_MAINMENU addWindow class=%s panel=%d mainMenu=%ld windowMenu=%ld",
              object_getClassName(window), (int) [window isKindOfClass: [NSPanel class]],
              _mainMenu ? (long) [[_mainMenu itemArray] count] : -1L,
              [window menu] ? (long) [[[window menu] itemArray] count] : -1L);
    }

}

- (void) _windowWillBecomeActive: (NSWindow *) window {
    [_attentionTimer invalidate];
    _attentionTimer = nil;

    if (![self isActive]) {
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationWillBecomeActiveNotification
                              object: self];
    }
}

- (void) _windowDidBecomeActive: (NSWindow *) window {
    if (![self isActiveExcludingWindow: window]) {
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationDidBecomeActiveNotification
                              object: self];
    }
}

- (void) _windowWillBecomeDeactive: (NSWindow *) window {
    if (![self isActiveExcludingWindow: window]) {
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationWillResignActiveNotification
                              object: self];
    }
}

- (void) _windowDidBecomeDeactive: (NSWindow *) window {
    if (![self isActive]) {

        // Exposed menus are running tight event tracking loops and would remain
        // visible when the app deactivates (making the UI less than community
        // minded) - unfortunately because they're in these tracking loops
        // they're waiting on events and even though they could receive the
        // notification sent here they can't deal with it until an event is
        // received to let them proceed. This special event type was added to
        // help them get unstuck and remove the menu on deactivation
        NSEvent *appKitEvent =
                [NSEvent otherEventWithType: NSAppKitDefined
                                   location: NSZeroPoint
                              modifierFlags: 0
                                  timestamp: 0
                               windowNumber: 0
                                    context: nil
                                    subtype: NSApplicationDeactivated
                                      data1: 0
                                      data2: 0];
        [self postEvent: appKitEvent atStart: YES];

        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSApplicationDidResignActiveNotification
                              object: self];
    }
}

// private method called when the application is reopened
- (void) _reopen {
    BOOL doReopen = YES;
    if ([_delegate respondsToSelector: @selector
                   (applicationShouldHandleReopen:hasVisibleWindows:)])
        doReopen = [_delegate applicationShouldHandleReopen: self
                                          hasVisibleWindows: !_isHidden];
    if (!doReopen)
        return;
    if (_isHidden)
        [self unhide: nil];
}

+ (void) load {
    // Xcode expects this method to exist for some reason?
}

- (NSApplicationPresentationOptions) currentSystemPresentationOptions {
    return [self presentationOptions];
}

- (NSApplicationPresentationOptions) presentationOptions {
    return _presentationOptions;
}

- (void) setPresentationOptions: (NSApplicationPresentationOptions) options {
    if (options & NSApplicationPresentationAutoHideDock &&
        options & NSApplicationPresentationHideDock) {
        [NSException raise: NSInvalidArgumentException
                    format: @"Both NSApplicationPresentationHideDock and "
                            @"NSApplicationPresentationAutoHideDock were "
                            @"specified; only one is allowed"];
    }

    if (options & NSApplicationPresentationHideMenuBar &&
        (options & NSApplicationPresentationHideDock) == 0) {
        [NSException raise: NSInvalidArgumentException
                    format: @"NSApplicationPresentationHideMenuBar specified "
                            @"without NSApplicationPresentationHideDock"];
    }

    if (options & NSApplicationPresentationAutoHideMenuBar &&
        options & NSApplicationPresentationHideMenuBar) {
        [NSException raise: NSInvalidArgumentException
                    format: @"Both NSApplicationPresentationHideMenuBar and "
                            @"NSApplicationPresentationAutoHideMenuBar were "
                            @"specified; only one is allowed"];
    }

    if ((options & NSApplicationPresentationDisableForceQuit ||
         options & NSApplicationPresentationDisableMenuBarTransparency ||
         options & NSApplicationPresentationDisableProcessSwitching ||
         options & NSApplicationPresentationDisableSessionTermination) &&
        ((options & NSApplicationPresentationHideDock) == 0 ||
         (options & NSApplicationPresentationAutoHideDock) == 0)) {
        [NSException
                 raise: NSInvalidArgumentException
                format: @"One of NSApplicationPresentationDisableForceQuit, "
                        @"NSApplicationPresentationDisableMenuBarTransparency, "
                        @"NSApplicationPresentationDisableProcessSwitching, or "
                        @"NSApplicationPresentationDisableSessionTermination "
                        @"was specified without either "
                        @"NSApplicationPresentationHideDock or "
                        @"NSApplicationPresentationAutoHideDock"];
    }
#if 0 // The behaviour exists but I couldn't reproduce it at High Sierra and
      // Mojave (need test in newer versions)
    if (
        options & NSApplicationPresentationAutoHideToolbar
        && (
            (options & NSApplicationPresentationFullScreen) == 0
            || (options & NSApplicationPresentationAutoHideMenuBar) == 0
        )
    ) {
        [NSException
                 raise: NSInvalidArgumentException
                format: @""];
    }
#endif

    _presentationOptions = options;
}

@end

/*
 * Bring Cocoa up from code that did not start as a Cocoa application.
 *
 * It exists for Carbon and for anything else with its own main(), and LibreOffice is the second
 * kind: it calls this before touching AppKit. A MISSING LAZY SYMBOL IS NOT A DEGRADED FEATURE, it
 * is an abort at first call, so the absence of this four line function ended the process with
 * "Symbol not found: _NSApplicationLoad" and nothing else.
 *
 * +sharedApplication is the whole of it: it creates the instance if there is none and returns the
 * existing one otherwise, which is exactly the documented contract of returning YES once Cocoa is
 * initialised.
 */
BOOL NSApplicationLoad(void) {
    return [NSApplication sharedApplication] != nil;
}

int NSApplicationMain(int argc, const char *argv[]) {
#ifndef DARLING
    __NSInitializeProcess(argc, argv);
#endif

    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSBundle *bundle = [NSBundle mainBundle];
    Class class = [bundle principalClass];
    NSString *nibFile = [bundle infoDictionary][@"NSMainNibFile"];

    /* THE ENTRY OF THE FUNCTION EVERY COCOA APPLICATION STARTS IN. An application that reaches the
     * run loop without a window has either loaded no nib or never come through here at all, and
     * those want completely different work; a trace further down cannot tell them apart. */
    if (getenv("CIDER_TRACE_NIB") != NULL) {
        NSLog(@"CIDER_NIB NSApplicationMain principal=%s nib=%@",
              (class != Nil) ? class_getName(class) : "nil", nibFile);
    }

#ifndef DARLING
    if (argc > 1) {
        NSMutableArray *arguments =
                [NSMutableArray arrayWithCapacity: arg c - 1];
        for (int i = 1; i < argc; i++)
            if (argv[i][0] != '-')
                [arguments addObject: [NSString stringWithUTF8String: argv[i]]];
            else if (argv[i][1] == '-' && argv[i][2] == '\0')
                break;
            else // (argv[i][0] == '-' && argv[i] != "--")
                    if (*(int64_t *) argv[i] != *(int64_t *) "-NSOpen")
                i++;

        if ((argc = [arguments count]))
            [[NSUserDefaults standardUserDefaults]
                    setObject: ((argc == 1) ? [arguments lastObject]
                                            : arguments)
                       forKey: @"NSOpen"];
    }

    [NSClassFromString(@"Win32RunningCopyPipe")
            performSelector: @selector(startRunningCopyPipe)];
#endif

    if (class == Nil)
        class = [NSApplication class];

    [class sharedApplication];

    nibFile = [nibFile stringByDeletingPathExtension];

    /* BRACKETED, because -run is never entered and the application ends with no crash, no exception
     * and status 0. Either the main nib load does not come back or something after it ends the
     * process, and only a line on each side can tell those apart. */
    _CiderAppNote("main nib load enter", nil);
    if (![NSBundle loadNibNamed: nibFile owner: NSApp])
        NSLog(@"Unable to load main nib file %@", nibFile);
    _CiderAppNote("main nib load leave", nil);

    [pool release];

    _CiderAppNote("calling run", nil);
    [NSApp run];
    _CiderAppNote("run returned", nil);

    return 0;
}

void NSUpdateDynamicServices(void) {
    NSUnimplementedFunction();
}

BOOL NSPerformService(NSString *itemName, NSPasteboard *pasteboard) {
    NSUnimplementedFunction();
    return NO;
}
