#import <AppKit/NSNib.h>
#import <AppKit/NSNibLoading.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSViewController.h>

@implementation NSViewController

@synthesize identifier = _identifier;

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
    value = [value retain];
    [_view release];
    _view = value;
}

- (void) loadView {
    NSString *name = [self nibName];
    NSBundle *bundle = [self nibBundle];

    if (name == nil) {
        // should pathForResource assert name for non-nil?
        [NSException raise: NSInvalidArgumentException
                    format: @"-[%@ %s] nibName is nil", [self class], _cmd];
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
