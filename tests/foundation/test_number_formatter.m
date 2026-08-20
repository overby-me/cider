/*
 * test_number_formatter.m: NSNumberFormatter has to parse AND display.
 *
 * BUILT WITH BUCK2, like every other guest binary here, and only RUN inside the container: there is
 * no guest C compiler in this runtime (/usr/bin/clang is a 12 KB xcrun shim and the CLT directory
 * holds cctools and no clang), so a harness that compiles in the guest cannot run this at all.
 *
 * WHY THESE FIVE. Both halves of this class were missing here and each one cost an application a
 * usable control. getObjectValue:forString:errorDescription: forwarded to the range form, which
 * nothing in the chain implemented, so every parse RAISED: AppKit catches that per event and the
 * field editor retries on the next display pass, which turned one click on Swift Publisher's margin
 * field into 68,612 raises and a keyboard that appeared dead. stringForObjectValue: was missing too,
 * so a committed value came back out of the model as its raw description: the field read 22248 where
 * it should have read 309. Neither symptom names the formatter, and both are one line to assert.
 *
 * Build:
 *   buck2 build //tests/foundation:test_number_formatter
 * Run, staged into a directory launchd does not clear at boot:
 *   cp <built> <prefix>/private/var/tmp/ && cider shell /private/var/tmp/test_number_formatter
 *
 * Exit code 0 = all tests passed, nonzero = failure.
 */

#import <Foundation/Foundation.h>

#include <stdio.h>

static int failures = 0;

/* NOT "check": <AssertMacros.h> defines check() as a function-like macro and it is reached through
 * the Foundation header cascade, so a function of that name fails to compile with "too many
 * arguments provided to function-like macro invocation" and nothing points at the header. */
static void expect(int ok, const char *what, NSString *detail)
{
    if (ok) {
        printf("PASS: %s\n", what);
        return;
    }
    printf("FAIL: %s (%s)\n", what, detail != nil ? [detail UTF8String] : "no detail");
    failures++;
}

int main(void)
{
    @autoreleasepool {
        NSNumberFormatter *formatter = [[[NSNumberFormatter alloc] init] autorelease];

        [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
        [formatter setGroupingSeparator:@""];
        [formatter setUsesGroupingSeparator:NO];

        /* 1. The display half: a number renders, and it renders the same as stringFromNumber:. */
        NSString *shown = [formatter stringForObjectValue:[NSNumber numberWithInt:309]];
        NSString *direct = [formatter stringFromNumber:[NSNumber numberWithInt:309]];

        expect(shown != nil && [shown isEqualToString:direct],
              "stringForObjectValue: renders an NSNumber",
              [NSString stringWithFormat:@"got %@, stringFromNumber: gave %@", shown, direct]);

        /* 2. And it answers nil rather than a description for something it cannot render. */
        expect([formatter stringForObjectValue:@"not a number"] == nil,
              "stringForObjectValue: answers nil for a non-number", nil);

        /* 3. The parse half, range form: the value AND the range it consumed. */
        id parsed = nil;
        NSRange range = NSMakeRange(0, 2);
        NSError *error = nil;
        BOOL ok = [formatter getObjectValue:&parsed forString:@"42" range:&range error:&error];

        expect(ok && [parsed isKindOfClass:[NSNumber class]] && [parsed intValue] == 42,
              "getObjectValue:forString:range:error: parses",
              [NSString stringWithFormat:@"ok=%d value=%@ error=%@", (int) ok, parsed, error]);
        expect(range.location == 0 && range.length == 2,
              "getObjectValue:forString:range:error: reports the range it consumed",
              [NSString stringWithFormat:@"got {%lu, %lu}", (unsigned long) range.location,
                                         (unsigned long) range.length]);

        /* 4. The older form, which is what NSCell actually calls. This one used to RAISE. */
        id fromCell = nil;
        NSString *why = nil;

        ok = [formatter getObjectValue:&fromCell forString:@"7" errorDescription:&why];
        expect(ok && [fromCell intValue] == 7,
              "getObjectValue:forString:errorDescription: parses without raising",
              [NSString stringWithFormat:@"ok=%d value=%@ why=%@", (int) ok, fromCell, why]);

        /* 5. A RANGE LONGER THAN THE STRING IS CLAMPED, NOT FOLLOWED. The caller inside this very
         * class passed an uninitialised NSRange for years, which faulted inside CoreFoundation the
         * moment the callee existed. A formatter has to survive a caller that lies about length. */
        id clamped = nil;
        NSRange silly = NSMakeRange(0, 4096);

        ok = [formatter getObjectValue:&clamped forString:@"5" range:&silly error:NULL];
        expect(ok && [clamped intValue] == 5,
              "a range past the end of the string is clamped",
              [NSString stringWithFormat:@"ok=%d value=%@", (int) ok, clamped]);

        /* 6. Round trip, which is what a bound text field does on every commit. */
        id back = nil;
        NSString *rendered = [formatter stringForObjectValue:[NSNumber numberWithInt:1440]];

        ok = [formatter getObjectValue:&back forString:rendered errorDescription:NULL];
        expect(ok && [back intValue] == 1440, "a rendered number parses back to itself",
              [NSString stringWithFormat:@"rendered %@ parsed %@", rendered, back]);
    }

    if (failures != 0) {
        printf("\n%d test(s) failed\n", failures);
        return 1;
    }
    printf("\nAll number formatter tests passed\n");
    return 0;
}
