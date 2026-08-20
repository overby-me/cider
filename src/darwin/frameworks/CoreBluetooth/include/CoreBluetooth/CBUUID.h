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

#include <Foundation/Foundation.h>

/*
 * A CBUUID IS A VALUE, NOT A CONNECTION. It is 2, 4 or 16 bytes and a few conversions, and none of
 * it needs a Bluetooth stack, so it can be real here while the rest of CoreBluetooth is a stub.
 * MoneyMoney builds several the moment its add-account flow starts, for the card readers it can
 * talk to, and a class that cannot answer +UUIDWithString: took the whole flow down with it.
 */
@interface CBUUID : NSObject <NSCopying>

@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) NSString *UUIDString;

+ (CBUUID *) UUIDWithString: (NSString *) theString;
+ (CBUUID *) UUIDWithData: (NSData *) theData;
+ (CBUUID *) UUIDWithNSUUID: (NSUUID *) theUUID;
+ (CBUUID *) UUIDWithCFUUID: (CFUUIDRef) theUUID;

@end
