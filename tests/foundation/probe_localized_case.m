/* DOES A CASE CONVERSION SURVIVE BEING GIVEN A LOCALE?
 *
 * -[NSString lowercaseString] passes nil and is used everywhere. The 10.11 localized forms pass
 * [NSLocale currentLocale], and -lowercaseStringWithLocale: hands that straight to
 * CFStringLowercase as a CFLocaleRef. If an NSLocale is not what that function expects, the
 * difference between the two is a cast, and the cast is the whole defect.
 *
 * This matters because iTerm2 takes a SIGSEGV the moment those methods exist and its Preferences
 * nib finishes decoding (docs/iterm2-preferences-gap.md), with ERR 0x7: a user mode WRITE to a
 * page that is present and not writable.
 *
 * EVERY CASE CARRIES ITS OWN CONTROL: the same conversion with nil, which is the path that already
 * works. If the nil form passes and the locale form does not, the locale argument is the defect
 * and not the conversion.
 *
 * Prints and always exits 0, EXCEPT that a crash here is the finding. Each step announces itself
 * BEFORE doing the work, so the last line printed names what killed it.
 */
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSLocale.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>

#include <stdio.h>
#include <string.h>

static int gChecks = 0;
static int gBad = 0;

static void checkStr(const char *what, NSString *got, const char *want) {
	const char *g = (got != nil) ? [got UTF8String] : "(nil)";
	int ok = (g != NULL && strcmp(g, want) == 0);

	gChecks++;
	if (!ok) gBad++;
	printf("PROBE %-46s got=%-12s want=%-12s %s\n", what, g ?: "(null)", want, ok ? "ok" : "MISMATCH");
	fflush(stdout);
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *mixed = @"MiXeD";

	printf("PROBE step: currentLocale\n");
	fflush(stdout);
	{
		NSLocale *cur = [NSLocale currentLocale];

		printf("PROBE currentLocale = %s\n", cur != nil ? object_getClassName(cur) : "(nil)");
		fflush(stdout);

		/* CONTROL FIRST, the path every application already takes. */
		printf("PROBE step: lowercaseString (nil locale)\n");
		fflush(stdout);
		checkStr("CONTROL lowercaseString", [mixed lowercaseString], "mixed");

		printf("PROBE step: lowercaseStringWithLocale nil\n");
		fflush(stdout);
		checkStr("CONTROL lowercaseStringWithLocale:nil",
		         [mixed lowercaseStringWithLocale:nil], "mixed");

		/* THE SUSPECT. Same conversion, a real NSLocale handed over as a CFLocaleRef. */
		printf("PROBE step: lowercaseStringWithLocale currentLocale\n");
		fflush(stdout);
		checkStr("lowercaseStringWithLocale:currentLocale",
		         [mixed lowercaseStringWithLocale:cur], "mixed");

		printf("PROBE step: uppercaseStringWithLocale currentLocale\n");
		fflush(stdout);
		checkStr("uppercaseStringWithLocale:currentLocale",
		         [mixed uppercaseStringWithLocale:cur], "MIXED");

		printf("PROBE step: capitalizedStringWithLocale currentLocale\n");
		fflush(stdout);
		checkStr("capitalizedStringWithLocale:currentLocale",
		         [mixed capitalizedStringWithLocale:cur], "Mixed");
	}

	printf("PROBE %d checks, %d mismatched\n", gChecks, gBad);
	fflush(stdout);
	[pool release];
	return 0;
}
