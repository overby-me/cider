#include <string.h>
#import <AppKit/NSNib.h>
#import <AppKit/NSNibLoading.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSViewController.h>
#import <objc/runtime.h>

@implementation NSViewController

@synthesize identifier = _identifier;

/*
 * NEW HAS TO REACH THE DESIGNATED INITIALISER. AppKit documents -init on a view controller as
 * initWithNibName:nil bundle:nil, and a subclass that builds its view in code overrides that one
 * method, because it is the only one every other initialiser funnels through. Without this, an
 * ordinary [MyViewController new] runs NSObject's -init, the subclass override never executes, and
 * the controller comes up with no view at all.
 *
 * That is not a theoretical tidiness point. Swift Publisher creates its document container that
 * way: the override installs a real NSSplitView subclass as the controller's view, and the window
 * then adds the page-preview strip and the canvas scroll view to it as panes, both with no
 * autoresizing mask, because a split view sizes its own subviews. Skipping the override left them
 * in the empty NSView that loadView hands back for a nib-less controller, which lays nothing out,
 * so the canvas scroll view stayed at zero by zero for the life of the window.
 */
- init {
    return [self initWithNibName: nil bundle: nil];
}

- initWithNibName: (NSString *) name bundle: (NSBundle *) bundle {
    _nibName = [name copy];
    _nibBundle = [bundle retain];
    return self;
}

- initWithCoder: (NSCoder *) coder {
    if ([coder allowsKeyedCoding]) {
        _nibName = [[coder decodeObjectForKey: @"NSNibName"] copy];
        _title = [[coder decodeObjectForKey: @"NSTitle"] copy];
        NSString *bundleIdentifier =
                [coder decodeObjectForKey: @"NSNibBundleIdentifier"];
        if (bundleIdentifier != nil)
            _nibBundle = [NSBundle bundleWithIdentifier: bundleIdentifier];
    }

    return self;
}

- (void) dealloc {
    [_identifier release];

    [super dealloc];
}

- (NSString *) nibName {
    return _nibName;
}

- (NSBundle *) nibBundle {
    return _nibBundle;
}

/* Asking must not BUILD the view, which is the whole point of the question: a caller uses it to
 * avoid forcing a load it is not ready for. iA Writer raised on it while building its toolbar. */
- (BOOL) isViewLoaded {
    return _view != nil;
}

- (NSView *) view {
    if (_view == nil)
        [self loadView];

    [self _ciderSendViewDidLoadIfNeeded];

    return _view;
}

/*
 * THE LIFECYCLE NOTHING HERE HAS EVER SENT.
 *
 * AppKit calls -viewDidLoad once, after the view is loaded, and it is where a controller does the
 * setup its nib cannot: installing child controllers, wiring data sources, pushing a first screen.
 * None of it existed here, and iA Writer implements the method on THIRTY SIX classes, so that much
 * of the application never ran. The appearance pair is the same story on a smaller scale.
 */
- (void) viewDidLoad {
}

- (void) viewWillAppear {
}

- (void) viewDidAppear {
}

- (void) viewWillDisappear {
}

- (void) viewDidDisappear {
}

/*
 * -viewDidLoad ON, the appearance pair OFF, and the split is measured rather than cautious.
 *
 * AppKit sends -viewDidLoad once after the view loads and it is where a controller does the setup
 * its nib cannot. Nothing here ever sent it, and 36 classes in iA Writer implement it, so that much
 * of the application had never run. It now fires for 31 controllers there and the window is
 * unchanged, so it is on.
 *
 * The appearance pair is a different story: with viewWillAppear and viewDidAppear as well, iA
 * Writer runs further, past two selectors this port was missing, and then QUITS three seconds in, 2
 * runs of 2. Losing the window is worse than not running that setup, so it waits for whoever finds
 * what the application decides there.
 *
 * CIDER_VC_LIFECYCLE=0 turns everything off, =all adds the appearance pair back.
 */
static int CiderViewControllerLifecycle(void) {
    static int mode = -1;

    if (mode < 0) {
        const char *value = getenv("CIDER_VC_LIFECYCLE");

        if (value != NULL && (strcmp(value, "0") == 0 || strcmp(value, "off") == 0))
            mode = 0;
        else if (value != NULL && strcmp(value, "all") == 0)
            mode = 2;
        else
            mode = 1;
    }
    return mode;
}

- (void) _ciderSendViewDidLoadIfNeeded {
    if (CiderViewControllerLifecycle() < 1)
        return;
    if (_ciderDidSendViewDidLoad || _view == nil)
        return;

    _ciderDidSendViewDidLoad = YES;

    if (getenv("CIDER_TRACE_VIEWS") != NULL && getenv("CIDER_TRACE_VIEWS")[0] != (char) 0) {
        fprintf(stderr, "CIDER_VIEW viewDidLoad %s\n", object_getClassName(self));
        fflush(stderr);
    }

    [self viewDidLoad];
}

/* Once each way, so a view that moves between windows does not repeat the pair. */
- (void) _ciderSendAppearance: (BOOL) appearing {
    if (CiderViewControllerLifecycle() < 2)
        return;
    if (appearing == _ciderDidSendViewDidAppear)
        return;

    _ciderDidSendViewDidAppear = appearing;
    if (appearing) {
        [self viewWillAppear];
        [self viewDidAppear];
    } else {
        [self viewWillDisappear];
        [self viewDidDisappear];
    }
}

- (NSString *) title {
    return _title;
}

- representedObject {
    return _representedObject;
}

- (void) setRepresentedObject: object {
    object = [object retain];
    [_representedObject release];
    _representedObject = object;
}

- (void) setTitle: (NSString *) value {
    value = [value retain];
    [_title release];
    _title = value;
}

- (void) setView: (NSView *) value {
    /* WHICH CONTROLLER GOT WHICH VIEW, and what it inherits from. A controller named for a split
     * view whose view is a plain NSView cannot lay anything out, and the class hierarchy is the
     * only way to tell whether it IS an NSSplitViewController that we failed to give a split view,
     * or a plain NSViewController that merely has the word in its name. CIDER_TRACE_VIEWS. */
    if (getenv("CIDER_TRACE_VIEWS") != NULL) {
        Class walk = [self class];

        fprintf(stderr, "CIDER_VIEW setView controller=%s view=%s chain=", object_getClassName(self),
                value != nil ? object_getClassName(value) : "(nil)");
        while (walk != Nil) {
            fprintf(stderr, "%s%s", class_getName(walk),
                    class_getSuperclass(walk) != Nil ? " < " : "");
            walk = class_getSuperclass(walk);
        }
        fprintf(stderr, " loadViewOverridden=%d\n",
                class_getMethodImplementation([self class], @selector(loadView)) !=
                        class_getMethodImplementation([NSViewController class], @selector(loadView)));
        fflush(stderr);
    }
    value = [value retain];
    [_view release];
    _view = value;
    /* The layout pass tells the controller about its own view, and only a back pointer can say
     * which controller that is. */
    [_view _ciderSetViewController: self];
    [self _ciderSendViewDidLoadIfNeeded];
}

- (void) viewWillLayout {
}

- (void) viewDidLayout {
}

- (void) loadView {
    NSString *name = [self nibName];
    NSBundle *bundle = [self nibBundle];

    /*
     * NO NIB IS NOT AN ERROR. AppKit says so: a view controller with no nib gets a plain NSView,
     * and a controller built in code is expected either to take that view or to override this
     * method, which is what NSSplitViewController and friends do.
     *
     * Raising here instead cost Swift Publisher its document window. The application creates a
     * CCCanvasesPreviewAndDocumentSplitViewController in code, asks it for its view inside
     * -[CCMainWindowController awakeFromNib], and the exception unwound the whole nib load through
     * -[NSWindowController showWindow:], so nothing appeared and nothing said why.
     *
     * An empty view is honest: the controller has no nib, so it has no contents yet, and a caller
     * that wanted contents will have overridden loadView.
     */
    if (name == nil) {
        NSView *view = [[[NSView alloc]
                initWithFrame: NSMakeRect(0, 0, 0, 0)] autorelease];

        [self setView: view];
        return;
    }

    if (bundle == nil)
        bundle = [NSBundle mainBundle];

    NSString *path = [bundle pathForResource: name ofType: @"nib"];
    NSDictionary *nameTable = [NSDictionary dictionaryWithObject: self
                                                          forKey: NSNibOwner];

    if (path == nil)
        NSLog(@"NSViewController unable to find nib named %@, bundle=%@", name,
              bundle);

    [bundle loadNibFile: path externalNameTable: nameTable withZone: NULL];
}

- (void) discardEditing {
    NSUnimplementedMethod();
}

/*
 * NO HERE ABORTS THE CALLER, which is not what an unimplemented method should do.
 *
 * commitEditing means "were you able to commit any edit you had pending", and its callers treat NO
 * as a refusal and stop. -[NSController commitEditing] is literally
 *
 *     if ([editor commitEditing] == NO)
 *         return NO;
 *
 * and NSDocument asks its editors the same question before saving. A view controller that tracks no
 * editors at all has nothing pending, so the truthful answer is YES: there was nothing to commit and
 * committing it did not fail. Answering NO said the opposite and silently blocked saves.
 *
 * Found by auditing for the shape that cost this project a night on iTerm2 inline images, where
 * -[NSImage isValid] returned 0 and every image was skipped. NOT VERIFIED AT RUNTIME yet, because
 * no application in the queue reaches a save; it is a reasoned fix, unlike the isValid one which was
 * measured before and after.
 */
- (BOOL) commitEditing {
    return YES;
}

- (void) commitEditingWithDelegate: delegate
                 didCommitSelector: (SEL) didCommitSelector
                       contextInfo: (void *) contextInfo
{
    NSUnimplementedMethod();
}

@end

/*
 * VIEW CONTROLLER CONTAINMENT, kept outside the object.
 *
 * A subclass here is compiled against the real AppKit layout, so the children are held in a side
 * table rather than in new ivars, exactly as the responder's user activity is. What this does is the
 * bookkeeping and nothing more: it does not add the child's view to a hierarchy, because the parent
 * is what decides where that goes and every caller seen here does it itself.
 *
 * Unimplemented, addChildViewController: raised and took iA Writer with it while it assembled the
 * library window out of its controllers.
 */
@implementation NSViewController (NSViewControllerContainment)

static NSMapTable *_ciderChildren = nil;
static NSMapTable *_ciderParents = nil;

static NSMutableArray *_CiderChildrenOf(id controller, BOOL create) {
    if (_ciderChildren == nil) {
        if (!create)
            return nil;
        _ciderChildren = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                          NSObjectMapValueCallBacks, 0);
    }

    NSMutableArray *children = (NSMutableArray *) NSMapGet(_ciderChildren,
                                                           (const void *) controller);
    if (children == nil && create) {
        children = [NSMutableArray array];
        NSMapInsert(_ciderChildren, (const void *) controller, (const void *) children);
    }
    return children;
}

- (NSArray *) childViewControllers {
    NSMutableArray *children = _CiderChildrenOf(self, NO);
    return children != nil ? children : [NSArray array];
}

- (void) setChildViewControllers: (NSArray *) children {
    for (NSViewController *child in [self childViewControllers])
        [child removeFromParentViewController];
    for (NSViewController *child in children)
        [self addChildViewController: child];
}

- (void) addChildViewController: (NSViewController *) child {
    [self insertChildViewController: child atIndex: [[self childViewControllers] count]];
}

- (void) insertChildViewController: (NSViewController *) child atIndex: (NSInteger) index {
    if (child == nil)
        return;

    [child removeFromParentViewController];

    NSMutableArray *children = _CiderChildrenOf(self, YES);
    if (index < 0 || index > (NSInteger) [children count])
        index = [children count];
    [children insertObject: child atIndex: index];

    if (_ciderParents == nil) {
        _ciderParents = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                                         NSNonOwnedPointerMapValueCallBacks, 0);
    }
    NSMapInsert(_ciderParents, (const void *) child, (const void *) self);
}

- (void) removeChildViewControllerAtIndex: (NSInteger) index {
    NSMutableArray *children = _CiderChildrenOf(self, NO);

    if (children == nil || index < 0 || index >= (NSInteger) [children count])
        return;

    id child = [children objectAtIndex: index];
    if (_ciderParents != nil)
        NSMapRemove(_ciderParents, (const void *) child);
    [children removeObjectAtIndex: index];
}

- (NSViewController *) parentViewController {
    if (_ciderParents == nil)
        return nil;
    return (NSViewController *) NSMapGet(_ciderParents, (const void *) self);
}

- (void) removeFromParentViewController {
    NSViewController *parent = [self parentViewController];
    if (parent == nil)
        return;

    NSMutableArray *children = _CiderChildrenOf(parent, NO);
    NSUInteger index = [children indexOfObjectIdenticalTo: self];
    if (index != NSNotFound)
        [parent removeChildViewControllerAtIndex: (NSInteger) index];
}

@end
