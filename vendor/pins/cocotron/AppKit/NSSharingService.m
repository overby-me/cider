#import <objc/runtime.h>
#import <AppKit/NSSharingService.h>

NSSharingServiceName const NSSharingServiceNameAddToIPhoto = @"com.apple.share.System.add-to-iphoto";
NSSharingServiceName const NSSharingServiceNameAddToSafariReadingList = @"com.apple.share.System.add-to-safari-reading-list";
NSSharingServiceName const NSSharingServiceNameComposeEmail = @"com.apple.share.Mail.compose";
NSSharingServiceName const NSSharingServiceNameComposeMessage = @"com.apple.messages.ShareExtension";

// The rest of the built in services an application can name. AirDrop is the one Swift Publisher 5
// references, and a name that is missing stops the process loading, whether or not the service
// could ever run here: none of them can, and the picker above answers nothing.
NSSharingServiceName const NSSharingServiceNameSendViaAirDrop = @"com.apple.share.AirDrop.send";
NSSharingServiceName const NSSharingServiceNameUseAsDesktopPicture = @"com.apple.desktop.picture";
NSSharingServiceName const NSSharingServiceNameCloudSharing = @"com.apple.CloudSharingUI.ShareService";

NSSharingServiceName const NSSharingServiceNamePostOnFacebook = @"com.apple.share.Facebook.post";
NSSharingServiceName const NSSharingServiceNamePostOnTwitter = @"com.apple.share.Twitter.post";
NSSharingServiceName const NSSharingServiceNamePostOnSinaWeibo = @"com.apple.share.SinaWeibo.post";
NSSharingServiceName const NSSharingServiceNamePostOnTencentWeibo = @"com.apple.share.TencentWeibo.post";
NSSharingServiceName const NSSharingServiceNamePostOnLinkedIn = @"com.apple.share.LinkedIn.post";

@implementation NSSharingService

/*
 * NIL IS THE TRUE ANSWER HERE, not a placeholder.
 *
 * +sharingServiceNamed: answers nil on macOS when the named service is not available, and on this
 * system none of them are: there is no Mail, no Messages, no Twitter account behind any of the
 * names declared above. So nil is what the method means, and a caller that checks it will do the
 * right thing.
 *
 * It has to be said in code rather than left to the forwarding stubs below, because those are
 * INSTANCE methods. A class method has no such fallback: the metaclass forwards nowhere, so
 * +sharingServiceNamed: raised, and Swift Publisher raised it from
 *
 *   -[CCMainWindowController shareToolbarItemMenu]
 *   -[CCMainWindowController toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:]
 *   -[NSToolbar loadDefaultItemsIfNeeded]
 *
 * which is the document window building its toolbar. The exception came out through
 * -[NSWindowController window] and the window was never finished, so a share button nobody asked
 * for took the whole document with it.
 */
/*
 * AND AN EMPTY LIST IS THE TRUE ANSWER TO "WHAT CAN SHARE THIS".
 *
 * The same shape as +sharingServiceNamed: below and written out for the same reason: a class
 * method has no forwarding fallback. iA Writer asks while building its File menu, the raise took
 * the whole menu with it, and an application whose menus are empty has no key equivalents either.
 * Nothing here can share anything, so the list is empty rather than absent.
 */
+ (NSArray *) sharingServicesForItems: (NSArray *) items {
    return [NSArray array];
}

+ (NSSharingService *) sharingServiceNamed: (NSSharingServiceName) serviceName
{
    return nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    /* The arity comes from the selector's colons and the return is an object: "v@:" claimed every
     * method took none and returned nothing, so a caller passing arguments wrote through slots the
     * invocation did not have, and one using the result read the leftover return register. */
    const char *name = sel_getName(aSelector);
    char types[256];
    size_t n = 0;

    types[n++] = '@';
    types[n++] = '@';
    types[n++] = ':';
    for (const char *p = name; *p != '\0' && n < sizeof(types) - 1; p++) {
        if (*p == ':')
            types[n++] = '@';
    }
    types[n] = '\0';
    return [NSMethodSignature signatureWithObjCTypes: types];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    id nothing = nil;
    [anInvocation setReturnValue: &nothing];
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end

@implementation NSSharingServicePicker

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    /* The arity comes from the selector's colons and the return is an object: "v@:" claimed every
     * method took none and returned nothing, so a caller passing arguments wrote through slots the
     * invocation did not have, and one using the result read the leftover return register. */
    const char *name = sel_getName(aSelector);
    char types[256];
    size_t n = 0;

    types[n++] = '@';
    types[n++] = '@';
    types[n++] = ':';
    for (const char *p = name; *p != '\0' && n < sizeof(types) - 1; p++) {
        if (*p == ':')
            types[n++] = '@';
    }
    types[n] = '\0';
    return [NSMethodSignature signatureWithObjCTypes: types];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    id nothing = nil;
    [anInvocation setReturnValue: &nothing];
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
