/* DOES A MUTABLE CHARACTER SET REMEMBER WHAT WAS ADDED TO IT?
 *
 * -[VT100Grid numberOfNonEmptyLinesIncludingWhitespaceAsEmpty:] builds an NSMutableCharacterSet of
 * the cell codes that count as EMPTY, by addCharactersInRange: for 0, 2 and 4 and
 * addCharactersInString: for the rest, and then asks it which lines have content. In Cider it
 * answers that all 44 lines of a 44 line grid are used when only 4 hold text, which makes iTerm2
 * archive six rows of real output into scrollback on a shrink and blank its own terminal (#247).
 *
 * A set that forgets an added character, or a membership test that always answers NO, produces
 * exactly that. This asks the question directly instead of inferring it from the terminal.
 *
 * THE CONTROL IS A CHARACTER THAT WAS NEVER ADDED. Without it, a set whose membership test always
 * answers YES passes every assertion here and looks like a working set.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSString.h>
#import <Foundation/NSAutoreleasePool.h>

#include <stdio.h>

static void report(const char *what, int got, int want) {
	printf("PROBE %-46s got=%-3s want=%-3s %s\n", what, got ? "YES" : "NO", want ? "YES" : "NO",
	       (got == want) ? "ok" : "MISMATCH");
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSMutableCharacterSet *set = [[NSMutableCharacterSet alloc] init];

	if (set == nil) {
		printf("PROBE NSMutableCharacterSet alloc init returned nil\n");
		return 0;
	}

	/* The three ranges iTerm2 adds, read out of its disassembly. */
	[set addCharactersInRange:NSMakeRange(0, 1)];
	[set addCharactersInRange:NSMakeRange(2, 1)];
	[set addCharactersInRange:NSMakeRange(4, 1)];
	[set addCharactersInString:@" "];

	report("member 0 after addCharactersInRange 0,1", [set characterIsMember:(unichar) 0], 1);
	report("member 2 after addCharactersInRange 2,1", [set characterIsMember:(unichar) 2], 1);
	report("member 4 after addCharactersInRange 4,1", [set characterIsMember:(unichar) 4], 1);
	report("member space after addCharactersInString", [set characterIsMember:(unichar) ' '], 1);
	report("CONTROL member A, never added", [set characterIsMember:(unichar) 'A'], 0);
	report("CONTROL member 3, never added", [set characterIsMember:(unichar) 3], 0);

	/* The same questions through the immutable reading path, which is what a caller that copies the
	 * set would use, and through an inverted set, which is how a scan for NON empty cells is
	 * usually written. */
	{
		NSCharacterSet *copy = [[set copy] autorelease];
		NSCharacterSet *inverted = [set invertedSet];

		report("copy member 0", [copy characterIsMember:(unichar) 0], 1);
		report("copy CONTROL member A", [copy characterIsMember:(unichar) 'A'], 0);
		report("inverted member 0", [inverted characterIsMember:(unichar) 0], 0);
		report("inverted CONTROL member A", [inverted characterIsMember:(unichar) 'A'], 1);
	}

	[set release];
	[pool release];
	return 0;
}
