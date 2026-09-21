/* DOES DATE AND NUMBER FORMATTING ANSWER CORRECTLY?
 *
 * Nothing in the testsuite touches NSDateFormatter, and MoneyMoney, Money Manager EX and
 * LibreOffice format a date or an amount on almost every row they draw. A formatter that returns
 * nil, an empty string, or the same string for every input fails the way NSMutableCharacterSet
 * failed in #247: silently, with the application looking wrong instead of the port.
 *
 * FIXED LOCALE, FIXED TIME ZONE, FIXED EPOCH, so the expected strings are deterministic rather
 * than whatever this machine is configured for. The guest clock runs about two hours behind the
 * host, which is irrelevant here because every date comes from an explicit interval.
 *
 * THE CONTROL THAT MATTERS IS A SECOND INPUT. A formatter that returns one constant passes every
 * single-value assertion and every round trip, so each case also asserts that a DIFFERENT input
 * produces a DIFFERENT answer.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSCalendar.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDateFormatter.h>
#import <Foundation/NSLocale.h>
#import <Foundation/NSNumberFormatter.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimeZone.h>
#import <Foundation/NSValue.h>

#include <stdio.h>
#include <string.h>

static int gChecks = 0;
static int gBad = 0;

static void checkStr(const char *what, NSString *got, const char *want) {
	const char *g = (got != nil) ? [got UTF8String] : "(nil)";
	int ok = (g != NULL && strcmp(g, want) == 0);

	gChecks++;
	if (!ok) gBad++;
	printf("PROBE %-50s got=%-22s want=%-22s %s\n", what, g ?: "(null)", want, ok ? "ok" : "MISMATCH");
}

static void checkInt(const char *what, long got, long want) {
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-50s got=%-22ld want=%-22ld %s\n", what, got, want,
	       (got == want) ? "ok" : "MISMATCH");
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	/* 1000000000 is 2001-09-09 01:46:40 UTC. 1000086400 is exactly one day later. */
	NSDate *d1 = [NSDate dateWithTimeIntervalSince1970:1000000000.0];
	NSDate *d2 = [NSDate dateWithTimeIntervalSince1970:1000086400.0];

	{
		NSDateFormatter *f = [[NSDateFormatter alloc] init];

		[f setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
		[f setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];
		[f setDateFormat:@"yyyy-MM-dd"];

		checkStr("dateFormat yyyy-MM-dd", [f stringFromDate:d1], "2001-09-09");
		checkStr("CONTROL the next day differs", [f stringFromDate:d2], "2001-09-10");

		[f setDateFormat:@"HH:mm:ss"];
		checkStr("dateFormat HH:mm:ss", [f stringFromDate:d1], "01:46:40");

		[f setDateFormat:@"yyyy-MM-dd"];
		{
			NSDate *parsed = [f dateFromString:@"2001-09-09"];
			NSDate *other = [f dateFromString:@"2001-09-10"];

			checkInt("dateFromString returns a date", parsed != nil, 1);
			checkInt("CONTROL two dates parse to different values",
			         (parsed != nil && other != nil &&
			          [parsed timeIntervalSince1970] != [other timeIntervalSince1970]), 1);
			if (parsed != nil)
				checkStr("round trip through dateFromString", [f stringFromDate:parsed],
				         "2001-09-09");
		}
		[f release];
	}

	/* The calendar, which is what an application uses when it wants the parts rather than a
	 * string. Fixed to GMT for the same reason. */
	{
		NSCalendar *cal = [[[NSCalendar alloc]
		                       initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
		NSDateComponents *c;

		/* NIL AND ZERO ARE DIFFERENT ANSWERS and a message to nil gives 0, so separate them before
		 * reading any component: a nil calendar and a calendar that answers zero need different
		 * fixes. */
		checkInt("NSCalendar initWithCalendarIdentifier is not nil", cal != nil, 1);
		checkInt("currentCalendar is not nil", [NSCalendar currentCalendar] != nil, 1);
		/* A NIL CONSTANT AND A FAILED LOOKUP GIVE THE SAME NIL. Print the constant and try the
		 * literal it is supposed to equal, so the next step is not a guess. */
		printf("PROBE NSCalendarIdentifierGregorian = %s\n",
		       NSCalendarIdentifierGregorian != nil
		           ? [NSCalendarIdentifierGregorian UTF8String] : "(nil)");
		checkInt("initWithCalendarIdentifier with the literal gregorian",
		         [[[NSCalendar alloc] initWithCalendarIdentifier:@"gregorian"] autorelease] != nil, 1);
		checkInt("calendarWithIdentifier with the literal gregorian",
		         [NSCalendar calendarWithIdentifier:@"gregorian"] != nil, 1);

		[cal setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];
		c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
		           fromDate:d1];
		checkInt("components:fromDate: is not nil", c != nil, 1);
		checkInt("NSCalendar year of the fixed date", [c year], 2001);
		checkInt("NSCalendar month of the fixed date", [c month], 9);
		checkInt("NSCalendar day of the fixed date", [c day], 9);
		checkInt("CONTROL the next day is the 10th",
		         [[cal components:NSCalendarUnitDay fromDate:d2] day], 10);
	}

	/* Number formatting, which every row of a finance application goes through. The decimal
	 * separator is locale dependent, so this fixes the locale and asserts exact output. */
	{
		NSNumberFormatter *n = [[NSNumberFormatter alloc] init];

		[n setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
		[n setNumberStyle:NSNumberFormatterDecimalStyle];
		[n setMinimumFractionDigits:2];
		[n setMaximumFractionDigits:2];
		[n setGroupingSeparator:@""];
		[n setUsesGroupingSeparator:NO];

		checkStr("NSNumberFormatter 1234.5 to 2 places",
		         [n stringFromNumber:[NSNumber numberWithDouble:1234.5]], "1234.50");
		checkStr("CONTROL a different amount differs",
		         [n stringFromNumber:[NSNumber numberWithDouble:7.25]], "7.25");
		checkStr("NSNumberFormatter negative", [n stringFromNumber:[NSNumber numberWithDouble:-3.0]],
		         "-3.00");
		[n release];
	}

	printf("PROBE %d checks, %d mismatched\n", gChecks, gBad);
	[pool release];
	return 0;
}
