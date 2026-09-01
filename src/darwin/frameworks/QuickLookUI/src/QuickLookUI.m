/*
 * A FRAMEWORK THAT EXISTS SO DYLD CAN FINISH, and nothing more than iTerm2 asks of it.
 *
 * dyld refuses to start a process whose LIBRARY is missing, whatever it does or does not use from
 * it, so an application that merely links QuickLookUI cannot run without one. What iTerm2 actually
 * binds from this framework was counted with llvm-objdump across --bind, --lazy-bind and
 * --weak-bind: exactly one class, QLPreviewPanel, and no functions.
 */

#import <Foundation/Foundation.h>

/*
 * QLPreviewPanel is a shared panel on macOS and every caller asks the class, not an instance, so the
 * class object existing is most of the contract. sharedPreviewPanel answering nil is what a system
 * with no Quick Look would do, and iTerm2 checks it.
 */
@interface QLPreviewPanel : NSObject
+ (BOOL)sharedPreviewPanelExists;
+ (id)sharedPreviewPanel;
@end

@implementation QLPreviewPanel

+ (BOOL)sharedPreviewPanelExists
{
    return NO;
}

+ (id)sharedPreviewPanel
{
    return nil;
}

@end
