/* WHERE DOES A BOOKMARK IDENTIFIER GO NIL?
 *
 * iA Writer terminates the moment a document is opened from the panel: -[IAFileBookmarkHistory
 * willUpdate:] removes a key from a dictionary and the key is nil. Disassembly of the shipping
 * FoundationAdditions slice says the key is [bookmark identifier], the identifier is set once in
 * +bookmarkWithURL:error: from [[NSUUID UUID] UUIDString] and once in -initWithCoder: from
 * decodeObjectOfClass:forKey:, and the array is walked with enumerateObjectsWithOptions:
 * NSEnumerationReverse. Any one of those three answering nil produces exactly this crash, and
 * nothing in an application trace can tell them apart.
 *
 * EVERY CASE CARRIES A CONTROL. A UUID string that is non nil proves nothing unless a second one
 * DIFFERS, because a stub returning a constant passes every non-nil test; a decode that returns a
 * string proves nothing unless a decode of the wrong class returns nil; an enumeration that hands
 * out objects proves nothing unless the objects arrive in the order the option asked for.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#import <Foundation/NSArray.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSUUID.h>
#import <Foundation/NSValue.h>

#include <stdio.h>
#include <string.h>

static int gChecks = 0;
static int gBad = 0;

static void checkBool(const char *what, int got, int want)
{
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-56s got=%-10s want=%-10s %s\n", what, got ? "YES" : "NO",
	       want ? "YES" : "NO", (got == want) ? "ok" : "MISMATCH");
}

static void checkStr(const char *what, NSString *got, const char *want)
{
	const char *g = (got != nil) ? [got UTF8String] : "(nil)";
	int ok = (g != NULL && want != NULL && strcmp(g, want) == 0);

	gChecks++;
	if (!ok) gBad++;
	printf("PROBE %-56s got=%-40s want=%-24s %s\n", what, g ?: "(null)", want ?: "(null)",
	       ok ? "ok" : "MISMATCH");
}

static void checkInt(const char *what, long got, long want)
{
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-56s got=%-10ld want=%-10ld %s\n", what, got, want,
	       (got == want) ? "ok" : "MISMATCH");
}

/* Stands in for IAFileBookmark: one string under the key the shipping class uses, archived and
 * decoded the same way, so a decode defect shows up here and not only inside the application. */
@interface ProbeBookmark : NSObject <NSSecureCoding>
@property (retain) NSString *identifier;
@end

@implementation ProbeBookmark
@synthesize identifier = _identifier;

+ (BOOL)supportsSecureCoding
{
	return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil)
		_identifier = [[coder decodeObjectOfClass:[NSString class] forKey:@"identifier"] retain];
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_identifier forKey:@"identifier"];
}

- (void)dealloc
{
	[_identifier release];
	[super dealloc];
}
@end

static void probeUUID(void)
{
	printf("\n-- NSUUID, the source of a freshly made bookmark identifier --\n");

	NSUUID *a = [NSUUID UUID];
	NSUUID *b = [NSUUID UUID];

	checkBool("[NSUUID UUID] is non nil", a != nil, 1);
	checkBool("a second [NSUUID UUID] is non nil", b != nil, 1);

	NSString *sa = [a UUIDString];
	NSString *sb = [b UUIDString];

	checkBool("UUIDString is non nil", sa != nil, 1);
	checkInt("UUIDString length", (long) [sa length], 36);
	/* The control: a stub that answers a constant passes every test above. */
	checkBool("two UUIDStrings DIFFER", ![sa isEqualToString:sb], 1);

	NSUUID *round = [[[NSUUID alloc] initWithUUIDString:sa] autorelease];
	checkBool("initWithUUIDString round trip is non nil", round != nil, 1);
	checkStr("initWithUUIDString round trips the spelling", [round UUIDString],
	         sa != nil ? [sa UTF8String] : NULL);
	checkBool("the round tripped UUID isEqual the original", [round isEqual:a], 1);
}

static void probeKeyedDecode(void)
{
	printf("\n-- keyed archiving, the source of a restored bookmark identifier --\n");

	ProbeBookmark *bm = [[[ProbeBookmark alloc] init] autorelease];
	[bm setIdentifier:@"87C9FB2E-0000-4000-8000-000000000001"];

	NSData *plain = [NSKeyedArchiver archivedDataWithRootObject:bm];
	checkBool("archivedDataWithRootObject: produced data", plain != nil && [plain length] > 0, 1);

	ProbeBookmark *plainBack = [NSKeyedUnarchiver unarchiveObjectWithData:plain];
	checkBool("unarchiveObjectWithData: returned an object", plainBack != nil, 1);
	checkStr("the identifier survived the plain round trip", [plainBack identifier],
	         "87C9FB2E-0000-4000-8000-000000000001");

	NSError *error = nil;
	NSData *secure = [NSKeyedArchiver archivedDataWithRootObject:bm
	                                      requiringSecureCoding:YES
	                                                      error:&error];
	checkBool("secure archivedDataWithRootObject: produced data",
	          secure != nil && [secure length] > 0, 1);

	error = nil;
	ProbeBookmark *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[ProbeBookmark class]
	                                                        fromData:secure
	                                                           error:&error];
	checkBool("unarchivedObjectOfClass: returned an object", back != nil, 1);
	checkStr("the identifier survived the secure round trip", [back identifier],
	         "87C9FB2E-0000-4000-8000-000000000001");

	/* The control: asking for the wrong class must answer nil rather than hand the object over. */
	error = nil;
	id wrong = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSURL class]
	                                             fromData:secure
	                                                error:&error];
	checkBool("unarchivedObjectOfClass: of the WRONG class answers nil", wrong == nil, 1);
}

static void probeEnumerationAndKeyPath(void)
{
	printf("\n-- the walk willUpdate: makes over the change set --\n");

	ProbeBookmark *one = [[[ProbeBookmark alloc] init] autorelease];
	ProbeBookmark *two = [[[ProbeBookmark alloc] init] autorelease];
	[one setIdentifier:@"ID-ONE"];
	[two setIdentifier:@"ID-TWO"];
	NSArray *both = [NSArray arrayWithObjects:one, two, nil];

	__block NSUInteger seen = 0;
	__block NSUInteger nilObjects = 0;
	__block NSUInteger nilIdentifiers = 0;
	__block NSUInteger firstIndex = 99;
	[both enumerateObjectsWithOptions:NSEnumerationReverse
	                       usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if (seen == 0) firstIndex = idx;
		seen++;
		if (obj == nil) nilObjects++;
		if (obj != nil && [obj identifier] == nil) nilIdentifiers++;
	}];

	checkInt("reverse enumeration visited every element", (long) seen, 2);
	checkInt("reverse enumeration STARTED at the last index", (long) firstIndex, 1);
	checkInt("no element arrived nil", (long) nilObjects, 0);
	checkInt("no identifier read back nil", (long) nilIdentifiers, 0);

	NSArray *ids = [both valueForKey:@"identifier"];
	checkBool("valueForKey: answered an array", [ids isKindOfClass:[NSArray class]], 1);
	checkInt("valueForKey: answered one value per element", (long) [ids count], 2);

	NSSet *set = [NSSet setWithArray:ids];
	checkBool("the set contains a value that is in it", [set containsObject:@"ID-ONE"], 1);
	/* The control: a set that contains everything passes the test above. */
	checkBool("the set does NOT contain a value that is absent",
	          [set containsObject:@"ID-NOT-THERE"], 0);
}

int main(int argc, const char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	probeUUID();
	probeKeyedDecode();
	probeEnumerationAndKeyPath();

	printf("\nPROBE SUMMARY %d checks, %d mismatched\n", gChecks, gBad);
	[pool release];
	return 0;
}
