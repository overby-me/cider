/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#import <CoreBluetooth/CBUUID.h>

/*
 * The Bluetooth base UUID. A 16 or 32 bit UUID is shorthand for a 128 bit one with these 12 bytes
 * after it, which is what -UUIDString has to print for a short UUID and what two UUIDs of different
 * widths have to be compared through.
 */
static const uint8_t kCBUUIDBase[12] = {0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
                                        0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB};

static int cbHexValue(unichar c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

@implementation CBUUID {
    NSData *_data;
}

- (instancetype) _initWithData: (NSData *) data {
    if ((self = [super init]) != nil) {
        _data = [data copy];
    }
    return self;
}

- (void) dealloc {
    [_data release];
    [super dealloc];
}

+ (CBUUID *) UUIDWithData: (NSData *) theData {
    NSUInteger length = [theData length];

    if (length != 2 && length != 4 && length != 16) {
        [NSException raise: NSInternalInconsistencyException
                    format: @"CBUUID data must be 2, 4 or 16 bytes, not %lu",
                            (unsigned long) length];
        return nil;
    }
    return [[[CBUUID alloc] _initWithData: theData] autorelease];
}

+ (CBUUID *) UUIDWithString: (NSString *) theString {
    NSUInteger i, length = [theString length];
    uint8_t bytes[16];
    NSUInteger count = 0;
    int high = -1;

    /* Dashes are decoration wherever they appear: 180D, 0000180D, and the full dashed form all
     * arrive here, and only the hex digits carry anything. */
    for (i = 0; i < length; i++) {
        unichar c = [theString characterAtIndex: i];
        int value;

        if (c == '-')
            continue;

        value = cbHexValue(c);
        if (value < 0) {
            [NSException raise: NSInternalInconsistencyException
                        format: @"%@ is not a valid CBUUID string", theString];
            return nil;
        }
        if (high < 0) {
            high = value;
        } else {
            if (count >= sizeof(bytes)) {
                [NSException raise: NSInternalInconsistencyException
                            format: @"%@ is too long for a CBUUID", theString];
                return nil;
            }
            bytes[count++] = (uint8_t) ((high << 4) | value);
            high = -1;
        }
    }

    if (high >= 0 || (count != 2 && count != 4 && count != 16)) {
        [NSException raise: NSInternalInconsistencyException
                    format: @"%@ is not a 16, 32 or 128 bit CBUUID", theString];
        return nil;
    }

    return [CBUUID UUIDWithData: [NSData dataWithBytes: bytes length: count]];
}

+ (CBUUID *) UUIDWithNSUUID: (NSUUID *) theUUID {
    uuid_t bytes;

    [theUUID getUUIDBytes: bytes];
    return [CBUUID UUIDWithData: [NSData dataWithBytes: bytes length: sizeof(bytes)]];
}

+ (CBUUID *) UUIDWithCFUUID: (CFUUIDRef) theUUID {
    CFUUIDBytes bytes = CFUUIDGetUUIDBytes(theUUID);

    return [CBUUID UUIDWithData: [NSData dataWithBytes: &bytes length: sizeof(bytes)]];
}

- (NSData *) data {
    return _data;
}

/* THE FULL 128 BITS, always, so that a short UUID and the long one it stands for compare equal and
 * print the same, which is what CoreBluetooth documents. */
- (void) _getFullBytes: (uint8_t *) out {
    const uint8_t *bytes = [_data bytes];
    NSUInteger length = [_data length];

    if (length == 16) {
        memcpy(out, bytes, 16);
        return;
    }

    memset(out, 0, 4);
    memcpy(out + 4 - length, bytes, length);
    memcpy(out + 4, kCBUUIDBase, sizeof(kCBUUIDBase));
}

- (NSString *) UUIDString {
    uint8_t full[16];

    [self _getFullBytes: full];

    return [NSString stringWithFormat:
                             @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                             full[0], full[1], full[2], full[3], full[4], full[5], full[6], full[7],
                             full[8], full[9], full[10], full[11], full[12], full[13], full[14],
                             full[15]];
}

- (NSString *) description {
    return [self UUIDString];
}

- (BOOL) isEqual: (id) other {
    if (self == other)
        return YES;
    if (![other isKindOfClass: [CBUUID class]])
        return NO;

    uint8_t mine[16], theirs[16];

    [self _getFullBytes: mine];
    [(CBUUID *) other _getFullBytes: theirs];

    return memcmp(mine, theirs, sizeof(mine)) == 0;
}

- (NSUInteger) hash {
    uint8_t full[16];

    [self _getFullBytes: full];

    return [[NSData dataWithBytes: full length: sizeof(full)] hash];
}

- (id) copyWithZone: (NSZone *) zone {
    return [self retain];
}

@end
