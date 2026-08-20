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
#import <CoreBluetooth/CBCentralManagerConstants.h>
#import <CoreBluetooth/CBManager.h>

@class CBCentralManager;
@class CBPeripheral;
@class CBUUID;

@protocol CBCentralManagerDelegate <NSObject>
@required
- (void) centralManagerDidUpdateState: (CBCentralManager *) central;
@end

/*
 * A CENTRAL MANAGER THAT ANSWERS. There is no Bluetooth transport in this container, and the
 * documented way to say that is a manager whose state is CBManagerStateUnsupported, delivered to the
 * delegate on its queue. An application then hides the feature and carries on.
 *
 * The alternative, which is what a forwardInvocation: stub does, is to return a garbage value from
 * -initWithDelegate:queue: and let the caller autorelease it. MoneyMoney did exactly that and died.
 */
@interface CBCentralManager : CBManager

/* assign, not weak: this framework is built with manual reference counting, and a
 * delegate is not owned. */
@property (nonatomic, assign) id<CBCentralManagerDelegate> delegate;
@property (nonatomic, readonly) BOOL isScanning;

- (instancetype) initWithDelegate: (id<CBCentralManagerDelegate>) delegate
                            queue: (dispatch_queue_t) queue;
- (instancetype) initWithDelegate: (id<CBCentralManagerDelegate>) delegate
                            queue: (dispatch_queue_t) queue
                          options: (NSDictionary *) options;

- (void) scanForPeripheralsWithServices: (NSArray *) serviceUUIDs
                                options: (NSDictionary *) options;
- (void) stopScan;
- (void) connectPeripheral: (CBPeripheral *) peripheral options: (NSDictionary *) options;
- (void) cancelPeripheralConnection: (CBPeripheral *) peripheral;
- (NSArray *) retrievePeripheralsWithIdentifiers: (NSArray *) identifiers;
- (NSArray *) retrieveConnectedPeripheralsWithServices: (NSArray *) serviceUUIDs;

@end
