#import <WebKit/WebView.h>

NSString *WebElementImageKey = @"WebElementImage";
NSString *WebElementLinkLabelKey = @"WebElementLinkLabel";
NSString *WebElementLinkTargetFrameKey = @"WebElementTargetFrame";
NSString *WebElementLinkTitleKey = @"WebElementLinkTitle";
NSString *WebElementLinkURLKey = @"WebElementLinkURL";

NSString *const WebViewDidChangeSelectionNotification = @"WebViewDidChangeSelectionNotification";

/*
 * THE KEYS OF THE ACTION DICTIONARY a policy delegate is handed, which is how an application decides
 * whether to follow a link in an embedded web view. MoneyMoney reads the navigation type from it to
 * tell a bank redirect from a click, and referencing the symbol is enough to stop the process from
 * loading at all: dyld failed on _WebActionNavigationTypeKey before a window ever existed.
 */
NSString *const WebActionNavigationTypeKey = @"WebActionNavigationTypeKey";
NSString *const WebActionElementKey = @"WebActionElementKey";
NSString *const WebActionButtonKey = @"WebActionButtonKey";
NSString *const WebActionModifierFlagsKey = @"WebActionModifierFlagsKey";
NSString *const WebActionOriginalURLKey = @"WebActionOriginalURLKey";
