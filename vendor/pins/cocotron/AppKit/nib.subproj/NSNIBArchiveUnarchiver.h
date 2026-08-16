/* Copyright (c) 2026 Cider contributors.

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

/*
 * THE THIRD NIB FORMAT, which is the one every current application ships.
 *
 * This framework reads two: the typedstream Interface Builder wrote before Xcode 3, and the keyed
 * property list it wrote until Xcode 4. Everything built since is a NIBArchive, whose first ten
 * bytes are that word, and nothing here read it. A nib that fails to decode is SILENT: no menu, no
 * connections, no window, which from the outside is an application that started and did nothing.
 *
 * The object graph inside is the same one the keyed archive carries, class for class and key for
 * key: NSIBObjectData with NSConnections and NSObjectsKeys, NSCustomObject with NSClassName,
 * NSMenu with NSMenuItems. Only the container is different, so this class parses the container and
 * hands each object to the initWithCoder: that already exists.
 */
#import <Foundation/NSCoder.h>

@class NSData, NSMutableDictionary;

@interface _NSNIBArchiveUnarchiver : NSCoder {
    NSData *_data;
    const unsigned char *_bytes;
    NSUInteger _length;

    struct _NIBObject *_objects;
    NSUInteger _objectCount;
    struct _NIBValue *_values;
    NSUInteger _valueCount;
    NSString **_keys;
    NSUInteger _keyCount;
    NSString **_classNames;
    NSUInteger _classCount;

    /* One slot per object: the instance once it exists. Filled BEFORE initWithCoder: runs, because
     * a nib graph has cycles (a menu item names its menu, which lists the item) and the second
     * visit has to find the first one rather than build it again. */
    id *_instances;

    /* Which object decode*ForKey: is being asked about, as a stack: initWithCoder: of one object
     * decodes another, and the keys belong to whichever is on top. */
    NSUInteger *_scope;
    NSUInteger _scopeDepth;

    NSMutableDictionary *_classSubstitutions;
    id _delegate;
    BOOL _valid;
}

+ (BOOL) isNIBArchiveData: (NSData *) data;

- initForReadingWithData: (NSData *) data;
- (void) setClass: (Class) cls forClassName: (NSString *) name;
- (void) setDelegate: delegate;
- delegate;

@end
