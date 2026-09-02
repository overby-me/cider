#import <AppKit/NSResponder.h>
#import <AppKit/NSUserInterfaceItemIdentification.h>

@class NSView;

@interface NSViewController : NSResponder <NSUserInterfaceItemIdentification> {
    NSString *_nibName;
    NSBundle *_nibBundle;
    id _representedObject;
    NSString *_title;
    NSView *_view;
    NSUserInterfaceItemIdentifier _identifier;
}

- initWithNibName: (NSString *) name bundle: (NSBundle *) bundle;

- (NSString *) nibName;
- (NSBundle *) nibBundle;

- (NSView *) view;
- (BOOL) isViewLoaded;
- (NSString *) title;
- representedObject;

- (void) setRepresentedObject: object;

- (void) setTitle: (NSString *) value;

- (void) setView: (NSView *) value;

- (void) loadView;

- (void) discardEditing;

- (BOOL) commitEditing;
- (void) commitEditingWithDelegate: delegate
                 didCommitSelector: (SEL) didCommitSelector
                       contextInfo: (void *) contextInfo;

@end

@interface NSViewController (NSViewControllerContainment)
- (NSArray *) childViewControllers;
- (void) setChildViewControllers: (NSArray *) children;
- (void) addChildViewController: (NSViewController *) child;
- (void) insertChildViewController: (NSViewController *) child atIndex: (NSInteger) index;
- (void) removeChildViewControllerAtIndex: (NSInteger) index;
- (NSViewController *) parentViewController;
- (void) removeFromParentViewController;
@end
