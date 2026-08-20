/*
 * What does a bundle answer when asked which languages it has?
 *
 * MoneyMoney's preferences window has a Language pop-up that draws its chevrons and no title at
 * all, and its cell reports title=(null), so either the menu is empty or nothing is selected. The
 * application builds that menu in its own MMLanguagePopUpButton, and the only input it can have is
 * the bundle: MoneyMoney.app carries de.lproj and en.lproj and no CFBundleLocalizations key, so
 * -[NSBundle localizations] has to find them by looking.
 *
 * -[NSBundle localizations] forwards straight to CFBundleCopyBundleLocalizations, so this asks BOTH
 * and prints them side by side: if they disagree the gap is in Foundation, and if they agree and are
 * empty it is in CoreFoundation.
 *
 * WITH A KNOWN NEGATIVE IN THE SAME RUN, because "answers nothing" and "was never asked" look
 * identical from one result. Contents/ is a directory inside a bundle and not a bundle itself, so an
 * empty answer there is the CORRECT one, and seeing it proves the probe can tell the two apart.
 */
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <stdio.h>

static void describe(const char *what, NSString *path) {
    NSBundle *bundle = [NSBundle bundleWithPath: path];

    if (bundle == nil) {
        printf("CIDER_LOC %s: no bundle at %s\n", what, [path UTF8String]);
        return;
    }

    NSArray *fromFoundation = [bundle localizations];

    /* A SEPARATE CFBundle from the same path rather than the one inside NSBundle, so the two answers
     * are genuinely independent and a private accessor is not needed. */
    CFBundleRef cf = CFBundleCreate(NULL, (CFURLRef) [NSURL fileURLWithPath: path]);
    CFArrayRef fromCF = cf != NULL ? CFBundleCopyBundleLocalizations(cf) : NULL;

    printf("CIDER_LOC %s: NSBundle localizations = %s\n", what,
           [[fromFoundation description] UTF8String] ?: "(nil)");
    printf("CIDER_LOC %s: CFBundleCopyBundleLocalizations = %s\n", what,
           fromCF != NULL ? [[(NSArray *) fromCF description] UTF8String] : "(NULL)");
    printf("CIDER_LOC %s: preferred = %s, development = %s\n", what,
           [[[bundle preferredLocalizations] description] UTF8String] ?: "(nil)",
           [[bundle developmentLocalization] UTF8String] ?: "(nil)");

    if (fromCF != NULL)
        CFRelease(fromCF);
    if (cf != NULL)
        CFRelease(cf);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);

    @autoreleasepool {
        NSString *app = argc > 1 ? [NSString stringWithUTF8String: argv[1]]
                                 : @"/Applications/MoneyMoney.app";

        describe("the application bundle", app);
        describe("a DIRECTORY that is not a bundle, the control",
                 [app stringByAppendingPathComponent: @"Contents"]);

        /* And what is actually on disk, so the answer above can be compared with the truth. */
        NSString *resources = [app stringByAppendingPathComponent: @"Contents/Resources"];
        NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: resources
                                                                            error: NULL];
        NSMutableArray *lproj = [NSMutableArray array];

        for (NSString *name in names)
            if ([name hasSuffix: @".lproj"])
                [lproj addObject: name];

        printf("CIDER_LOC on disk: %s\n", [[lproj description] UTF8String]);
    }
    return 0;
}
