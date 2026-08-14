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

/* The Rust side of the system selection. See src/darwin/wayland/clipboard.rs: publishing takes
 * ownership of the Wayland selection, and reading asks whoever owns it to write down a pipe. */
extern int cider_wayland_clipboard_set_text(const unsigned char *bytes, size_t len);
extern int cider_wayland_clipboard_declare(void);
extern ssize_t cider_wayland_clipboard_get_text(unsigned char *out, size_t cap);

@interface WaylandPasteboard : NSPasteboard {
    NSPasteboardName _name;
    NSMutableDictionary<NSPasteboardType, NSData *> *_typeToData;
    NSMutableDictionary<NSPasteboardType, id<NSPasteboardTypeOwner>> *_typeToOwner;
    NSInteger _changeCount;
}
+ (WaylandPasteboard *) pasteboardWithName: (NSPasteboardName) name;
- (instancetype) initWithName: (NSPasteboardName) name;
- (NSData *) _localDataForType: (NSPasteboardType) type;
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
    /* DECLARING IS COPYING, for an application that promises rather than renders.
     *
     * LibreOffice never calls -setData:forType: at copy time: it declares the types it COULD
     * produce and waits to be asked, which is why publishing from setData caught nothing at all.
     * Wayland works the same way -- a source advertises MIME types and is asked to write the bytes
     * later -- so the two lazinesses line up exactly: take the selection here, render in the send
     * callback, and a copy nobody ever pastes costs one protocol message and no work. */
    if ([_name isEqual: NSGeneralPboard]) {
        for (NSPasteboardType type in types) {
            if ([type isEqual: NSStringPboardType] || [type isEqual: NSPasteboardTypeString]) {
                cider_wayland_clipboard_declare();
                break;
            }
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
    [self _publishToSystemSelection: type];
    return YES;
}

/* OUT OF THE APPLICATION, which is the half this file used to say it did not do.
 *
 * Only the GENERAL pasteboard, because that is the one that means "the clipboard" to the rest of
 * the desktop; a private pasteboard an application uses for its own drag or find state is not the
 * users clipboard and publishing it would overwrite what they copied.
 *
 * Only text, and only when it converts. A selection carries a dozen representations -- RTF, ODF,
 * an image -- and the ones another application is most likely to want are the ones we can name in
 * MIME terms without inventing a mapping. */
- (void) _publishToSystemSelection: (NSPasteboardType) type {
    if (![_name isEqual: NSGeneralPboard]) {
        return;
    }
    if (!([type isEqual: NSStringPboardType] || [type isEqual: NSPasteboardTypeString])) {
        return;
    }
    NSString *string = [self stringForType: type];
    if ([string length] == 0) {
        return;
    }
    NSData *utf8 = [string dataUsingEncoding: NSUTF8StringEncoding];
    if ([utf8 length] == 0) {
        return;
    }
    cider_wayland_clipboard_set_text([utf8 bytes], [utf8 length]);
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

/* WHAT THIS PROCESS HAS, asking the owner if the type was promised, and NEVER asking the rest of
 * the desktop. Serving a system paste request has to use this and not -dataForType:, or answering
 * "what have you got" would ask the system, which would ask us, and so on. */
- (NSData *) _localDataForType: (NSPasteboardType) type {
    if (type == nil) {
        return nil;
    }
    id<NSPasteboardTypeOwner> owner = _typeToOwner[type];
    if (owner != nil) {
        [owner pasteboard: self provideDataForType: type];
    }
    return _typeToData[type];
}

- (NSData *) dataForType: (NSPasteboardType) type {
    if (type == nil) {
        return nil;
    }
    /* LAZY OWNERS ARE THE NORMAL CASE, not an edge one: a promise is how an application avoids
     * rendering every representation of a large selection at copy time. Asking the owner here is
     * what turns a promised type into bytes, and it answers into -setData:forType: above. */
    NSData *mine = [self _localDataForType: type];
    if (mine != nil) {
        return mine;
    }
    /* INTO THE APPLICATION. Nothing of ours under this type, so whatever the rest of the desktop
     * has copied is the honest answer -- that is what the user means by paste. Asked here rather
     * than kept in step with every selection event, because the transfer is a pipe the other
     * application writes when asked, and doing it on demand means no work at all for a session
     * that never pastes. */
    if ([_name isEqual: NSGeneralPboard] &&
        ([type isEqual: NSStringPboardType] || [type isEqual: NSPasteboardTypeString])) {
        unsigned char buffer[64 * 1024];
        ssize_t got = cider_wayland_clipboard_get_text(buffer, sizeof(buffer));
        if (got > 0) {
            NSString *string = [[[NSString alloc] initWithBytes: buffer
                                                        length: (NSUInteger) got
                                                      encoding: NSUTF8StringEncoding] autorelease];
            if (string != nil) {
                NSStringEncoding encoding = [type isEqual: NSStringPboardType]
                        ? NSUTF8StringEncoding
                        : NSUnicodeStringEncoding;
                return [string dataUsingEncoding: encoding];
            }
        }
    }
    return nil;
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
    NSArray<NSPasteboardType> *mine =
            [[_typeToData allKeys] arrayByAddingObjectsFromArray: [_typeToOwner allKeys]];
    /* An application asks what is on the clipboard BEFORE it asks for the bytes, and enables or
     * greys out its Paste command on the answer. A general pasteboard with nothing of ours in it
     * still has whatever the desktop copied, so string has to be in this list or Paste is never
     * even offered. */
    if ([_name isEqual: NSGeneralPboard] && [mine count] == 0) {
        if (cider_wayland_clipboard_get_text(NULL, 0) != 0) {
            return @[ NSStringPboardType ];
        }
    }
    return mine;
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

/* WE LOST THE CLIPBOARD, called from the Wayland cancelled callback.
 *
 * Another application copied, so what this pasteboard is holding is STALE and must not be handed
 * to the next paste: the user copied somewhere else and expects that. Emptying the tables is what
 * makes the general pasteboard fall through to the system selection, and bumping the change count
 * is how an application that caches its own view of the clipboard learns to look again. */
void cider_wayland_pasteboard_dropped(void)
{
    WaylandPasteboard *board = [WaylandPasteboard pasteboardWithName: NSGeneralPboard];
    if (board != nil) {
        [board clearContents];
    }
}

/* RENDERING THE PROMISE, called from the Wayland send callback when another application pastes.
 *
 * Returns a malloc block the caller frees, because the autoreleased NSData behind it belongs to a
 * pool this function does not control and the bytes have to outlive the call. */
unsigned char *cider_wayland_pasteboard_general_utf8(size_t *out_len)
{
    if (out_len != NULL) {
        *out_len = 0;
    }
    WaylandPasteboard *board = [WaylandPasteboard pasteboardWithName: NSGeneralPboard];
    if (board == nil) {
        return NULL;
    }
    NSData *data = [board _localDataForType: NSStringPboardType];
    NSString *string = nil;
    if (data != nil) {
        string = [[[NSString alloc] initWithData: data
                                        encoding: NSUTF8StringEncoding] autorelease];
    }
    if (string == nil) {
        data = [board _localDataForType: NSPasteboardTypeString];
        if (data != nil) {
            string = [[[NSString alloc] initWithData: data
                                            encoding: NSUnicodeStringEncoding] autorelease];
        }
    }
    if ([string length] == 0) {
        return NULL;
    }
    NSData *utf8 = [string dataUsingEncoding: NSUTF8StringEncoding];
    if ([utf8 length] == 0) {
        return NULL;
    }
    unsigned char *copy = malloc([utf8 length]);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, [utf8 bytes], [utf8 length]);
    if (out_len != NULL) {
        *out_len = [utf8 length];
    }
    return copy;
}
