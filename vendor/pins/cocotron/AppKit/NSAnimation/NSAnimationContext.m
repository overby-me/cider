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

+ (void) beginGrouping {
    NSUnimplementedMethod();
}
+ (void) endGrouping {
    NSUnimplementedMethod();
}

+ (NSAnimationContext *) currentContext {
    NSUnimplementedMethod();
    return nil;
}

- (void) setDuration: (NSTimeInterval) duration {
    NSUnimplementedMethod();
}
- (NSTimeInterval) duration {
    NSUnimplementedMethod();
    return 0;
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
    if (changes != NULL)
        changes([self currentContext]);
    [self endGrouping];

    if (completionHandler != NULL)
        completionHandler();
}

+ (void) runAnimationGroup: (void (^)(NSAnimationContext *context)) changes {
    [self runAnimationGroup: changes completionHandler: NULL];
}

@end