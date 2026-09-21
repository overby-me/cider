/* DOES THE RUNTIME CONSULT ITS OWN DISPATCH HOOKS BEFORE GIVING UP?
 *
 * A selector that is not in a class's method list is not yet an error on macOS. objc_msgSend asks
 * +resolveInstanceMethod: first, then -forwardingTargetForSelector:, then the full
 * methodSignatureForSelector:/forwardInvocation: pair, and only then raises. An application that
 * declares a property @dynamic and adds the accessor in resolveInstanceMethod: is ordinary Cocoa,
 * and it works with NOTHING in the class's method list.
 *
 * If any one of those hooks is skipped here, the port raises where macOS returns, and the symptom
 * is not an error message: cocotron wraps action delivery in @try, so the raise is swallowed and
 * the application merely does less than it should. MoneyMoney loses its whole Preferences window
 * to one caught raise on a selector its class does not implement (#254), which is what made this
 * worth asking directly rather than guessing from the application side.
 *
 * EVERY HOOK CARRIES A CONTROL THAT MUST RAISE. A runtime that never raises passes every
 * did-not-raise assertion, so each case is paired with the same selector sent to a class that
 * installs no hook at all. Both halves are asserted.
 *
 * Prints and always exits 0: a measurement, not a suite case.
 */
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSException.h>
#import <Foundation/NSInvocation.h>
#import <Foundation/NSMethodSignature.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>

#include <objc/runtime.h>
#include <stdio.h>

static int gChecks = 0;
static int gBad = 0;

static void checkInt(const char *what, long got, long want) {
	gChecks++;
	if (got != want) gBad++;
	printf("PROBE %-56s got=%-6ld want=%-6ld %s\n", what, got, want,
	       (got == want) ? "ok" : "MISMATCH");
}

/* The receiver that installs no hook. Its only job is to prove the selector really is absent and
 * that this runtime does raise when nothing answers. */
@interface ProbeBare : NSObject
@end
@implementation ProbeBare
@end

/* +resolveInstanceMethod:, which is how an @dynamic property accessor is supplied. */
static int gResolveCalls = 0;

@interface ProbeResolve : NSObject
@end
@implementation ProbeResolve
static void probeSetFlag(id self, SEL _cmd, BOOL value) { (void) self; (void) _cmd; (void) value; }

+ (BOOL)resolveInstanceMethod:(SEL)sel {
	gResolveCalls++;
	if (sel == sel_getUid("setHasPriority:")) {
		class_addMethod(self, sel, (IMP) probeSetFlag, "v@:c");
		return YES;
	}
	return [super resolveInstanceMethod:sel];
}
@end

/* -forwardingTargetForSelector:, the cheap second chance. */
@interface ProbeTargetHelper : NSObject
@end
@implementation ProbeTargetHelper
- (void)setHasPriority:(BOOL)value { (void) value; }
@end

@interface ProbeTarget : NSObject
@end
@implementation ProbeTarget
- (id)forwardingTargetForSelector:(SEL)sel {
	if (sel == sel_getUid("setHasPriority:"))
		return [[[ProbeTargetHelper alloc] init] autorelease];
	return [super forwardingTargetForSelector:sel];
}
@end

/* The full forwarding pair, which is the last chance before doesNotRecognizeSelector:. */
static int gForwarded = 0;

@interface ProbeForward : NSObject
@end
@implementation ProbeForward
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
	if (sel == sel_getUid("setHasPriority:"))
		return [NSMethodSignature signatureWithObjCTypes:"v@:c"];
	return [super methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
	gForwarded++;
}
@end

/* Sending an unknown selector is a compile error without a declaration, so go through the runtime
 * directly, exactly as the application's compiled call site does. */
static BOOL sendSetHasPriority(id target) {
	void (*send)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL)) objc_msgSend;
	BOOL raised = NO;

	@try {
		send(target, sel_getUid("setHasPriority:"), YES);
	} @catch (NSException *e) {
		raised = YES;
	}
	return raised;
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	/* THE CONTROL FIRST. If this does not raise, every other case below is meaningless, because a
	 * runtime that silently swallows unknown selectors passes them all. */
	checkInt("CONTROL no hook at all raises",
	         sendSetHasPriority([[[ProbeBare alloc] init] autorelease]), 1);
	checkInt("CONTROL the selector really is absent from ProbeBare",
	         class_getInstanceMethod([ProbeBare class], sel_getUid("setHasPriority:")) != NULL, 0);

	{
		id r = [[[ProbeResolve alloc] init] autorelease];

		checkInt("resolveInstanceMethod: is consulted, so no raise", sendSetHasPriority(r), 0);
		checkInt("  and it was actually called", gResolveCalls > 0, 1);
		checkInt("  and the method is now installed",
		         class_getInstanceMethod([ProbeResolve class], sel_getUid("setHasPriority:")) != NULL, 1);
	}
	{
		id t = [[[ProbeTarget alloc] init] autorelease];

		checkInt("forwardingTargetForSelector: is consulted, so no raise", sendSetHasPriority(t), 0);
	}
	{
		id f = [[[ProbeForward alloc] init] autorelease];

		checkInt("forwardInvocation: is consulted, so no raise", sendSetHasPriority(f), 0);
		checkInt("  and the invocation actually arrived", gForwarded > 0, 1);
	}

	/* respondsToSelector: must NOT be fooled by a hook that has not run yet, and must answer YES
	 * once resolveInstanceMethod: has installed the method. Separate from dispatch on purpose:
	 * an application asks this before sending. */
	checkInt("respondsToSelector: is NO on the bare class",
	         [[[[ProbeBare alloc] init] autorelease] respondsToSelector:sel_getUid("setHasPriority:")], 0);
	checkInt("respondsToSelector: is YES after resolution",
	         [[[[ProbeResolve alloc] init] autorelease] respondsToSelector:sel_getUid("setHasPriority:")], 1);

	printf("PROBE %d checks, %d mismatched\n", gChecks, gBad);
	[pool release];
	return 0;
}
