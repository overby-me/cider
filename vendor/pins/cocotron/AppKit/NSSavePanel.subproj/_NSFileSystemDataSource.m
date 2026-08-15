#import "_NSFileSystemDataSource.h"
#import <AppKit/NSOutlineView.h>

@implementation _NSFileSystemDataSource

@synthesize showsHiddenFiles = _showsHiddenFiles;

- (id) init {
    self = [super init];
    _cachedPaths = [[NSMutableSet alloc] init];
    _fileManager = [[NSFileManager defaultManager] retain];
    _children = [[NSMutableDictionary alloc] init];
    return self;
}

- (void) dealloc {
    [_cachedPaths release];
    [_fileManager release];
    [_children release];
    [super dealloc];
}

- (void) invalidateChildren {
    [_children removeAllObjects];
}

- (void) setShowsHiddenFiles: (BOOL) value {
    if (value != _showsHiddenFiles) {
        _showsHiddenFiles = value;
        [self invalidateChildren];
    }
}

/*
 * WHAT IS IN A DIRECTORY, ONCE, IN ORDER.
 *
 * Read once and kept, because an outline view asks for the number of children and then for each
 * child by index: the old code called -contentsOfDirectoryAtURL: in both, so a directory with forty
 * entries was read forty one times to draw one screen, and again for every reload.
 *
 * SORTED, which the old code left as a TODO and it shows: the panel listed whatever order the file
 * system handed back, so the same directory came out differently on different machines and nothing
 * could be found by eye. Finder sorts by name, case insensitively, folders and files together.
 *
 * HIDDEN NAMES SKIPPED unless the panel asks for them. macOS does not put dot files in a save
 * panel, and ours opened on .ciderd.sock and .init.pid.
 */
- (NSArray *) _childrenOfURL: (NSURL *) url {
    NSString *key = [url path];

    if (key == nil) {
        key = @"/";
    }

    NSArray *cached = [_children objectForKey: key];

    if (cached != nil) {
        return cached;
    }

    NSArray *items = [_fileManager contentsOfDirectoryAtURL: url
                                 includingPropertiesForKeys: nil
                                                    options: 0
                                                      error: nil];
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity: [items count]];
    NSInteger i, count = [items count];

    for (i = 0; i < count; i++) {
        NSURL *item = [items objectAtIndex: i];
        NSString *name = [[item pathComponents] lastObject];

        if (!_showsHiddenFiles && [name hasPrefix: @"."]) {
            continue;
        }
        [visible addObject: item];
    }

    [visible sortUsingComparator: ^NSComparisonResult(id a, id b) {
        return [(NSString *) [[a pathComponents] lastObject]
                localizedCaseInsensitiveCompare: [[b pathComponents] lastObject]];
    }];

    NSArray *result = [[visible copy] autorelease];

    [_children setObject: result forKey: key];
    return result;
}

- (NSInteger) outlineView: (NSOutlineView *) outlineView
        numberOfChildrenOfItem: (NSURL *) url
{

    if (url == nil) {
        url = [NSURL URLWithString: @"/"];
    }
    return [[self _childrenOfURL: url] count];
}

- (BOOL) outlineView: (NSOutlineView *) outlineView
        isItemExpandable: (NSURL *) url
{

    if (url == nil) {
        return YES;
    }

    BOOL isDirectory;
    [_fileManager fileExistsAtPath: [url path] isDirectory: &isDirectory];
    return isDirectory;
}

- (NSURL *) outlineView: (NSOutlineView *) outlineView
                  child: (NSInteger) index
                 ofItem: (NSURL *) url
{

    if (url == nil) {
        url = [NSURL URLWithString: @"/"];
    }

    NSArray *items = [self _childrenOfURL: url];

    if (index < 0 || index >= (NSInteger) [items count]) {
        return nil;
    }

    NSURL *preRes = [items objectAtIndex: index];
    NSURL *res = [_cachedPaths member: preRes];
    if (res == nil) {
        [_cachedPaths addObject: preRes];
        res = preRes;
    }

    return res;
}

- (NSString *) outlineView: (NSOutlineView *) outlineView
        objectValueForTableColumn: (NSTableColumn *) tableColumn
                           byItem: (NSURL *) url
{
    return [[url pathComponents] lastObject];
}

@end
