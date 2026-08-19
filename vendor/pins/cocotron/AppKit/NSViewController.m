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

- (NSView *) view {
    if (_view == nil)
        [self loadView];

    return _view;
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
