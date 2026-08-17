#import "_NSControllerArray.h"
#include <stdlib.h>
#import "NSObservationProxy.h"
#import <Foundation/NSException.h>
#import <Foundation/NSIndexSet.h>
#import <Foundation/NSKeyValueObserving.h>
#import <Foundation/NSString.h>

@implementation _NSControllerArray

- objectAtIndex: (NSUInteger) idx {
    return [_array objectAtIndex: idx];
}

- (NSUInteger) count {
    return [_array count];
}

- init {
    return [self initWithObjects: NULL count: 0];
}

- initWithObjects: (id *) objects count: (NSUInteger) count {
    _array = [[NSMutableArray alloc] initWithObjects: objects count: count];
    _observationProxies = [NSMutableArray new];
    return self;
}

- (void) dealloc {
    /*
     * UNWIND WHAT IS LEFT INSTEAD OF RAISING, and say so when it happens.
     *
     * The exception here is the Cocoa diagnostic for deallocating an object that still has key
     * value observers, and it is aimed at whoever registered them. That is the wrong party in this
     * class. _NSControllerArray is not an object an application ever holds: it is the TRANSIENT
     * value a controller hands back for selection or arrangedObjects, and it is replaced whenever
     * the content changes. An observer of selection.someKey ends up registered on whichever array
     * was current at the time, so the controller destroying that array is normal, and raising
     * takes the caller down with it.
     *
     * Swift Publisher is the caller. The exception came out of
     *
     *   -[_NSControllerArray dealloc]
     *   -[NSControllerSelectionProxy controllerWillChange]
     *   -[NSObjectController setContent:]
     *   -[CCMainWindowController awakeFromNib]
     *   -[NSNib instantiateNibWithExternalNameTable:]
     *   ... -[NSWindowController showWindow:] -[NSDocument showWindows]
     *
     * so an internal array being replaced during window setup unwound the whole nib load and the
     * document window never appeared. Once on paperFormat, once on visibleRightView, which is why
     * fixing one observation path did not end it.
     *
     * What is left to do is exactly what -removeObserver:forKeyPath: does: this array forwards
     * observation to its ELEMENTS, so the forwards have to come off them or they outlive the
     * array. Leaving them attached would be the real bug.
     */
    while ([_observationProxies count] > 0) {
        _NSObservationProxy *proxy = [[_observationProxies lastObject] retain];

        if (getenv("CIDER_TRACE_CONTROL") != NULL) {
            fprintf(stderr, "CIDER_CARRAY dealloc unwinding observer on %s\n",
                    [[proxy keyPath] UTF8String] ?: "?");
            fflush(stderr);
        }

        [self removeObserver: [proxy observer] forKeyPath: [proxy keyPath]];
        [proxy release];
    }

    [_observationProxies release];
    [_array release];
    [_roi release];
    [super dealloc];
}

- (void) addObserver: (id) observer
          forKeyPath: (NSString *) keyPath
             options: (NSKeyValueObservingOptions) options
             context: (void *) context
{
    // init the proxy
    _NSObservationProxy *proxy =
            [[_NSObservationProxy alloc] initWithKeyPath: keyPath
                                                observer: observer
                                                  object: self];

    proxy->_options = options;
    proxy->_context = context;
    [_observationProxies addObject: proxy];
    [proxy release];

    // get the relevant indexes
    id idxs;
    if (_roi)
        idxs = _roi;
    else
        idxs = [NSIndexSet
                indexSetWithIndexesInRange: NSMakeRange(0, [_array count])];

    // is this an operator?
    if ([keyPath hasPrefix: @"@"]) {
        NSString *firstPart, *rest;
        NSStringKVCSplitOnDot(keyPath, &firstPart, &rest);

        // observe ourselves
        [super addObserver: observer
                forKeyPath: keyPath
                   options: options
                   context: context];

        // if there's anything the operator depends on, observe _all_ objects
        // for that path
        keyPath = rest;
        idxs = [NSIndexSet
                indexSetWithIndexesInRange: NSMakeRange(0, [_array count])];
    }

    // add observer proxy for all relevant indexes
    if ([_array count] && keyPath) {
        [_array addObserver: proxy
                toObjectsAtIndexes: idxs
                        forKeyPath: keyPath
                           options: options
                           context: context];
    }
}

- (void) removeObserver: (id) observer forKeyPath: (NSString *) keyPath {
    // find the proxy again
    _NSObservationProxy *proxy =
            [[_NSObservationProxy alloc] initWithKeyPath: keyPath
                                                observer: observer
                                                  object: self];
    /*
     * NSNotFound IS NOT -1, and an int said it was.
     *
     * indexOfObject: answers NSNotFound, which is NSUIntegerMax; stored in an int that becomes -1,
     * and objectAtIndex: -1 raises
     *
     *   NSRangeException: index (-1) beyond array bounds (0)
     *
     * so removing an observer that is not registered blew up instead of doing nothing. It reached
     * Swift Publisher through -[NSKeyValueNestedProperty object:withObservance:...], which removes
     * an observation the array had already dropped, and the exception unwound the document window
     * nib load exactly like the one above it did.
     *
     * Nothing registered means nothing to remove. The operator branch below still runs, because a
     * key path starting with @ is observed on super as well as on the elements.
     */
    NSUInteger idx = [_observationProxies indexOfObject: proxy];
    [proxy release];

    if (idx == NSNotFound) {
        if (getenv("CIDER_TRACE_CONTROL") != NULL) {
            fprintf(stderr, "CIDER_CARRAY removeObserver: %s was not registered\n",
                    [keyPath UTF8String] ?: "?");
            fflush(stderr);
        }
        return;
    }

    proxy = [[[_observationProxies objectAtIndex: idx] retain] autorelease];
    [_observationProxies removeObjectAtIndex: idx];

    // get the relevant indexes
    id idxs;

    if (_roi)
        idxs = _roi;
    else
        idxs = [NSIndexSet
                indexSetWithIndexesInRange: NSMakeRange(0, [_array count])];

    // operator?
    if ([keyPath hasPrefix: @"@"]) {
        NSString *firstPart, *rest;
        NSStringKVCSplitOnDot(keyPath, &firstPart, &rest);

        [super removeObserver: observer forKeyPath: keyPath];

        // remove dependent key path from all children
        keyPath = rest;
        idxs = [NSIndexSet
                indexSetWithIndexesInRange: NSMakeRange(0, [_array count])];
    }
    if ([_array count] && keyPath) {
        [_array removeObserver: proxy
                fromObjectsAtIndexes: idxs
                          forKeyPath: keyPath];
    }
}

- (void) insertObject: (id) obj atIndex: (NSUInteger) idx {
    for (_NSObservationProxy *proxy in _observationProxies) {
        id keyPath = [proxy keyPath];

        if ([keyPath hasPrefix: @"@"]) {
            // this operator will probably have changed
            [self willChangeValueForKey: keyPath];

            NSString *firstPart, *rest;
            NSStringKVCSplitOnDot(keyPath, &firstPart, &rest);

            // if dependencies: observe these in any case
            if (rest)
                [obj addObserver: proxy
                        forKeyPath: rest
                           options: [proxy options]
                           context: [proxy context]];
        } else if (!_roi) {
            // only observe if no ROI
            [obj addObserver: proxy
                    forKeyPath: keyPath
                       options: [proxy options]
                       context: [proxy context]];
        }
    }

    [_array insertObject: obj atIndex: idx];
    // change ROI to reflect new state (unobserved for new index)
    [_roi shiftIndexesStartingAtIndex: idx by: 1];

    for (_NSObservationProxy *proxy in _observationProxies) {
        id keyPath = [proxy keyPath];

        if ([keyPath hasPrefix: @"@"])
            [self didChangeValueForKey: keyPath];
    }
}

- (void) removeObjectAtIndex: (NSUInteger) idx {
    id obj = [_array objectAtIndex: idx];
    for (_NSObservationProxy *proxy in _observationProxies) {
        id keyPath = [proxy keyPath];

        if ([keyPath hasPrefix: @"@"]) {
            [self willChangeValueForKey: keyPath];
            NSString *firstPart, *rest;
            NSStringKVCSplitOnDot(keyPath, &firstPart, &rest);

            if (rest) {
                [obj removeObserver: proxy forKeyPath: rest];
            }
        } else {
            if (!_roi || [_roi containsIndex: idx]) {
                [obj removeObserver: proxy forKeyPath: keyPath];
            }
        }
    }
    [_array removeObjectAtIndex: idx];

    if ([_roi containsIndex: idx])
        [_roi shiftIndexesStartingAtIndex: idx + 1 by: -1];

    for (_NSObservationProxy *proxy in _observationProxies) {
        id keyPath = [proxy keyPath];

        if ([keyPath hasPrefix: @"@"])
            [self didChangeValueForKey: keyPath];
    }
}

- (void) addObject: (id) obj {
    [self insertObject: obj atIndex: [self count]];
}

- (void) removeLastObject {
    [self removeObjectAtIndex: [self count] - 1];
}

- (void) replaceObjectAtIndex: (NSUInteger) idx withObject: (id) obj {
    id old = [_array objectAtIndex: idx];
    for (_NSObservationProxy *proxy in _observationProxies) {
        id keyPath = [proxy keyPath];

        if ([keyPath hasPrefix: @"@"]) {
            [self willChangeValueForKey: keyPath];
            NSString *firstPart, *rest;
            NSStringKVCSplitOnDot(keyPath, &firstPart, &rest);

            if (rest) {
                [old removeObserver: proxy forKeyPath: [proxy keyPath]];

                [obj addObserver: proxy
                        forKeyPath: rest
                           options: [proxy options]
                           context: [proxy context]];
            }
        } else {
            if (!_roi || [_roi containsIndex: idx]) {
                [old removeObserver: proxy forKeyPath: [proxy keyPath]];

                [obj addObserver: proxy
                        forKeyPath: [proxy keyPath]
                           options: [proxy options]
                           context: [proxy context]];
            }
        }
    }
    [_array replaceObjectAtIndex: idx withObject: obj];

    for (_NSObservationProxy *proxy in _observationProxies) {
        id keyPath = [proxy keyPath];

        if ([keyPath hasPrefix: @"@"])
            [self didChangeValueForKey: keyPath];
    }
}

- (void) setROI: (NSIndexSet *) newROI {
    if (newROI != _roi) {
        id proxies = [_observationProxies copy];

        // TODO: this should be optimized to only change those indexes that
        // actually changed
        for (_NSObservationProxy *proxy in proxies) {
            [self removeObserver: [proxy observer] forKeyPath: [proxy keyPath]];
        }

        [_roi release];
        _roi = [newROI mutableCopy];

        for (_NSObservationProxy *proxy in proxies) {
            [self addObserver: [proxy observer]
                    forKeyPath: [proxy keyPath]
                       options: [proxy options]
                       context: [proxy context]];
        }

        [proxies release];
    }
}
@end
