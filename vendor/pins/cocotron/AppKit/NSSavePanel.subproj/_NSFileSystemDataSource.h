#import <Foundation/Foundation.h>

@interface _NSFileSystemDataSource : NSObject {
    NSMutableSet *_cachedPaths;
    NSFileManager *_fileManager;

    /* The children of each directory the panel has looked at, sorted, keyed by path. The outline
     * view asks for a count and then for each child by index, so without this every row read the
     * whole directory again: N rows meant N + 1 directory reads and N + 1 arrays of NSURL. */
    NSMutableDictionary *_children;

    /* Whether names beginning with a dot are listed. macOS hides them, and the panel was showing
     * .ciderd.sock and .init.pid above the first real file. */
    BOOL _showsHiddenFiles;
}

@property BOOL showsHiddenFiles;

- (void) invalidateChildren;

@end
