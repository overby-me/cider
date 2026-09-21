/* DO SORTING AND FILTERING ANSWER CORRECTLY?
 *
 * Every table driven application on the roster sorts a column and filters a list, and both go
 * through NSSortDescriptor and NSPredicate. A comparator that returns a constant leaves the array
 * in its original order, and a predicate that always answers YES returns the whole array: both
 * look like an application that ignored the user, and neither raises anything. That is the same
 * shape as the empty character set in #247 and the placeholder calendar identifiers in #253.
 *
 * EVERY CASE CARRIES A CONTROL. An array that comes back in the right order proves nothing unless
 * the INPUT was in the wrong order to begin with, and a filter that returns two of four proves
 * nothing unless a different predicate returns a different count. Both halves are asserted.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#import <Foundation/NSArray.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSPredicate.h>
#import <Foundation/NSSortDescriptor.h>
#import <Foundation/NSString.h>
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
	printf("PROBE %-52s got=%-18s want=%-18s %s\n", what, g ?: "(null)", want, ok ? "ok" : "MISMATCH");
}

static void checkInt(const char *what, long got, long want) {
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-52s got=%-18ld want=%-18ld %s\n", what, got, want,
	       (got == want) ? "ok" : "MISMATCH");
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	/* Deliberately NOT in sorted order, so a sort that does nothing fails. */
	NSArray *names = [NSArray arrayWithObjects:@"pear", @"apple", @"cherry", @"banana", nil];

	{
		NSSortDescriptor *up = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:YES];
		NSSortDescriptor *down = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO];
		NSArray *asc = [names sortedArrayUsingDescriptors:[NSArray arrayWithObject:up]];
		NSArray *desc = [names sortedArrayUsingDescriptors:[NSArray arrayWithObject:down]];

		checkInt("CONTROL the input was NOT already sorted",
		         [[names objectAtIndex:0] isEqualToString:@"pear"], 1);
		checkInt("sortedArrayUsingDescriptors keeps the count", [asc count], 4);
		if ([asc count] == 4) {
			checkStr("ascending first is apple", [asc objectAtIndex:0], "apple");
			checkStr("ascending last is pear", [asc objectAtIndex:3], "pear");
		}
		if ([desc count] == 4)
			checkStr("CONTROL descending first is pear", [desc objectAtIndex:0], "pear");
	}
	{
		NSArray *sel = [names sortedArrayUsingSelector:@selector(compare:)];

		checkInt("sortedArrayUsingSelector keeps the count", [sel count], 4);
		if ([sel count] == 4) {
			checkStr("sortedArrayUsingSelector first is apple", [sel objectAtIndex:0], "apple");
			checkStr("CONTROL and last is pear", [sel objectAtIndex:3], "pear");
		}
	}
	{
		NSPredicate *begins = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", @"b"];
		NSPredicate *none = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", @"z"];
		NSPredicate *all = [NSPredicate predicateWithValue:YES];

		checkInt("predicate BEGINSWITH b matches 1 of 4",
		         [[names filteredArrayUsingPredicate:begins] count], 1);
		checkInt("CONTROL BEGINSWITH z matches none",
		         [[names filteredArrayUsingPredicate:none] count], 0);
		checkInt("CONTROL predicateWithValue YES matches all four",
		         [[names filteredArrayUsingPredicate:all] count], 4);
		checkInt("evaluateWithObject on a match", [begins evaluateWithObject:@"banana"], 1);
		checkInt("CONTROL evaluateWithObject on a non match",
		         [begins evaluateWithObject:@"apple"], 0);
	}
	{
		/* A dictionary key path, which is how a table column is actually sorted and filtered. */
		NSArray *rows = [NSArray arrayWithObjects:
		    [NSDictionary dictionaryWithObjectsAndKeys:@"b", @"name",
		                  [NSNumber numberWithInt:2], @"amount", nil],
		    [NSDictionary dictionaryWithObjectsAndKeys:@"a", @"name",
		                  [NSNumber numberWithInt:1], @"amount", nil], nil];
		NSArray *sorted = [rows sortedArrayUsingDescriptors:[NSArray arrayWithObject:
		    [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
		NSArray *big = [rows filteredArrayUsingPredicate:
		    [NSPredicate predicateWithFormat:@"amount > 1"]];

		if ([sorted count] == 2)
			checkStr("sort by a dictionary key path", [[sorted objectAtIndex:0] objectForKey:@"name"], "a");
		checkInt("filter on a numeric key path matches 1 of 2", [big count], 1);
		checkInt("CONTROL amount > 0 matches both",
		         [[rows filteredArrayUsingPredicate:
		             [NSPredicate predicateWithFormat:@"amount > 0"]] count], 2);
	}

	printf("PROBE %d checks, %d mismatched\n", gChecks, gBad);
	[pool release];
	return 0;
}
