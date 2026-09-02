/* Copyright (c) 2006-2007 Christopher J. W. Lloyd
                 2010 Markus Hitter <mah@jump-ing.de>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

#import <AppKit/NSApplication.h>
#import <AppKit/NSDisplay.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSEvent_keyboard.h>
#import <AppKit/NSEvent_mouse.h>
#import <AppKit/NSEvent_other.h>
#import <AppKit/NSEvent_periodic.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSException.h>
#import <Foundation/NSRaise.h>

@implementation NSEvent

/*
 * NSEvent CONFORMS TO NSCopying ON APPLE, and applications rely on it: an application that wants
 * to keep an event past the end of the current pass copies it, because the one it was handed is
 * autoreleased. LibreOffice does exactly that for every mouse event it receives, so without this
 * the FIRST CLICK anywhere in the application raises an unrecognized selector, is caught, and the
 * process reports Unspecified Application Error and exits.
 *
 * A retain rather than a real copy, which is correct rather than lazy: an NSEvent is immutable once
 * created, every accessor is a getter, and there is no mutable subclass. Foundation does the same
 * for NSString and NSNumber for the same reason. Doing it on the base class covers NSEvent_mouse,
 * NSEvent_keyboard and the rest without repeating it five times.
 */
- (id) copyWithZone: (NSZone *) zone {
    return [self retain];
}

+ (NSPoint) mouseLocation {
    return [[NSDisplay currentDisplay] mouseLocation];
}

+ (NSEventModifierFlags) modifierFlags {
    return [[NSDisplay currentDisplay] currentModifierFlags];
}

/*
 * Which buttons are held RIGHT NOW, outside any event. The Wayland backend does not track button
 * state, so this answers "none", and that is a policy answer with a consequence: an application
 * polling it to ask whether a drag is under way is told there is none. Reporting a button held
 * instead would be worse, because it never becomes false and the drag never ends.
 */
+ (NSUInteger) pressedMouseButtons {
    return 0;
}

/* Overridden by NSEvent_mouse, which is the only kind that is given one. */
- (NSInteger) eventNumber {
    return 0;
}

- (instancetype) initWithType: (NSEventType) type
                     location: (NSPoint) location
                modifierFlags: (NSEventModifierFlags) modifierFlags
                       window: (NSWindow *) window
{
    _type = type;
    _timestamp = [NSDate timeIntervalSinceReferenceDate];
    _locationInWindow = location;
    _modifierFlags = modifierFlags;
    _windowNumber = [window windowNumber];
    return self;
}

+ (instancetype) mouseEventWithType: (NSEventType) type
                           location: (NSPoint) location
                      modifierFlags: (NSEventModifierFlags) modifierFlags
                             window: (NSWindow *) window
                         clickCount: (NSInteger) clickCount
                             deltaX: (CGFloat) deltaX
                             deltaY: (CGFloat) deltaY
{
    return [[[NSEvent_mouse alloc] initWithType: type
                                       location: location
                                  modifierFlags: modifierFlags
                                         window: window
                                     clickCount: clickCount
                                         deltaX: deltaX
                                         deltaY: deltaY] autorelease];
}

+ (instancetype) mouseEventWithType: (NSEventType) type
                           location: (NSPoint) location
                      modifierFlags: (NSEventModifierFlags) modifierFlags
                             window: (NSWindow *) window
                             deltaY: (CGFloat) deltaY
{
    return [[[NSEvent_mouse alloc] initWithType: type
                                       location: location
                                  modifierFlags: modifierFlags
                                         window: window
                                         deltaY: deltaY] autorelease];
}

+ (instancetype) enterExitEventWithType: (NSEventType) type
                               location: (NSPoint) location
                          modifierFlags: (NSEventModifierFlags) flags
                              timestamp: (NSTimeInterval) timestamp
                           windowNumber: (NSInteger) windowNumber
                                context: (NSGraphicsContext *) context
                            eventNumber: (NSInteger) eventNumber
                         trackingNumber: (NSInteger) tracking
                               userData: (void *) userData
{
    return [[[NSEvent_mouse alloc] initWithType: type
                                       location: location
                                  modifierFlags: flags
                                      timestamp: timestamp
                                   windowNumber: windowNumber
                                        context: context
                                    eventNumber: eventNumber
                                 trackingNumber: tracking
                                       userData: userData] autorelease];
}

+ (instancetype) mouseEventWithType: (NSEventType) type
                           location: (NSPoint) location
                      modifierFlags: (NSEventModifierFlags) modifierFlags
                          timestamp: (NSTimeInterval) timestamp
                       windowNumber: (NSInteger) windowNumber
                            context: (NSGraphicsContext *) context
                        eventNumber: (NSInteger) eventNumber
                         clickCount: (NSInteger) clickCount
                           pressure: (float) pressure
{
    return [[[NSEvent_mouse alloc] initWithType: type
                                       location: location
                                  modifierFlags: modifierFlags
                                      timestamp: timestamp
                                   windowNumber: windowNumber
                                        context: context
                                    eventNumber: eventNumber
                                     clickCount: clickCount
                                       pressure: pressure] autorelease];
}

+ (instancetype) keyEventWithType: (NSEventType) type
                           location: (NSPoint) location
                      modifierFlags: (NSEventModifierFlags) modifierFlags
                             window: (NSWindow *) window
                         characters: (NSString *) characters
        charactersIgnoringModifiers: (NSString *) charactersIgnoringModifiers
                          isARepeat: (BOOL) isARepeat
                            keyCode: (unsigned short) keyCode
{
    return [[[NSEvent_keyboard alloc] initWithType: type
                                          location: location
                                     modifierFlags: modifierFlags
                                            window: window
                                        characters: characters
                       charactersIgnoringModifiers: charactersIgnoringModifiers
                                         isARepeat: isARepeat
                                           keyCode: keyCode] autorelease];
}

+ (instancetype) keyEventWithType: (NSEventType) type
                           location: (NSPoint) location
                      modifierFlags: (NSEventModifierFlags) modifierFlags
                          timestamp: (NSTimeInterval) timestamp
                       windowNumber: (NSInteger) windowNumber
                            context: (NSGraphicsContext *) context
                         characters: (NSString *) characters
        charactersIgnoringModifiers: (NSString *) charactersIgnoringModifiers
                          isARepeat: (BOOL) isARepeat
                            keyCode: (unsigned short) keyCode
{
    return [[[NSEvent_keyboard alloc]
                           initWithType: type
                               location: location
                          modifierFlags: modifierFlags
                                 window: [NSApp windowWithWindowNumber:
                                                         windowNumber]
                             characters: characters
            charactersIgnoringModifiers: charactersIgnoringModifiers
                              isARepeat: isARepeat
                                keyCode: keyCode] autorelease];
}

+ (instancetype) otherEventWithType: (NSEventType) type
                           location: (NSPoint) location
                      modifierFlags: (NSEventModifierFlags) flags
                          timestamp: (NSTimeInterval) timestamp
                       windowNumber: (NSInteger) windowNum
                            context: (NSGraphicsContext *) context
                            subtype: (short) subtype
                              data1: (NSInteger) data1
                              data2: (NSInteger) data2
{
    return [[[NSEvent_other alloc] initWithType: type
                                       location: location
                                  modifierFlags: flags
                                      timestamp: timestamp
                                   windowNumber: windowNum
                                        context: context
                                        subtype: subtype
                                          data1: data1
                                          data2: data2] autorelease];
}

- (NSEventType) type {
    return _type;
}

- (NSTimeInterval) timestamp {
    return _timestamp;
}

- (NSPoint) locationInWindow {
    return _locationInWindow;
}

- (NSEventModifierFlags) modifierFlags {
    return _modifierFlags;
}

- (NSWindow *) window {
    return [NSApp windowWithWindowNumber: [self windowNumber]];
}

- (NSInteger) windowNumber {
    return _windowNumber;
}

- (NSInteger) clickCount {
    return 0;
}

- (CGFloat) deltaX {
    return 0;
}

- (CGFloat) deltaY {
    return 0;
}

- (CGFloat) deltaZ {
    return 0;
}

- (NSString *) characters {
    return nil;
}

- (NSString *) charactersIgnoringModifiers {
    return nil;
}

- (unsigned short) keyCode {
    return 0xFFFF;
}

- (NSString *) description {
    return [NSString
            stringWithFormat:
                    @"<NSEvent: type=%lu loc=(%f,%f) time=%f flags=0x%lX "
                    @"win=%p winNum=%lu>",
                    (unsigned long) [self type], [self locationInWindow].x,
                    [self locationInWindow].y, [self timestamp],
                    (unsigned long) [self modifierFlags], [self window],
                    (unsigned long) [self windowNumber]];
}

static NSTimer *_periodicTimer = nil;

+ (void) _periodicDelay: (NSTimer *) timer {
    NSTimeInterval period = [[timer userInfo] doubleValue];

    [_periodicTimer invalidate];
    [_periodicTimer release];

    _periodicTimer = [[NSTimer timerWithTimeInterval: period
                                              target: self
                                            selector: @selector(_periodicEvent:)
                                            userInfo: nil
                                             repeats: YES] retain];

    [[NSRunLoop currentRunLoop] addTimer: _periodicTimer
                                 forMode: NSEventTrackingRunLoopMode];
}

+ (void) _periodicEvent: (NSTimer *) timer {
    NSEvent *event = [[[NSEvent_periodic alloc] initWithType: NSPeriodic
                                                    location: NSZeroPoint
                                               modifierFlags: 0
                                                      window: nil] autorelease];

    [[NSDisplay currentDisplay] postEvent: event atStart: NO];
    [[NSDisplay currentDisplay] discardEventsMatchingMask: NSPeriodicMask
                                              beforeEvent: event];
}

+ (void) startPeriodicEventsAfterDelay: (NSTimeInterval) delay
                            withPeriod: (NSTimeInterval) period
{
    NSNumber *userInfo = [NSNumber numberWithDouble: period];

    if (_periodicTimer != nil)
        [NSException raise: NSInternalInconsistencyException
                    format: @"periodic events already enabled"];

    _periodicTimer = [[NSTimer timerWithTimeInterval: delay
                                              target: self
                                            selector: @selector(_periodicDelay:)
                                            userInfo: userInfo
                                             repeats: NO] retain];

    [[NSRunLoop currentRunLoop] addTimer: _periodicTimer
                                 forMode: NSEventTrackingRunLoopMode];
}

+ (void) stopPeriodicEvents {
    [_periodicTimer invalidate];
    [_periodicTimer release];
    _periodicTimer = nil;
}

- (short) subtype {
    [NSException raise: NSInternalInconsistencyException
                format: @"No event subtype in %@", [self class]];
    return 0;
}

- (NSInteger) data1 {
    [NSException raise: NSInternalInconsistencyException
                format: @"No event data1 in %@", [self class]];
    return 0;
}

- (NSInteger) data2 {
    [NSException raise: NSInternalInconsistencyException
                format: @"No event data2 in %@", [self class]];
    return 0;
}

- (void *) userData {
    [NSException raise: NSInternalInconsistencyException
                format: @"No userData in %@", [self class]];
    return 0;
}

- (NSInteger) trackingNumber {
    [NSException raise: NSInternalInconsistencyException
                format: @"No trackingNumber in %@", [self class]];
    return 0;
}

- (NSTrackingArea *) trackingArea {
    [NSException raise: NSInternalInconsistencyException
                format: @"No trackingArea in %@", [self class]];
    return nil;
}

- (BOOL) isARepeat {
    return FALSE;
}

- (NSInteger) buttonNumber {
    return 0;
}

+ (id) addLocalMonitorForEventsMatchingMask: (NSEventMask) mask
                                    handler: (NSEvent * (^)(NSEvent *event)) block
{
    NSUnimplementedMethod();
    return nil;
}

+ (void) removeMonitor: (id) eventMonitor {
    NSUnimplementedMethod();
}


/*
 * THE SCROLL EVENT PROPERTIES, which decide whether a wheel event is looked at at all.
 *
 * LibreOffice classifies every scroll with isMouseScrollWheelEvent, and that reads -phase and
 * -momentumPhase before anything else: a wheel is the case where both are None and a trackpad
 * gesture is the case where they are not. Neither selector existed here, so the first thing the
 * application did with a scroll was raise an unrecognized selector, and its own handler swallowed
 * the exception. Eight scroll events reached -[SalFrameView scrollWheel:] and the document did not
 * move, with nothing in the log but the raise itself.
 *
 * None is the honest answer for a real wheel, which is what this backend delivers: Wayland
 * wl_pointer.axis carries no phase, and the discrete and value120 variants say notch, not gesture.
 * The precise deltas are the trackpad path and are reported as absent for the same reason.
 */
- (NSUInteger) phase {
    return 0; // NSEventPhaseNone
}

- (NSUInteger) momentumPhase {
    return 0; // NSEventPhaseNone
}

- (BOOL) hasPreciseScrollingDeltas {
    return NO;
}

- (CGFloat) scrollingDeltaX {
    return [self deltaX];
}

- (CGFloat) scrollingDeltaY {
    return [self deltaY];
}

- (BOOL) isDirectionInvertedFromDevice {
    return NO;
}

@end

NSEventMask NSEventMaskFromType(NSEventType type) {
    return 1 << type;
}
