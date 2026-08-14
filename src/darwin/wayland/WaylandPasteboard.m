/*
 * The pasteboard, as a process-local clipboard.
 *
 * WHY THIS EXISTS AT ALL: -pasteboardWithName: returning nil is not a degraded clipboard, it is a
 * dead application. LibreOffice asks for the general pasteboard while it builds its first frame,
 * and the nil comes back inside a constructor that cannot report it, so the whole start collapses
 * into "Unspecified Application Error" with nothing naming the clipboard anywhere. That was the
 * exact wall this file removes, and the log line that proved it was the last one printed before
 * the exit.
 *
 * WHAT IT DOES NOT DO YET: talk to other applications. That is wl_data_device, which needs a
 * wl_seat, and it is a genuinely separate piece of work with a protocol of its own. Copy and paste
 * WITHIN the application is the whole of what this provides, and that is most of what a document
 * editor does with a clipboard anyway. The X11 backend gets cross-application transfer by owning a
 * selection; the note in the header is where the Wayland equivalent goes.
 *
 * The shape is X11Pasteboard with every X call removed. That is deliberate: it keeps the two
 * readable side by side, so whoever adds wl_data_device can see precisely which methods grow a
 * transport and which are pure bookkeeping.
 */
#import <AppKit/NSPasteboard.h>
#import <Foundation/Foundation.h>

@interface WaylandPasteboard : NSPasteboard {
    NSPasteboardName _name;
    NSMutableDictionary<NSPasteboardType, NSData *> *_typeToData;
    NSMutableDictionary<NSPasteboardType, id<NSPasteboardTypeOwner>> *_typeToOwner;
    NSInteger _changeCount;
}
+ (WaylandPasteboard *) pasteboardWithName: (NSPasteboardName) name;
- (instancetype) initWithName: (NSPasteboardName) name;
@end

@implementation WaylandPasteboard

/* One pasteboard per name, for the life of the process. NSPasteboard is an identity: two lookups
 * of the same name have to answer the same object or a copy and the paste that follows it end up
 * talking to different clipboards. */
static NSMutableDictionary<NSPasteboardName, WaylandPasteboard *> *nameToPboard;

+ (WaylandPasteboard *) pasteboardWithName: (NSPasteboardName) name {
    @synchronized([WaylandPasteboard class]) {
        if (nameToPboard == nil) {
            nameToPboard = [NSMutableDictionary new];
        }
        if (name == nil) {
            name = NSGeneralPboard;
        }
        WaylandPasteboard *existing = nameToPboard[name];
        if (existing == nil) {
            existing = [[WaylandPasteboard alloc] initWithName: name];
            nameToPboard[name] = existing;
        }
        return existing;
    }
}

- (instancetype) initWithName: (NSPasteboardName) name {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _name = [name retain];
    _typeToData = [NSMutableDictionary new];
    _typeToOwner = [NSMutableDictionary new];
    _changeCount = 0;
    return self;
}

- (void) dealloc {
    [_name release];
    [_typeToData release];
    [_typeToOwner release];
    [super dealloc];
}

- (NSString *) name {
    return _name;
}

- (NSInteger) changeCount {
    return _changeCount;
}

- (NSInteger) clearContents {
    _changeCount++;
    /* The owners are told BEFORE the tables are emptied, because an owner is allowed to write its
     * data back into this pasteboard while it is being told, and clearing afterwards would throw
     * away exactly that. */
    for (id owner in [_typeToOwner allValues]) {
        if ([owner respondsToSelector: @selector(pasteboardChangedOwner:)]) {
            [owner pasteboardChangedOwner: self];
        }
    }
    [_typeToOwner removeAllObjects];
    [_typeToData removeAllObjects];
    return _changeCount;
}

- (NSInteger) addTypes: (NSArray<NSPasteboardType> *) types
                 owner: (id<NSPasteboardTypeOwner>) owner
{
    for (NSPasteboardType type in types) {
        [_typeToData removeObjectForKey: type];
        if (owner != nil) {
            _typeToOwner[type] = owner;
        }
    }
    return _changeCount;
}

- (NSInteger) declareTypes: (NSArray<NSPasteboardType> *) types
                     owner: (id<NSPasteboardTypeOwner>) owner
{
    [self clearContents];
    return [self addTypes: types owner: owner];
}

- (BOOL) setData: (NSData *) data forType: (NSPasteboardType) type {
    if (data == nil || type == nil) {
        return NO;
    }
    /* Retain through the dictionary BEFORE dropping the owner: the owner may be the very object
     * that just produced this data, and releasing it first can take the data with it. */
    _typeToData[type] = data;
    [_typeToOwner removeObjectForKey: type];
    return YES;
}

- (BOOL) setString: (NSString *) string forType: (NSPasteboardType) type {
    if (string == nil) {
        return NO;
    }
    NSStringEncoding encoding = NSUnicodeStringEncoding;
    if ([type isEqual: NSStringPboardType]) {
        encoding = NSUTF8StringEncoding;
    }
    return [self setData: [string dataUsingEncoding: encoding] forType: type];
}

- (NSData *) dataForType: (NSPasteboardType) type {
    if (type == nil) {
        return nil;
    }
    /* LAZY OWNERS ARE THE NORMAL CASE, not an edge one: a promise is how an application avoids
     * rendering every representation of a large selection at copy time. Asking the owner here is
     * what turns a promised type into bytes, and it answers into -setData:forType: above. */
    id<NSPasteboardTypeOwner> owner = _typeToOwner[type];
    if (owner != nil) {
        [owner pasteboard: self provideDataForType: type];
    }
    return _typeToData[type];
}

- (NSString *) stringForType: (NSPasteboardType) type {
    NSData *data = [self dataForType: type];
    if (data == nil) {
        return nil;
    }
    NSStringEncoding encoding = NSUnicodeStringEncoding;
    if ([type isEqual: NSStringPboardType]) {
        encoding = NSUTF8StringEncoding;
    }
    return [[[NSString alloc] initWithData: data encoding: encoding] autorelease];
}

- (NSArray<NSPasteboardType> *) types {
    return [[_typeToData allKeys] arrayByAddingObjectsFromArray: [_typeToOwner allKeys]];
}

- (NSPasteboardType) availableTypeFromArray: (NSArray<NSPasteboardType> *) types {
    NSArray<NSPasteboardType> *mine = [self types];
    for (NSPasteboardType type in types) {
        if ([mine containsObject: type]) {
            return type;
        }
    }
    return nil;
}

/* NSDisplay reaches windows through -delegate in a couple of places and a pasteboard can land
 * there by identity. nil is the honest answer and keeps it out of window paths. */
- (id) delegate {
    return nil;
}

@end

/* The C entry point the Rust side calls. A class lookup by name from Rust would work equally well;
 * a function keeps the class name out of the caller and gives the linker something to complain
 * about if this file is ever dropped from the bundle. */
id cider_wayland_pasteboard_with_name(id name)
{
    return [WaylandPasteboard pasteboardWithName: (NSPasteboardName) name];
}
