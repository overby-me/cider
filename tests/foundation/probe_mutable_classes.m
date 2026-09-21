/* DOES EVERY MUTABLE CLASS ACTUALLY MUTATE?
 *
 * NSMutableCharacterSet did not, for the whole life of this port, and nothing failed loudly:
 * it inherited -[NSCharacterSet init], which builds an IMMUTABLE CFCharacterSet, and every mutator
 * was gated on __CFCharacterSetIsMutable and silently did nothing. One application, iTerm2, made it
 * visible by blanking its own terminal on a resize (#247).
 *
 * A mutable class cluster that hands back an immutable object is invisible from the outside: no
 * error, no exception, no log line, just a collection that stays empty. So ask every one of them
 * the same question directly rather than reading their init methods, which is how the first one
 * was missed.
 *
 * EVERY CASE CARRIES A CONTROL THAT MUST BE ABSENT, because a container that answers YES to
 * everything passes every add-then-find assertion and is just as broken.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
/* NOT Foundation.h: the umbrella reaches NSURLCredential.h, which imports Security, which is not on
 * this target's header path. */
#import <Foundation/NSArray.h>
#import <Foundation/NSAttributedString.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSIndexSet.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSOrderedSet.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSString.h>

#include <stdio.h>

static int gChecks = 0;
static int gBad = 0;

static void check(const char *what, int got, int want) {
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-52s got=%-3s want=%-3s %s\n", what, got ? "YES" : "NO", want ? "YES" : "NO",
	       (got == want) ? "ok" : "MISMATCH");
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *a = @"alpha";
	NSString *absent = @"neverAdded";

	{
		NSMutableArray *m = [[NSMutableArray alloc] init];
		[m addObject:a];
		check("NSMutableArray addObject then count is 1", [m count] == 1, 1);
		check("NSMutableArray CONTROL does not contain the absent one",
		      [m containsObject:absent], 0);
		[m release];
	}
	{
		NSMutableDictionary *m = [[NSMutableDictionary alloc] init];
		[m setObject:a forKey:@"k"];
		check("NSMutableDictionary setObject then objectForKey", [m objectForKey:@"k"] != nil, 1);
		check("NSMutableDictionary CONTROL absent key is nil", [m objectForKey:absent] != nil, 0);
		[m release];
	}
	{
		NSMutableSet *m = [[NSMutableSet alloc] init];
		[m addObject:a];
		check("NSMutableSet addObject then containsObject", [m containsObject:a], 1);
		check("NSMutableSet CONTROL absent object", [m containsObject:absent], 0);
		[m release];
	}
	{
		NSMutableOrderedSet *m = [[NSMutableOrderedSet alloc] init];
		[m addObject:a];
		check("NSMutableOrderedSet addObject then containsObject", [m containsObject:a], 1);
		check("NSMutableOrderedSet CONTROL absent object", [m containsObject:absent], 0);
		[m release];
	}
	{
		NSMutableData *m = [[NSMutableData alloc] init];
		const char bytes[4] = {1, 2, 3, 4};
		[m appendBytes:bytes length:4];
		check("NSMutableData appendBytes then length is 4", [m length] == 4, 1);
		check("NSMutableData CONTROL length is not 0", [m length] == 0, 0);
		[m release];
	}
	{
		NSMutableString *m = [[NSMutableString alloc] init];
		[m appendString:a];
		check("NSMutableString appendString then isEqual", [m isEqualToString:a], 1);
		check("NSMutableString CONTROL not equal to the absent one",
		      [m isEqualToString:absent], 0);
		[m release];
	}
	{
		NSMutableIndexSet *m = [[NSMutableIndexSet alloc] init];
		[m addIndex:7];
		check("NSMutableIndexSet addIndex then containsIndex", [m containsIndex:7], 1);
		check("NSMutableIndexSet CONTROL absent index", [m containsIndex:9], 0);
		[m release];
	}
	{
		NSMutableAttributedString *m =
		    [[NSMutableAttributedString alloc] initWithString:@""];
		[m appendAttributedString:[[[NSAttributedString alloc] initWithString:a] autorelease]];
		check("NSMutableAttributedString append then length", [m length] == [a length], 1);
		check("NSMutableAttributedString CONTROL length is not 0", [m length] == 0, 0);
		[m release];
	}
	{
		NSMutableCharacterSet *m = [[NSMutableCharacterSet alloc] init];
		[m addCharactersInRange:NSMakeRange('q', 1)];
		check("NSMutableCharacterSet addCharactersInRange then member",
		      [m characterIsMember:(unichar) 'q'], 1);
		check("NSMutableCharacterSet CONTROL absent character",
		      [m characterIsMember:(unichar) 'z'], 0);
		[m release];
	}

	printf("PROBE %d checks, %d mismatched\n", gChecks, gBad);
	[pool release];
	return 0;
}
