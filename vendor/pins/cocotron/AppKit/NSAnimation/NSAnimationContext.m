/* Copyright (c) 2007 Christopher J. W. Lloyd

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 of the Software, and to permit persons to whom the Software is furnished to do
 so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE. */

#import "NSAnimationContext.h"
#import <AppKit/NSRaise.h>

@implementation NSAnimationContext

- (id) copyWithZone: (NSZone *) zone {
    return self;
}

/*
 * A REAL STACK, because +currentContext returning nil is not the same as returning a context that
 * animates nothing. The caller sets a duration and a completion handler on what it gets back, and a
 * nil answer swallows both silently; on macOS there is ALWAYS a current context on the main thread,
 * which is why nothing guards it.
 *
 * Nothing here animates, so a duration is carried and reported and the changes take effect at once.
 */
static NSMutableArray *_CiderAnimationContextStack(void) {
    static NSMutableArray *stack = nil;

    if (stack == nil)
        stack = [[NSMutableArray alloc] init];
    return stack;
}

+ (void) beginGrouping {
    [_CiderAnimationContextStack() addObject: [[[self alloc] init] autorelease]];
}

+ (void) endGrouping {
    NSMutableArray *stack = _CiderAnimationContextStack();
    NSAnimationContext *context = [stack lastObject];
    void (^completionHandler)(void) = [[[context completionHandler] copy] autorelease];

    if ([stack count] > 0)
        [stack removeLastObject];
    if (completionHandler != NULL)
        completionHandler();
}

+ (NSAnimationContext *) currentContext {
    NSMutableArray *stack = _CiderAnimationContextStack();

    if ([stack count] == 0)
        [stack addObject: [[[self alloc] init] autorelease]];
    return [stack lastObject];
}

- (void) dealloc {
    [_timingFunction release];
    [_completionHandler release];
    [super dealloc];
}

- (void) setDuration: (NSTimeInterval) duration {
    _duration = duration;
}

- (NSTimeInterval) duration {
    return _duration;
}

- (void) setCompletionHandler: (void (^)(void)) completionHandler {
    completionHandler = [completionHandler copy];
    [_completionHandler release];
    _completionHandler = completionHandler;
}

- (void (^)(void)) completionHandler {
    return _completionHandler;
}

/* Carried. Nothing here animates, so the curve is state the caller can read back. */
- (void) setTimingFunction: (id) timingFunction {
    timingFunction = [timingFunction retain];
    [_timingFunction release];
    _timingFunction = timingFunction;
}

- (id) timingFunction {
    return _timingFunction;
}

- (void) setAllowsImplicitAnimation: (BOOL) flag {
}

- (BOOL) allowsImplicitAnimation {
    return NO;
}

/*
 * THE GROUPED FORM, run rather than animated.
 *
 * Nothing here animates, so the block is applied immediately and the completion handler follows it.
 * That is the END STATE the caller asked for, reached in one step instead of over a duration, and it
 * is what makes the difference visible: unimplemented, this class method raised and took iA Writer
 * while it was laying out its library window.
 *
 * The handler runs AFTER the changes and on this thread, which is the ordering callers rely on.
 */
+ (void) runAnimationGroup: (void (^)(NSAnimationContext *context)) changes
         completionHandler: (void (^)(void)) completionHandler
{
    [self beginGrouping];
    if (completionHandler != NULL)
        [[self currentContext] setCompletionHandler: completionHandler];
    if (changes != NULL)
        changes([self currentContext]);
    [self endGrouping];
}

+ (void) runAnimationGroup: (void (^)(NSAnimationContext *context)) changes {
    [self runAnimationGroup: changes completionHandler: NULL];
}

@end