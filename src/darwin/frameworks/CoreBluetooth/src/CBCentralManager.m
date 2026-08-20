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

#import <CoreBluetooth/CBCentralManager.h>
#import <dispatch/dispatch.h>

NSString *const CBCentralManagerScanOptionAllowDuplicatesKey = @"kCBScanOptionAllowDuplicates";

/*
 * AN INITIALISER MUST RETURN AN OBJECT, and a forwardInvocation: stub cannot.
 *
 * This class used to be a stub whose -methodSignatureForSelector: answered "v@:" for everything, so
 * -initWithDelegate:queue: was forwarded, produced no return value, and the caller got whatever
 * happened to be in the return register. MoneyMoney does
 *
 *     manager = [[CBCentralManager alloc] initWithDelegate: self queue: nil];
 *     objc_autorelease(manager);
 *
 * on a thread of its own during the add-account flow, and the value it autoreleased was
 * 0x4071f00000000000, which is the double 287.0: a general protection fault the moment its isa was
 * read, and the whole application went with it.
 *
 * The state it reports is UNSUPPORTED, which is the truthful answer here: there is no Bluetooth
 * transport in this container, and Unsupported is what CoreBluetooth documents for a machine that
 * cannot do BLE at all. PoweredOff would be a lie of a different kind, one that invites an
 * application to ask the user to switch something on.
 */
@implementation CBCentralManager {
    id<CBCentralManagerDelegate> _delegate;
    dispatch_queue_t _queue;
}

@synthesize delegate = _delegate;

- (instancetype) initWithDelegate: (id<CBCentralManagerDelegate>) delegate
                            queue: (dispatch_queue_t) queue
{
    return [self initWithDelegate: delegate queue: queue options: nil];
}

- (instancetype) initWithDelegate: (id<CBCentralManagerDelegate>) delegate
                            queue: (dispatch_queue_t) queue
                          options: (NSDictionary *) options
{
    if ((self = [super init]) == nil) {
        return nil;
    }

    _delegate = delegate;
    _queue = queue != NULL ? queue : dispatch_get_main_queue();
    dispatch_retain(_queue);

    /*
     * ASYNCHRONOUSLY, NEVER FROM INSIDE init. The caller has not finished assigning the manager to
     * whatever it keeps it in, and a delegate callback that arrives before that sees a half-built
     * object. CoreBluetooth delivers the first state update on the queue for the same reason.
     */
    CBCentralManager *manager = [self retain];

    dispatch_async(_queue, ^{
        id<CBCentralManagerDelegate> target = [manager delegate];

        if ([target respondsToSelector: @selector(centralManagerDidUpdateState:)]) {
            [target centralManagerDidUpdateState: manager];
        }
        [manager release];
    });

    return self;
}

- (void) dealloc {
    if (_queue != NULL) {
        dispatch_release(_queue);
    }
    [super dealloc];
}

- (CBManagerState) state {
    return CBManagerStateUnsupported;
}

- (id<CBCentralManagerDelegate>) delegate {
    return _delegate;
}

- (void) setDelegate: (id<CBCentralManagerDelegate>) delegate {
    _delegate = delegate;
}

- (BOOL) isScanning {
    return NO;
}

/* Nothing can be found, so scanning is a no-op rather than an error: an application that starts a
 * scan and never hears about a peripheral is in the state this machine is genuinely in. */
- (void) scanForPeripheralsWithServices: (NSArray *) serviceUUIDs
                                options: (NSDictionary *) options
{
}

- (void) stopScan {
}

- (void) connectPeripheral: (CBPeripheral *) peripheral options: (NSDictionary *) options {
}

- (void) cancelPeripheralConnection: (CBPeripheral *) peripheral {
}

- (NSArray *) retrievePeripheralsWithIdentifiers: (NSArray *) identifiers {
    return [NSArray array];
}

- (NSArray *) retrieveConnectedPeripheralsWithServices: (NSArray *) serviceUUIDs {
    return [NSArray array];
}

@end
