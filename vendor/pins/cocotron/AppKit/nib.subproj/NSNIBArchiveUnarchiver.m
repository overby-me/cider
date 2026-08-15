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

#import "NSNIBArchiveUnarchiver.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>
#import <stdlib.h>
#import <string.h>

/*
 * THE FILE LAYOUT, all little endian:
 *
 *   char     magic[10] = "NIBArchive"
 *   uint32   major, minor
 *   uint32   objectCount, objectOffset
 *   uint32   keyCount, keyOffset
 *   uint32   valueCount, valueOffset
 *   uint32   classCount, classOffset
 *
 * An OBJECT is three varints: which class, where its values start, how many it has.
 * A KEY is a varint length and that many bytes.
 * A VALUE is a varint key index, a one byte type, and a payload whose size the type decides.
 * A CLASS is a varint length, a varint count of extra int32s, those int32s, then the name.
 *
 * VARINTS ARE BACKWARDS from every other format in this tree: seven bits per byte, low bits first,
 * and the byte that has its high bit SET is the LAST one rather than a continuation.
 */
enum {
    _NIBValueInt8 = 0,
    _NIBValueInt16 = 1,
    _NIBValueInt32 = 2,
    _NIBValueInt64 = 3,
    _NIBValueTrue = 4,
    _NIBValueFalse = 5,
    _NIBValueFloat = 6,
    _NIBValueDouble = 7,
    _NIBValueData = 8,
    _NIBValueNil = 9,
    _NIBValueObject = 10,
};

struct _NIBObject {
    uint32_t classIndex;
    uint32_t valueIndex;
    uint32_t valueCount;
};

struct _NIBValue {
    uint32_t keyIndex;
    uint8_t kind;
    union {
        long long integer;
        double real;
        uint32_t object;
        struct {
            uint32_t offset;
            uint32_t length;
        } data;
    } payload;
};

static BOOL NIBTracing(void) {
    return getenv("CIDER_TRACE_NIB") != NULL;
}

@implementation _NSNIBArchiveUnarchiver

+ (BOOL) isNIBArchiveData: (NSData *) data {
    return ([data length] >= 10 && memcmp([data bytes], "NIBArchive", 10) == 0);
}

- (uint32_t) _uint32At: (NSUInteger) offset {
    uint32_t value = 0;

    if (offset + 4 <= _length) {
        memcpy(&value, _bytes + offset, 4);
    }
    return value;
}

- (unsigned long long) _varintAt: (NSUInteger *) offset {
    unsigned long long value = 0;
    int shift = 0;

    while (*offset < _length) {
        unsigned char byte = _bytes[(*offset)++];

        value |= ((unsigned long long) (byte & 0x7F)) << shift;
        shift += 7;
        if (byte & 0x80) {
            break;
        }
    }
    return value;
}

- initForReadingWithData: (NSData *) data {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _data = [data retain];
    _bytes = (const unsigned char *) [data bytes];
    _length = [data length];
    _classSubstitutions = [[NSMutableDictionary alloc] init];
    _valid = NO;

    if (![[self class] isNIBArchiveData: data] || _length < 50) {
        return self;
    }

    NSUInteger objectOffset, keyOffset, valueOffset, classOffset, i, pos;

    _objectCount = [self _uint32At: 18];
    objectOffset = [self _uint32At: 22];
    _keyCount = [self _uint32At: 26];
    keyOffset = [self _uint32At: 30];
    _valueCount = [self _uint32At: 34];
    valueOffset = [self _uint32At: 38];
    _classCount = [self _uint32At: 42];
    classOffset = [self _uint32At: 46];

    if (_objectCount == 0 || _classCount == 0) {
        return self;
    }

    _objects = calloc(_objectCount, sizeof(struct _NIBObject));
    _values = calloc(_valueCount ? _valueCount : 1, sizeof(struct _NIBValue));
    _keys = calloc(_keyCount ? _keyCount : 1, sizeof(NSString *));
    _classNames = calloc(_classCount, sizeof(NSString *));
    _instances = calloc(_objectCount, sizeof(id));
    _scope = calloc(_objectCount + 8, sizeof(NSUInteger));

    pos = objectOffset;
    for (i = 0; i < _objectCount; i++) {
        _objects[i].classIndex = (uint32_t) [self _varintAt: &pos];
        _objects[i].valueIndex = (uint32_t) [self _varintAt: &pos];
        _objects[i].valueCount = (uint32_t) [self _varintAt: &pos];
    }

    pos = keyOffset;
    for (i = 0; i < _keyCount; i++) {
        NSUInteger length = (NSUInteger) [self _varintAt: &pos];

        if (pos + length > _length) {
            return self;
        }
        _keys[i] = [[NSString alloc] initWithBytes: _bytes + pos
                                            length: length
                                          encoding: NSUTF8StringEncoding];
        pos += length;
    }

    pos = valueOffset;
    for (i = 0; i < _valueCount; i++) {
        _values[i].keyIndex = (uint32_t) [self _varintAt: &pos];
        if (pos >= _length) {
            return self;
        }
        _values[i].kind = _bytes[pos++];
        switch (_values[i].kind) {
        case _NIBValueInt8:
            _values[i].payload.integer = (signed char) _bytes[pos];
            pos += 1;
            break;
        case _NIBValueInt16: {
            int16_t v = 0;
            memcpy(&v, _bytes + pos, 2);
            _values[i].payload.integer = v;
            pos += 2;
            break;
        }
        case _NIBValueInt32: {
            int32_t v = 0;
            memcpy(&v, _bytes + pos, 4);
            _values[i].payload.integer = v;
            pos += 4;
            break;
        }
        case _NIBValueInt64: {
            int64_t v = 0;
            memcpy(&v, _bytes + pos, 8);
            _values[i].payload.integer = v;
            pos += 8;
            break;
        }
        case _NIBValueTrue:
            _values[i].payload.integer = 1;
            break;
        case _NIBValueFalse:
            _values[i].payload.integer = 0;
            break;
        case _NIBValueFloat: {
            float v = 0;
            memcpy(&v, _bytes + pos, 4);
            _values[i].payload.real = v;
            pos += 4;
            break;
        }
        case _NIBValueDouble: {
            double v = 0;
            memcpy(&v, _bytes + pos, 8);
            _values[i].payload.real = v;
            pos += 8;
            break;
        }
        case _NIBValueData: {
            NSUInteger length = (NSUInteger) [self _varintAt: &pos];

            _values[i].payload.data.offset = (uint32_t) pos;
            _values[i].payload.data.length = (uint32_t) length;
            pos += length;
            break;
        }
        case _NIBValueNil:
            break;
        case _NIBValueObject: {
            uint32_t v = 0;
            memcpy(&v, _bytes + pos, 4);
            _values[i].payload.object = v;
            pos += 4;
            break;
        }
        default:
            if (NIBTracing()) {
                fprintf(stderr, "CIDER_NIB archive UNKNOWN value type %d at value %lu\n",
                        (int) _values[i].kind, (unsigned long) i);
            }
            return self;
        }
        if (pos > _length) {
            return self;
        }
    }

    pos = classOffset;
    for (i = 0; i < _classCount; i++) {
        NSUInteger length = (NSUInteger) [self _varintAt: &pos];
        NSUInteger extras = (NSUInteger) [self _varintAt: &pos];

        pos += extras * 4;
        if (pos + length > _length) {
            return self;
        }
        /* The name is NUL terminated inside its own length, which is why the length alone is not
         * the string: a name decoded with the terminator in it matches no class. */
        NSUInteger textLength = length;

        while (textLength > 0 && _bytes[pos + textLength - 1] == 0) {
            textLength--;
        }
        _classNames[i] = [[NSString alloc] initWithBytes: _bytes + pos
                                                 length: textLength
                                               encoding: NSUTF8StringEncoding];
        pos += length;
    }

    _valid = YES;
    if (NIBTracing()) {
        fprintf(stderr, "CIDER_NIB archive objects=%lu keys=%lu values=%lu classes=%lu\n",
                (unsigned long) _objectCount, (unsigned long) _keyCount,
                (unsigned long) _valueCount, (unsigned long) _classCount);
        fflush(stderr);
    }
    return self;
}

- (void) dealloc {
    NSUInteger i;

    for (i = 0; i < _keyCount; i++) {
        [_keys[i] release];
    }
    for (i = 0; i < _classCount; i++) {
        [_classNames[i] release];
    }
    for (i = 0; i < _objectCount; i++) {
        [_instances[i] release];
    }
    free(_objects);
    free(_values);
    free(_keys);
    free(_classNames);
    free(_instances);
    free(_scope);
    [_classSubstitutions release];
    [_data release];
    [super dealloc];
}

- (void) setClass: (Class) cls forClassName: (NSString *) name {
    [_classSubstitutions setObject: cls forKey: name];
}

- (void) setDelegate: delegate {
    _delegate = delegate;
}

- delegate {
    return _delegate;
}

- (BOOL) allowsKeyedCoding {
    return YES;
}

/* The values of the object being decoded, and the current key inside them. */
- (struct _NIBValue *) _valueForKey: (NSString *) key {
    if (!_valid || _scopeDepth == 0) {
        return NULL;
    }

    struct _NIBObject *object = &_objects[_scope[_scopeDepth - 1]];
    NSUInteger i;

    for (i = 0; i < object->valueCount; i++) {
        struct _NIBValue *value = &_values[object->valueIndex + i];

        if (value->keyIndex < _keyCount && [_keys[value->keyIndex] isEqualToString: key]) {
            return value;
        }
    }
    return NULL;
}

- (Class) _classForName: (NSString *) name {
    Class substitute = [_classSubstitutions objectForKey: name];

    if (substitute != nil) {
        return substitute;
    }
    return NSClassFromString(name);
}

/*
 * A CONTAINER IS BUILT HERE, NOT BY ITS OWN initWithCoder:.
 *
 * Foundation classes encode themselves in this archive with keys of their own: a string is NS.bytes,
 * a number is NS.intval, and an array is a run of values that all share the key
 * UINibEncoderEmptyKey. The initWithCoder: in this framework expects the keys of the PROPERTY LIST
 * archive instead, so handing them this decoder produces empty strings and empty arrays. They are
 * short and they are exact, so they are built directly.
 */
- (id) _buildContainerOfClass: (NSString *) className atIndex: (NSUInteger) index {
    struct _NIBObject *object = &_objects[index];

    if ([className isEqualToString: @"NSString"] ||
        [className isEqualToString: @"NSMutableString"]) {
        NSUInteger i;

        for (i = 0; i < object->valueCount; i++) {
            struct _NIBValue *value = &_values[object->valueIndex + i];

            if (value->kind == _NIBValueData) {
                NSString *text = [[NSString alloc]
                        initWithBytes: _bytes + value->payload.data.offset
                               length: value->payload.data.length
                             encoding: NSUTF8StringEncoding];

                if ([className isEqualToString: @"NSMutableString"]) {
                    NSString *mutable = [[NSMutableString alloc] initWithString: text];

                    [text release];
                    return mutable;
                }
                return text;
            }
        }
        return [@"" retain];
    }

    if ([className isEqualToString: @"NSNumber"]) {
        NSUInteger i;

        for (i = 0; i < object->valueCount; i++) {
            struct _NIBValue *value = &_values[object->valueIndex + i];

            switch (value->kind) {
            case _NIBValueInt8:
            case _NIBValueInt16:
            case _NIBValueInt32:
            case _NIBValueInt64:
                return [[NSNumber numberWithLongLong: value->payload.integer] retain];
            case _NIBValueTrue:
                return [[NSNumber numberWithBool: YES] retain];
            case _NIBValueFalse:
                return [[NSNumber numberWithBool: NO] retain];
            case _NIBValueFloat:
            case _NIBValueDouble:
                return [[NSNumber numberWithDouble: value->payload.real] retain];
            default:
                break;
            }
        }
        return [[NSNumber numberWithInt: 0] retain];
    }

    if ([className isEqualToString: @"NSArray"] ||
        [className isEqualToString: @"NSMutableArray"] ||
        [className isEqualToString: @"NSSet"] ||
        [className isEqualToString: @"NSMutableSet"]) {
        /*
         * STORED BEFORE IT IS FILLED, for the same reason an object is stored before it is
         * initialised: a cycle THROUGH A CONTAINER has to terminate.
         *
         * The first version built the whole array and only then recorded it, so an array holding an
         * object whose own decoding reaches that array again recursed until the stack ran out. The
         * process died with no exception and no message, 700 objects into a 1573 object nib, and
         * the last thing printed was the array it had just started: MoneyMoney has that shape and
         * neither LibreOffice nor iTerm2 does.
         *
         * A MUTABLE container is what gets stored even where the archive says NSArray or NSSet. The
         * alternative is to swap in an immutable copy at the end, and then the objects that already
         * hold the mutable one are holding something else: two collections where the nib meant one.
         * NSMutableArray is an NSArray, and nothing in a decoded nib mutates one afterwards.
         */
        BOOL wantsSet = [className hasSuffix: @"Set"];
        id contents = wantsSet ? (id) [[NSMutableSet alloc] init]
                               : (id) [[NSMutableArray alloc] init];
        NSUInteger i;

        _instances[index] = contents;

        for (i = 0; i < object->valueCount; i++) {
            struct _NIBValue *value = &_values[object->valueIndex + i];

            if (value->kind == _NIBValueObject) {
                id member = [self _objectAtIndex: value->payload.object];

                if (member != nil) {
                    [contents addObject: member];
                }
            }
        }
        return contents;
    }

    if ([className isEqualToString: @"NSData"] ||
        [className isEqualToString: @"NSMutableData"]) {
        NSUInteger i;

        for (i = 0; i < object->valueCount; i++) {
            struct _NIBValue *value = &_values[object->valueIndex + i];

            if (value->kind == _NIBValueData) {
                return [[NSData alloc] initWithBytes: _bytes + value->payload.data.offset
                                              length: value->payload.data.length];
            }
        }
        return [[NSData alloc] init];
    }

    return nil;
}

- (id) _objectAtIndex: (NSUInteger) index {
    if (!_valid || index >= _objectCount) {
        return nil;
    }
    if (_instances[index] != nil) {
        return _instances[index];
    }

    NSString *className = _classNames[_objects[index].classIndex];

    if (NIBTracing()) {
        fprintf(stderr, "CIDER_NIB enter %lu %s\n", (unsigned long) index,
                [className UTF8String]);
        fflush(stderr);
    }

    id built = [self _buildContainerOfClass: className atIndex: index];

    if (built != nil) {
        _instances[index] = built;
        return built;
    }

    Class cls = [self _classForName: className];

    if (cls == Nil) {
        if (NIBTracing()) {
            fprintf(stderr, "CIDER_NIB archive NO CLASS %s\n", [className UTF8String]);
            fflush(stderr);
        }
        return nil;
    }

    /* WHICH OBJECT IS BEING BUILT, because a decode that dies takes the process with it and says
     * nothing: MoneyMoney parsed its 1573 objects and then vanished with no exception and no
     * message. The last line printed is the class that did it. */
    if (NIBTracing()) {
        fprintf(stderr, "CIDER_NIB build %lu %s\n", (unsigned long) index,
                [className UTF8String]);
        fflush(stderr);
    }

    /* STORED BEFORE IT IS INITIALISED, which is the only way a cycle terminates: a menu item names
     * the menu that lists it, so decoding either one reaches the other before either is finished. */
    id instance = [cls alloc];

    _instances[index] = instance;

    _scope[_scopeDepth++] = index;
    id initialised = [instance initWithCoder: self];
    _scopeDepth--;

    if (initialised != instance) {
        _instances[index] = initialised;
        instance = initialised;
    }

    id awake = [instance awakeAfterUsingCoder: self];

    if (awake != instance) {
        _instances[index] = awake;
        instance = awake;
    }
    if (NIBTracing()) {
        fprintf(stderr, "CIDER_NIB built %lu %s ok\n", (unsigned long) index,
                [className UTF8String]);
        fflush(stderr);
    }
    return instance;
}

/*
 * SWAP ONE OBJECT FOR ANOTHER IN THE TABLE, which nib loading needs rather than wants.
 *
 * NSIBObjectData replaces the placeholder objects a nib carries with the real ones: the File Owner
 * with the object that loaded the nib, and each NSCustomObject with the instance it names. A keyed
 * unarchiver does this by rewriting its uid table so every later decode of the same reference
 * answers with the replacement, and this is the same thing over the object array.
 */
- (void) replaceObject: (id) original withObject: (id) replacement {
    NSUInteger i;

    if (original == replacement) {
        return;
    }
    if ([_delegate respondsToSelector: @selector(unarchiver:willReplaceObject:withObject:)]) {
        [_delegate unarchiver: (id) self willReplaceObject: original withObject: replacement];
    }
    for (i = 0; i < _objectCount; i++) {
        if (_instances[i] == original) {
            [replacement retain];
            [_instances[i] release];
            _instances[i] = replacement;
        }
    }
}

- (BOOL) containsValueForKey: (NSString *) key {
    return [self _valueForKey: key] != NULL;
}

- (id) decodeObjectForKey: (NSString *) key {
    struct _NIBValue *value = [self _valueForKey: key];

    if (value == NULL) {
        return nil;
    }
    switch (value->kind) {
    case _NIBValueObject:
        return [self _objectAtIndex: value->payload.object];
    case _NIBValueData:
        return [NSData dataWithBytes: _bytes + value->payload.data.offset
                              length: value->payload.data.length];
    case _NIBValueNil:
        return nil;
    default:
        return nil;
    }
}

- (id) decodeObjectOfClass: (Class) cls forKey: (NSString *) key {
    return [self decodeObjectForKey: key];
}

- (BOOL) decodeBoolForKey: (NSString *) key {
    struct _NIBValue *value = [self _valueForKey: key];

    if (value == NULL) {
        return NO;
    }
    if (value->kind == _NIBValueFloat || value->kind == _NIBValueDouble) {
        return value->payload.real != 0.0;
    }
    return value->payload.integer != 0;
}

- (long long) _integerForKey: (NSString *) key {
    struct _NIBValue *value = [self _valueForKey: key];

    if (value == NULL) {
        return 0;
    }
    if (value->kind == _NIBValueFloat || value->kind == _NIBValueDouble) {
        return (long long) value->payload.real;
    }
    return value->payload.integer;
}

- (int) decodeIntForKey: (NSString *) key {
    return (int) [self _integerForKey: key];
}

- (NSInteger) decodeIntegerForKey: (NSString *) key {
    return (NSInteger) [self _integerForKey: key];
}

- (int32_t) decodeInt32ForKey: (NSString *) key {
    return (int32_t) [self _integerForKey: key];
}

- (int64_t) decodeInt64ForKey: (NSString *) key {
    return (int64_t) [self _integerForKey: key];
}

- (float) decodeFloatForKey: (NSString *) key {
    return (float) [self decodeDoubleForKey: key];
}

- (double) decodeDoubleForKey: (NSString *) key {
    struct _NIBValue *value = [self _valueForKey: key];

    if (value == NULL) {
        return 0.0;
    }
    if (value->kind == _NIBValueFloat || value->kind == _NIBValueDouble) {
        return value->payload.real;
    }
    return (double) value->payload.integer;
}

- (const uint8_t *) decodeBytesForKey: (NSString *) key
                       returnedLength: (NSUInteger *) length
{
    struct _NIBValue *value = [self _valueForKey: key];

    if (value == NULL || value->kind != _NIBValueData) {
        if (length != NULL) {
            *length = 0;
        }
        return NULL;
    }
    if (length != NULL) {
        *length = value->payload.data.length;
    }
    return _bytes + value->payload.data.offset;
}

/*
 * THE ROOT, which is an object of its own rather than a header field. Object zero holds
 * IB.objectdata, and NSNib asks for exactly that key, so the scope is opened on it and the caller
 * sees the same interface a keyed unarchiver gives.
 */
- (id) decodeObjectForRootKey: (NSString *) key {
    if (!_valid) {
        return nil;
    }
    _scope[_scopeDepth++] = 0;
    id result = [self decodeObjectForKey: key];
    _scopeDepth--;
    return result;
}

- (BOOL) isValidArchive {
    return _valid;
}

@end
