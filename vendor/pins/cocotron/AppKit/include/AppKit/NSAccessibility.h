#import <AppKit/AppKitExport.h>
#import <Foundation/NSString.h>

#import <AppKit/NSAccessibilityConstants.h>
#import <AppKit/NSAccessibilityProtocols.h>

APPKIT_EXPORT void NSAccessibilityPostNotification(id element,
                                                   NSString *notification);

APPKIT_EXPORT NSString *const NSAccessibilityRoleDescription(NSString *role,
                                                             NSString *subrole);

APPKIT_EXPORT id NSAccessibilityUnignoredAncestor(id element);
APPKIT_EXPORT id NSAccessibilityUnignoredDescendant(id element);
APPKIT_EXPORT NSArray *NSAccessibilityUnignoredChildren(NSArray *originalChildren);
APPKIT_EXPORT NSArray *NSAccessibilityUnignoredChildrenForOnlyChild(id originalChild);

@interface NSObject (NSAccessibility)
- (NSArray *) accessibilityAttributeNames;
- accessibilityAttributeValue: (NSString *) attribute;

/*
 * THE 10.10 PROPERTY SPELLING of the same information. Applications set these as a matter of course
 * while building views, and every one of them was an unrecognized selector.
 */
- (NSString *) accessibilityLabel;
- (void) setAccessibilityLabel: (NSString *) label;
- (NSString *) accessibilityTitle;
- (void) setAccessibilityTitle: (NSString *) title;
- (id) accessibilityValue;
- (void) setAccessibilityValue: (id) value;
- (NSString *) accessibilityHelp;
- (void) setAccessibilityHelp: (NSString *) help;
- (NSString *) accessibilityRole;
- (void) setAccessibilityRole: (NSString *) role;
- (NSString *) accessibilityRoleDescription;
- (void) setAccessibilityRoleDescription: (NSString *) description;
- (NSString *) accessibilitySubrole;
- (void) setAccessibilitySubrole: (NSString *) subrole;
- (NSString *) accessibilityIdentifier;
- (void) setAccessibilityIdentifier: (NSString *) identifier;
- (NSArray *) accessibilityChildren;
- (void) setAccessibilityChildren: (NSArray *) children;
- (id) accessibilityParent;
- (void) setAccessibilityParent: (id) parent;
- (BOOL) isAccessibilityElement;
- (void) setAccessibilityElement: (BOOL) element;
- (BOOL) isAccessibilityEnabled;
- (void) setAccessibilityEnabled: (BOOL) enabled;
@end
