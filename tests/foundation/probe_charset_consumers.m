/* DO THE STANDARD CHARACTER SETS, AND THE THINGS THAT CONSUME THEM, ANSWER CORRECTLY?
 *
 * NSMutableCharacterSet was silently empty for the whole life of this port and one application
 * found it by blanking its own terminal (#247). That fix covered sets built with alloc and init.
 * It did NOT cover the STANDARD sets, +whitespaceCharacterSet and friends, nor the string and
 * scanner methods that take a set and are how almost every parser is written.
 *
 * A wrong answer here is invisible in the same way: no error, no exception, just a component list
 * of the wrong length or a trim that trims nothing. So ask directly.
 *
 * EVERY CASE CARRIES A CONTROL THAT MUST FAIL TO MATCH, because a set that contains everything
 * passes every membership assertion, and a splitter that never splits passes every "did not over
 * split" assertion. Both halves are needed.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#import <Foundation/NSArray.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSScanner.h>
#import <Foundation/NSString.h>

#include <stdio.h>

static int gChecks = 0;
static int gBad = 0;

static void checkInt(const char *what, long got, long want) {
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-56s got=%-5ld want=%-5ld %s\n", what, got, want,
	       (got == want) ? "ok" : "MISMATCH");
}

static void checkStr(const char *what, NSString *got, const char *want) {
	const char *g = (got != nil) ? [got UTF8String] : "(nil)";

	gChecks++;
	if (g == NULL || strcmp(g, want) != 0) gBad++;
	printf("PROBE %-56s got=%-12s want=%-12s %s\n", what, g ?: "(null)", want,
	       (g != NULL && strcmp(g, want) == 0) ? "ok" : "MISMATCH");
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	/* The standard sets, membership both ways. */
	{
		NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
		NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
		NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
		NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];

		checkInt("whitespaceCharacterSet has space", [ws characterIsMember:' '], 1);
		checkInt("CONTROL whitespaceCharacterSet has no x", [ws characterIsMember:'x'], 0);
		checkInt("decimalDigitCharacterSet has 7", [digits characterIsMember:'7'], 1);
		checkInt("CONTROL decimalDigitCharacterSet has no x", [digits characterIsMember:'x'], 0);
		checkInt("letterCharacterSet has a", [letters characterIsMember:'a'], 1);
		checkInt("CONTROL letterCharacterSet has no 7", [letters characterIsMember:'7'], 0);
		checkInt("newlineCharacterSet has newline", [newlines characterIsMember:'\n'], 1);
		checkInt("CONTROL newlineCharacterSet has no space", [newlines characterIsMember:' '], 0);
	}

	/* A set built from a string, which is the other common way to make one. */
	{
		NSCharacterSet *s = [NSCharacterSet characterSetWithCharactersInString:@",;"];

		checkInt("characterSetWithCharactersInString has comma", [s characterIsMember:','], 1);
		checkInt("CONTROL that set has no x", [s characterIsMember:'x'], 0);
	}

	/* The string methods that take a set. These are how parsers are written. */
	{
		NSArray *parts = [@"a,b;c" componentsSeparatedByCharactersInSet:
		                              [NSCharacterSet characterSetWithCharactersInString:@",;"]];
		NSArray *none = [@"abc" componentsSeparatedByCharactersInSet:
		                            [NSCharacterSet characterSetWithCharactersInString:@",;"]];

		checkInt("componentsSeparatedByCharactersInSet splits into 3", [parts count], 3);
		checkInt("CONTROL no separator present gives 1", [none count], 1);
		if ([parts count] == 3) checkStr("  and the middle one is b", [parts objectAtIndex:1], "b");
	}
	{
		NSString *trimmed = [@"  pad  " stringByTrimmingCharactersInSet:
		                                    [NSCharacterSet whitespaceCharacterSet]];
		NSString *untrimmed = [@"pad" stringByTrimmingCharactersInSet:
		                                  [NSCharacterSet decimalDigitCharacterSet]];

		checkStr("stringByTrimmingCharactersInSet strips the spaces", trimmed, "pad");
		checkStr("CONTROL a set that does not match trims nothing", untrimmed, "pad");
	}
	{
		NSRange r = [@"abc7" rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
		NSRange none = [@"abc" rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];

		checkInt("rangeOfCharacterFromSet finds the digit at 3", (long) r.location, 3);
		checkInt("CONTROL no digit gives NSNotFound", none.location == NSNotFound, 1);
	}

	/* NSScanner, which is the other half of every parser and is built on character sets. */
	{
		NSScanner *sc = [NSScanner scannerWithString:@"abc123"];
		NSString *letters = nil;
		NSString *digits = nil;

		[sc setCharactersToBeSkipped:nil];
		[sc scanCharactersFromSet:[NSCharacterSet letterCharacterSet] intoString:&letters];
		[sc scanCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:&digits];
		checkStr("NSScanner scanCharactersFromSet letters", letters, "abc");
		checkStr("NSScanner scanCharactersFromSet digits", digits, "123");
	}
	{
		NSScanner *sc = [NSScanner scannerWithString:@"name=value"];
		NSString *upto = nil;
		BOOL found;

		[sc setCharactersToBeSkipped:nil];
		found = [sc scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"="]
		                           intoString:&upto];
		checkInt("NSScanner scanUpToCharactersFromSet returns YES", found, 1);
		checkStr("  and stops before the equals", upto, "name");
	}

	printf("PROBE %d checks, %d mismatched\n", gChecks, gBad);
	[pool release];
	return 0;
}
