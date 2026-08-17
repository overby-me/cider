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
+ (NSSharingService *) sharingServiceNamed: (NSSharingServiceName) serviceName
{
    return nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end

@implementation NSSharingServicePicker

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
