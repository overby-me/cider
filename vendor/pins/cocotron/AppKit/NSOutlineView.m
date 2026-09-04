/* Copyright (c) 2006-2007 Christopher J. W. Lloyd <cjwl@objc.net>

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

#import <AppKit/NSButtonCell.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContextFunctions.h>
#import <AppKit/NSGraphicsStyle.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSImageCell.h>
#import <AppKit/NSInterfaceStyle.h>
#import <AppKit/NSOutlineView.h>
#include <stdio.h>
#include <stdlib.h>
#import <objc/runtime.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTextFieldCell.h>
#import <Foundation/NSKeyedArchiver.h>

/* The delegate protocol in this port does not carry this one, and without a declaration the
 * compiler reads its answer as an id. */
@interface NSObject (CiderOutlineRowHeight)
- (CGFloat) outlineView: (NSOutlineView *) outlineView heightOfRowByItem: (id) item;
@end

NSString *const NSOutlineViewItemWillExpandNotification =
        @"NSOutlineViewItemWillExpandNotification";
NSString *const NSOutlineViewItemDidExpandNotification =
        @"NSOutlineViewItemDidExpandNotification";
NSString *const NSOutlineViewItemWillCollapseNotification =
        @"NSOutlineViewItemWillCollapseNotification";
NSString *const NSOutlineViewItemDidCollapseNotification =
        @"NSOutlineViewItemDidCollapseNotification";

NSString *const NSOutlineViewColumnDidMoveNotification =
        @"NSOutlineViewColumnDidMoveNotification";
NSString *const NSOutlineViewColumnDidResizeNotification =
        @"NSOutlineViewColumnDidResizeNotification";

NSString *const NSOutlineViewSelectionDidChangeNotification =
        @"NSOutlineViewSelectionDidChangeNotification";
NSString *const NSOutlineViewSelectionIsChangingNotification =
        @"NSOutlineViewSelectionIsChangingNotification";

NSString *const NSOutlineViewDisclosureButtonKey =
        @"NSOutlineViewDisclosureButtonKey";

// We probably don't want this public, but NSOutlineView needs it, and it would
// prove invaluable to other subclasses of NSTableView.
@interface NSTableView (NSTableView_notifications)

- (BOOL) delegateShouldSelectTableColumn: (NSTableColumn *) tableColumn;
- (BOOL) delegateShouldSelectRow: (NSInteger) row;
- (BOOL) delegateShouldEditTableColumn: (NSTableColumn *) tableColumn
                                   row: (NSInteger) row;
- (BOOL) delegateSelectionShouldChange;
- (void) noteSelectionIsChanging;
- (void) noteSelectionDidChange;
- (void) noteColumnDidResizeWithOldWidth: (CGFloat) oldWidth;
- (id) dataSourceObjectValueForTableColumn: (NSTableColumn *) tableColumn
                                       row: (NSInteger) row;
- (BOOL) dataSourceCanSetObjectValue;
- (void) dataSourceSetObjectValue: (id) object
                   forTableColumn: (NSTableColumn *) tableColumn
                              row: (NSInteger) row;

- (void) drawHighlightedSelectionForColumn: (NSInteger) column
                                       row: (NSInteger) row
                                    inRect: (NSRect) rect;

@end

/*
 * A BACKGROUND THAT IS NOT OPAQUE MUST NOT BE COPIED. NSRectFill composites with copy, so filling
 * with a colour that has alpha means REPLACING the backing with it rather than laying it over what
 * is there. For a clear background, which is what a nib means by "let what is behind show through",
 * copy erases the window instead: Swift Publisher's layers table punched a transparent hole 220 by
 * 56 that read as a solid black rectangle (task #134).
 *
 * CIDER_TRACE_BGFILL names every site that fills a background with a translucent colour, so this
 * rule can be measured rather than assumed.
 */
static void CiderFillBackground(NSColor *color, NSRect rect, const char *where) {
    CGFloat alpha = color == nil ? 0.0 : [color alphaComponent];

    [color setFill];
    if (alpha < 1.0) {
        const char *trace = getenv("CIDER_TRACE_BGFILL");

        if (trace != NULL && trace[0] != (char) 0) {
            fprintf(stderr, "CIDER_BGFILL %s alpha=%.3f rect=%.0fx%.0f@%.0f,%.0f\n", where,
                    (double) alpha, rect.size.width, rect.size.height, rect.origin.x,
                    rect.origin.y);
            fflush(stderr);
        }
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
    } else {
        NSRectFill(rect);
    }
}

@implementation NSOutlineView

static inline BOOL isItemExpanded(NSOutlineView *self, id item) {
    return (BOOL)((unsigned) NSMapGet(self->_itemToExpansionState, item));
}

static inline NSInteger numberOfChildrenOfItemAndReload(NSOutlineView *self,
                                                        id item, BOOL reload)
{
    NSInteger result;

    if (!reload)
        result = (NSInteger) NSMapGet(self->_itemToNumberOfChildren, item);
    else {
        result = [self->_dataSource outlineView: self
                         numberOfChildrenOfItem: item];

        NSMapInsert(self->_itemToNumberOfChildren, item, (void *) result);
    }

    return result;
}

static inline id childOfItemAtIndex(NSOutlineView *self, id item,
                                    NSInteger index)
{
#if 1
    // NSLog(@"%s %d",__FILE__,__LINE__);
    id result = [self->_dataSource outlineView: self child: index ofItem: item];

    // NSLog(@"item %@ child %d = %@",item,index,result);

    return result;
#else // broken
    if (item == nil)
        return [self->_dataSource outlineView: self child: index ofItem: item];
    else {
        NSInteger row = (NSInteger) NSMapGet(self->_itemToRow, item);

        return (id) NSMapGet(self->_rowToItem, (void *) (row + 1 + index));
    }
#endif
}

- (void) encodeWithCoder: (NSCoder *) coder {
    NSUnimplementedMethod();
}

- (void) invalidateRowCache {
    _numberOfCachedRows = 0;
}

- initWithCoder: (NSCoder *) coder {
    [super initWithCoder: coder];

    if ([coder allowsKeyedCoding]) {
        NSKeyedUnarchiver *keyed = (NSKeyedUnarchiver *) coder;

        _rowToItem = NSCreateMapTable(NSIntegerMapKeyCallBacks,
                                      NSNonOwnedPointerMapValueCallBacks, 0);
        _itemToRow = NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                      NSIntegerMapValueCallBacks, 0);
        _itemToParent = NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                         NSNonOwnedPointerMapValueCallBacks, 0);
        _itemToLevel = NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                        NSIntegerMapValueCallBacks, 0);
        _itemToExpansionState =
                NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                 NSIntegerMapValueCallBacks, 0);
        _itemToNumberOfChildren =
                NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                 NSIntegerMapValueCallBacks, 0);

        _markerCell = [[NSButtonCell alloc] initImageCell: nil];
        [_markerCell setBezelStyle: NSDisclosureBezelStyle];

        [self setIndentationPerLevel: _standardRowHeight]; // square it off

        [self setIndentationMarkerFollowsCell: YES];
        [self setAutoresizesOutlineColumn: YES];
        [self setAutosaveExpandedItems: NO];

        _editingCellPadding = 10.0;

        [self invalidateRowCache];

        _outlineTableColumn = [[[self tableColumns] objectAtIndex: 0] retain];
    } else {
        [NSException raise: NSInvalidArgumentException
                    format: @"-[%@ %s] is not implemented for coder %@",
                            [self class], sel_getName(_cmd), coder];
    }
    return self;
}

- (id) initWithFrame: (NSRect) frame {
    [super initWithFrame: frame];
    _rowToItem = NSCreateMapTable(NSIntegerMapKeyCallBacks,
                                  NSNonOwnedPointerMapValueCallBacks, 0);
    _itemToRow = NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                  NSIntegerMapValueCallBacks, 0);
    _itemToParent = NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                     NSNonOwnedPointerMapValueCallBacks, 0);
    _itemToLevel = NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                                    NSIntegerMapValueCallBacks, 0);
    _itemToExpansionState =
            NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                             NSIntegerMapValueCallBacks, 0);
    _itemToNumberOfChildren =
            NSCreateMapTable(NSNonOwnedPointerOrNullMapKeyCallBacks,
                             NSIntegerMapValueCallBacks, 0);

    _markerCell = [[NSButtonCell alloc] initImageCell: nil];
    [_markerCell setBezelStyle: NSDisclosureBezelStyle];

    [self setIndentationPerLevel: _standardRowHeight]; // square it off

    [self setIndentationMarkerFollowsCell: YES];
    [self setAutoresizesOutlineColumn: YES];
    [self setAutosaveExpandedItems: NO];

    _editingCellPadding = 10.0;

    [self invalidateRowCache];

    return self;
}

- (void) dealloc {
    NSFreeMapTable(_rowToItem);
    NSFreeMapTable(_itemToRow);
    NSFreeMapTable(_itemToParent);
    NSFreeMapTable(_itemToLevel);
    NSFreeMapTable(_itemToExpansionState);
    NSFreeMapTable(_itemToNumberOfChildren);

    [_markerCell release];
    [_outlineTableColumn release];

    [super dealloc];
}

- (NSTableColumn *) outlineTableColumn {
    return _outlineTableColumn;
}

- itemAtRow: (NSInteger) row {
    return (id) NSMapGet(_rowToItem, (void *) row);
}

- (NSInteger) rowForItem: (id) item {
    return (NSInteger) NSMapGet(_itemToRow, item);
}

- parentForItem: item {
    return NSMapGet(_itemToParent, item);
}

- (BOOL) isExpandable: (id) item {
    return [_dataSource outlineView: self isItemExpandable: item];
}

- (NSInteger) levelForItem: (id) item {
    NSInteger level = (NSInteger) NSMapGet(_itemToLevel, item);
    return level;
}

- (NSInteger) levelForRow: (NSInteger) row {
    return [self levelForItem: [self itemAtRow: row]];
}

- (BOOL) isItemExpanded: (id) item {
    return isItemExpanded(self, item);
}

- (CGFloat) indentationPerLevel {
    return _indentationPerLevel;
}

- (BOOL) autoresizesOutlineColumn {
    return _autoresizesOutlineColumn;
}

- (BOOL) indentationMarkerFollowsCell {
    return _indentationMarkerFollowsCell;
}

- (BOOL) autosaveExpandedItems {
    return _autosaveExpandedItems;
}

- (void) setOutlineTableColumn: (NSTableColumn *) tableColumn {
    [_outlineTableColumn release];
    _outlineTableColumn = [tableColumn retain];
}

- (void) setIndentationPerLevel: (CGFloat) value {
    _indentationPerLevel = value;
}

- (void) setAutoresizesOutlineColumn: (BOOL) flag {
    _autoresizesOutlineColumn = flag;
}

- (void) setIndentationMarkerFollowsCell: (BOOL) flag {
    _indentationMarkerFollowsCell = flag;
}

- (void) setAutosaveExpandedItems: (BOOL) flag {
    _autosaveExpandedItems = flag;
}

- (BOOL) _delayResizeButExpandItem: (id) item
                    expandChildren: (BOOL) expandChildren
{
    BOOL noteNumberOfRowsChanged = NO;
    BOOL expandThisItem = YES;

    if (![self isExpandable: item])
        return YES;

    if ([_delegate respondsToSelector: @selector(outlineView:
                                               shouldExpandItem:)])
        if ([_delegate outlineView: self shouldExpandItem: item] == NO)
            expandThisItem = NO;

    if (expandThisItem) {
        NSDictionary *userInfo = [NSDictionary
                dictionaryWithObjectsAndKeys: item, @"NSObject", nil];
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSOutlineViewItemWillExpandNotification
                              object: self
                            userInfo: userInfo];

        NSMapInsert(_itemToExpansionState, item, (void *) YES);

        [self invalidateRowCache];
        noteNumberOfRowsChanged = YES;

        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSOutlineViewItemDidExpandNotification
                              object: self
                            userInfo: userInfo];
    }

    if (expandChildren) {
        int i, numberOfChildren =
                       numberOfChildrenOfItemAndReload(self, item, YES);

        for (i = 0; i < numberOfChildren; ++i) {
            id child = [_dataSource outlineView: self child: i ofItem: item];

            if ([self _delayResizeButExpandItem: child expandChildren: YES])
                noteNumberOfRowsChanged = YES;
        }
    }

    return YES;
}

- _objectValueForTableColumn: (NSTableColumn *) column byItem: (id) item {
    if ([_dataSource respondsToSelector: @selector
                     (outlineView:objectValueForTableColumn:byItem:)])
        return [_dataSource outlineView: self
                objectValueForTableColumn: column
                                   byItem: item];

    // FIXME: Does it actually send this to the delegate too?
    if ([_delegate respondsToSelector: @selector
                   (outlineView:objectValueForTableColumn:byItem:)])
        return [_delegate outlineView: self
                objectValueForTableColumn: column
                                   byItem: item];

    return nil;
}

- (void) _tightenUpColumn: (NSTableColumn *) column forItem: (id) item {
    CGFloat minWidth = [column width], width;
    NSInteger rootLevel = [self levelForItem: item];
    NSInteger i = [self rowForItem: item] + 1,
              numberOfRows = [self numberOfRows];

    for (; i < numberOfRows; i++) {
        NSCell *dataCell = [column dataCellForRow: i];
        id item = [self itemAtRow: i];
        NSInteger level = [self levelForItem: item];

        if (level <= rootLevel)
            break;

        id objectValue = [self _objectValueForTableColumn: column byItem: item];
        if (objectValue != nil)
            [dataCell setObjectValue: objectValue];

        width = [[dataCell attributedStringValue] size].width +
                level * _indentationPerLevel;

        if (width > minWidth)
            minWidth = width;
    }
    width = [[[column headerCell] attributedStringValue] size].width;
    if (width > minWidth)
        minWidth = width;

    [column setMinWidth: minWidth];
}

- (void) _tightenUpColumn: (NSTableColumn *) column {
    [self _tightenUpColumn: column forItem: [self itemAtRow: 0]];
}

- (void) expandItem: (id) item expandChildren: (BOOL) expandChildren {
    if ([self _delayResizeButExpandItem: item expandChildren: expandChildren]) {
        [self noteNumberOfRowsChanged];
        if (_autoresizesOutlineColumn) {
            [self _tightenUpColumn: _outlineTableColumn forItem: item];
            if ([_outlineTableColumn width] < [_outlineTableColumn minWidth])
                [_outlineTableColumn setWidth: [_outlineTableColumn minWidth]];
        }
        [self setNeedsDisplay: YES];
    }
}

- (void) expandItem: (id) item {
    [self expandItem: item expandChildren: NO];
}

- (void) collapseItem: (id) item collapseChildren: (BOOL) collapseChildren {
    BOOL collapseThisItem = YES;

    if ([_delegate respondsToSelector: @selector(outlineView:
                                               shouldCollapseItem:)])
        if ([_delegate outlineView: self shouldCollapseItem: item] == NO)
            collapseThisItem = NO;

    if (collapseThisItem) {
        NSDictionary *userInfo = [NSDictionary
                dictionaryWithObjectsAndKeys: item, @"NSObject", nil];
        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSOutlineViewItemWillCollapseNotification
                              object: self
                            userInfo: userInfo];

        NSMapInsert(_itemToExpansionState, item, (void *) NO);

        [self invalidateRowCache];
        [self noteNumberOfRowsChanged];

        [[NSNotificationCenter defaultCenter]
                postNotificationName: NSOutlineViewItemDidCollapseNotification
                              object: self
                            userInfo: userInfo];
    }

    if (collapseChildren) {
        NSInteger i, numberOfChildren =
                             numberOfChildrenOfItemAndReload(self, item, YES);

        for (i = 0; i < numberOfChildren; ++i) {
            id child = [_dataSource outlineView: self child: i ofItem: item];

            [self collapseItem: child collapseChildren: YES];
        }
    }

    if (_autoresizesOutlineColumn) {
        [self _tightenUpColumn: _outlineTableColumn];
    }
    [self setNeedsDisplay: YES];
}

- (void) collapseItem: (id) item {
    [self collapseItem: item collapseChildren: NO];
}

- (void) _resetMapTables {
    NSResetMapTable(_rowToItem);
    NSResetMapTable(_itemToRow);
    NSResetMapTable(_itemToParent);
    NSResetMapTable(_itemToLevel);
    // NSResetMapTable(_itemToExpansionState);
    NSResetMapTable(_itemToNumberOfChildren);
}

- (void) reloadData {
    [self _resetMapTables];
    [self invalidateRowCache];
    [super reloadData];
}

/*
 * THE ANIMATED TREE EDITS, which here are not animated.
 *
 * macOS moves the affected rows with an animation and leaves the rest alone. Nothing here animates,
 * and the tree this view keeps is rebuilt from the data source anyway, so each of these asks for
 * that rebuild. The CONTENT ends up right, which is what a caller depends on; the animation is what
 * is lost. iA Writer brackets its library edits with beginUpdates and raised on the missing
 * selector before any of them ran.
 */
- (void) insertItemsAtIndexes: (NSIndexSet *) indexes
                     inParent: (id) parent
                withAnimation: (NSUInteger) animation
{
    [self reloadData];
}

- (void) removeItemsAtIndexes: (NSIndexSet *) indexes
                     inParent: (id) parent
                withAnimation: (NSUInteger) animation
{
    [self reloadData];
}

- (void) moveItemAtIndex: (NSInteger) fromIndex
                inParent: (id) oldParent
                 toIndex: (NSInteger) toIndex
                inParent: (id) newParent
{
    [self reloadData];
}

- (void) reloadItem: (id) item reloadChildren: (BOOL) reloadChildren {
    [self _resetMapTables];
    [self invalidateRowCache];
    [self noteNumberOfRowsChanged];
    [self setNeedsDisplay: YES];
}

- (void) reloadItem: (id) item {
    [self reloadItem: item reloadChildren: NO];
}

- (void) setDropItem: (id) item dropChildIndex: (NSInteger) index {
    NSUnimplementedMethod();
}

- (BOOL) shouldCollapseAutoExpandedItemsForDeposited: (BOOL) collapse {
    if (collapse)
        return NO;

    return YES;
}

// override for new outline-related selectors.
// FIX: Cocoa checks for selectors as they are needed, see -[NSTableView
// setDataSource].
- (BOOL) stronglyReferencesItems {
    return _stronglyReferencesItems;
}

- (void) setStronglyReferencesItems: (BOOL) strongly {
    _stronglyReferencesItems = strongly;
}

- (void) setDataSource: dataSource {
    /*
     * THREE, NOT FOUR. objectValueForTableColumn:byItem: is what a CELL based outline view asks for,
     * and a view based one never does: its delegate hands back views from
     * outlineView:viewForTableColumn:item: instead. Demanding it here rejected a data source macOS
     * accepts, and iA Writer died on exactly that with its library outline.
     *
     * Nothing downstream needs it either: -_objectValueForTableColumn:byItem: above already asks
     * the data source, then the delegate, and answers nil when neither implements it.
     *
     * The other three describe the TREE, and an outline view cannot do anything without them.
     */
    SEL requiredSelectors[] = {@selector(outlineView:child:ofItem:),
                               @selector(outlineView:isItemExpandable:),
                               @selector(outlineView:numberOfChildrenOfItem:),
                               NULL};
    NSInteger i;

    for (i = 0; requiredSelectors[i] != NULL; ++i)
        if (dataSource != nil &&
            ![dataSource respondsToSelector: requiredSelectors[i]])
            [NSException
                     raise: NSInternalInconsistencyException
                    format: @"NSOutlineView dataSource does not respond to %@",
                            NSStringFromSelector(requiredSelectors[i])];

    _dataSource = dataSource;
}

- (void) setDelegate: delegate {
    struct {
        NSString *name;
        SEL selector;
    } notes[] = {{NSOutlineViewItemWillExpandNotification,
                  @selector(outlineViewItemWillExpand:)},
                 {NSOutlineViewItemDidExpandNotification,
                  @selector(outlineViewItemDidExpand:)},
                 {NSOutlineViewItemWillCollapseNotification,
                  @selector(outlineViewItemWillCollapse:)},
                 {NSOutlineViewItemDidCollapseNotification,
                  @selector(outlineViewItemDidCollapse:)},
                 {NSOutlineViewColumnDidMoveNotification,
                  @selector(outlineViewColumnDidMove:)},
                 {NSOutlineViewColumnDidResizeNotification,
                  @selector(outlineViewColumnDidResize:)},
                 {NSOutlineViewSelectionIsChangingNotification,
                  @selector(outlineViewSelectionIsChanging:)},
                 {NSOutlineViewSelectionDidChangeNotification,
                  @selector(outlineViewSelectionDidChange:)},
                 {nil, NULL}};
    NSInteger i;

    if (_delegate != nil)
        for (i = 0; notes[i].name != nil; ++i)
            [[NSNotificationCenter defaultCenter] removeObserver: _delegate
                                                            name: notes[i].name
                                                          object: self];

    _delegate = delegate;

    for (i = 0; notes[i].name != nil; ++i)
        if ([_delegate respondsToSelector: notes[i].selector])
            [[NSNotificationCenter defaultCenter] addObserver: _delegate
                                                     selector: notes[i].selector
                                                         name: notes[i].name
                                                       object: self];
}

static void loadItemIntoMapTables(NSOutlineView *self, id item,
                                  NSUInteger *rowCountPtr,
                                  NSUInteger recursionLevel,
                                  NSHashTable *removeItems)
{
    NSInteger i,
            numberOfChildren = numberOfChildrenOfItemAndReload(self, item, YES);

    for (i = 0; i < numberOfChildren; ++i) {
        id child = [self->_dataSource outlineView: self child: i ofItem: item];

        NSHashRemove(removeItems, child);

        //   NSLog(@"got child %@ for row %d, level %d", child, *rowCountPtr,
        //   recursionLevel);

        NSMapInsert(self->_rowToItem, (void *) (*rowCountPtr), child);
        NSMapInsert(self->_itemToRow, child, (void *) (*rowCountPtr));
        NSMapInsert(self->_itemToParent, child, item);
        NSMapInsert(self->_itemToLevel, child, (void *) recursionLevel);

        (*rowCountPtr)++;

        if (isItemExpanded(self, child))
            loadItemIntoMapTables(self, child, rowCountPtr, recursionLevel + 1,
                                  removeItems);
    }
}

- (void) loadRootItem {
    NSHashTable *removeItems =
            NSCreateHashTable(NSNonOwnedPointerHashCallBacks, 0);

    {
        NSMapEnumerator state = NSEnumerateMapTable(_itemToExpansionState);
        void *key, *value;

        while (NSNextMapEnumeratorPair(&state, &key, &value))
            NSHashInsert(removeItems, key);
    }

    loadItemIntoMapTables(self, nil, &_numberOfCachedRows, 0, removeItems); {
        NSHashEnumerator state = NSEnumerateHashTable(removeItems);
        void *key;

        while ((key = NSNextHashEnumeratorItem(&state)) != NULL)
            NSMapRemove(_itemToExpansionState, key);
    }
}

- (NSInteger) numberOfRows {
    if (_numberOfCachedRows == 0) {
        [self loadRootItem];
    }

    return _numberOfCachedRows;
}

- (NSRect) frameOfOutlineCellAtRow: (NSInteger) row {
    NSInteger column =
            [_tableColumns indexOfObjectIdenticalTo: _outlineTableColumn];
    NSRect result = [super frameOfCellAtColumn: column row: row];
    NSInteger level = [self levelForRow: row];
    CGFloat indentPixels = level * _indentationPerLevel;

    result.size.width = indentPixels;

    if (_indentationMarkerFollowsCell)
        result.origin.x += result.size.width;

    result.size.width = _indentationPerLevel;

    return result;
}

- (NSRect) _adjustedFrameOfCellAtColumn: (NSInteger) column
                                    row: (NSInteger) row
                            objectValue: (id) objectValue
{
    NSRect cellRect = [super frameOfCellAtColumn: column row: row];
    NSTableColumn *tableColumn = [_tableColumns objectAtIndex: column];

    if (tableColumn == _outlineTableColumn) {
        NSCell *dataCell = [tableColumn dataCellForRow: row];
        CGFloat indentPixels = [self levelForRow: row] * _indentationPerLevel;
        CGFloat cellWidth;

        cellRect.origin.x +=
                (indentPixels + _standardRowHeight) + _intercellSpacing.width;

        // instead, give the delegate an opportunity to provide the cell width.
        // (i was keying on attributed string value width, but this broke when i
        // tried to use an NSBrowserCell, naturally..

        if ([_delegate respondsToSelector: @selector
                       (outlineView:widthOfCell:forTableColumn:byItem:)]) {
            cellWidth = [_delegate outlineView: self
                                   widthOfCell: dataCell
                                forTableColumn: tableColumn
                                        byItem: [self itemAtRow: row]] +
                        _intercellSpacing.width;
        } else {
#if 1
            // this is more NSTableView-ish behavior.
            cellWidth =
                    cellRect.size.width - (indentPixels + _standardRowHeight);
#else
            [dataCell setObjectValue: objectValue];

            cellWidth = [dataCell cellSize].width + _intercellSpacing.width;
#endif
        }

        // since we shrink the cell frame to fit the title, when editing occurs,
        // we need to pad the frame slightly so that the entire title will be
        // visible in the editing cell (space permitting in the column)
        if (column == _editedColumn && row == _editedRow)
            cellWidth += _editingCellPadding;

        cellRect.size.width =
                MIN(cellWidth,
                    cellRect.size.width - (indentPixels + _standardRowHeight));
    }

    return cellRect;
}

/*
 * THE INDENT IS THE ROW'S, NOT ITS CONTENT'S. This asked for an object value first and indented only
 * rows that had one, so a VIEW BASED outline view, which has no object values at all, put every cell
 * at x=0 on top of its own disclosure triangle: iA Writer's location sidebar drew a triangle through
 * the first letter of Locations, Favorites and Hashtags. The object value is not used by the
 * adjustment either, only by a branch that is compiled out.
 */
- (NSRect) frameOfCellAtColumn: (NSInteger) column row: (NSInteger) row {
    NSTableColumn *tableColumn = [_tableColumns objectAtIndex: column];

    if (tableColumn == _outlineTableColumn)
        return [self _adjustedFrameOfCellAtColumn: column
                                              row: row
                                      objectValue: nil];

    return [super frameOfCellAtColumn: column row: row];
}

- (void) drawHighlightedSelectionForColumn: (NSInteger) column
                                       row: (NSInteger) row
                                    inRect: (NSRect) rect
{
    /* NO DOTTED RECTANGLE ROUND THE SELECTED ROW, which is a Windows habit and was drawn here on
     * top of the fill. macOS says selected with the fill alone; a dotted frame reads as a focus
     * ring that nothing else in the interface has. The inset and the one point shuffle went with
     * it: they existed to make room for the frame, and without them the fill covers the whole
     * row, which is what every other column already did. */
    [super drawHighlightedSelectionForColumn: column row: row inRect: rect];
}

- (void) _drawGridForItem: (id) item
                    style: (NSGraphicsStyle *) style
                    level: (NSInteger) level
{
    NSInteger column = [_tableColumns indexOfObject: _outlineTableColumn];
    NSInteger row = [self rowForItem: item];
    NSRect myFrame = [self frameOfCellAtColumn: column row: row];

    if (level > 0) {
        NSRect rect = myFrame;

        // it is safe to assume that all marker cells are the same size.
        rect.origin.x -= rect.size.width / 2;
        rect.size.width += rect.size.width / 2;
        rect.origin.y += (rect.size.height / 2) - 1;
        rect.size.height = 1;

        [style drawOutlineViewGridInRect: rect];
    }

    if (isItemExpanded(self, item)) {
        NSInteger i, numberOfChildren =
                             numberOfChildrenOfItemAndReload(self, item, NO);
        id lastChild = nil;

        for (i = 0; i < numberOfChildren; i++) {
            lastChild = childOfItemAtIndex(self, item, i);
            [self _drawGridForItem: lastChild style: style level: level + 1];
        }

        if (lastChild != nil) {
            NSRect rect = myFrame;
            NSRect lastChildRect =
                    [self frameOfCellAtColumn: column
                                          row: [self rowForItem: lastChild]];
            CGFloat delta = lastChildRect.origin.y - myFrame.origin.y;

            // it is safe to assume that all rows are the same height.
            rect.origin.x += (rect.size.width / 2) - 1;
            rect.size.width = 1;
            rect.origin.y += rect.size.height / 2;
            rect.size.height = delta;

            [style drawOutlineViewGridInRect: rect];
        }
    }
}

- (void) drawGridInClipRect: (NSRect) clipRect {
    // this doesn't look right at all when the indentation marker isn't set to
    // follow the cell
    NSGraphicsStyle *style = [self graphicsStyle];
    BOOL temp = _indentationMarkerFollowsCell;
    NSInteger i, count = numberOfChildrenOfItemAndReload(self, nil, NO);

    [[NSColor grayColor] setStroke];

    [self setIndentationMarkerFollowsCell: YES];
    for (i = 0; i < count; i++)
        [self _drawGridForItem: childOfItemAtIndex(self, nil, i)
                         style: style
                         level: 0];
    [self setIndentationMarkerFollowsCell: temp];

    [super drawGridInClipRect: clipRect];
}

- (NSCell *) preparedCellAtColumn: (NSInteger) columnNumber
                              row: (NSInteger) row
{
    NSTableColumn *column = [_tableColumns objectAtIndex: columnNumber];
    NSCell *result = [super preparedCellAtColumn: columnNumber row: row];

    if ([_delegate respondsToSelector: @selector
                   (outlineView:willDisplayCell:forTableColumn:item:)])
        [_delegate outlineView: self
                willDisplayCell: result
                 forTableColumn: column
                           item: [self itemAtRow: row]];

    return result;
}

- (void) drawRow: (NSInteger) row clipRect: (NSRect) rect {
    // FIXME: This should be changed to just call super, then draw the markers
    // But there are some fine differences with _adjustedFrame in NSTableView
    NSRange visibleColumns = [self columnsInRect: rect];
    NSInteger drawThisColumn = visibleColumns.location;

    if (row < 0 || row >= [self numberOfRows])
        [NSException raise: NSInvalidArgumentException
                    format: @"invalid row in drawRow:clipRect:"];

    for (; drawThisColumn < NSMaxRange(visibleColumns); drawThisColumn++) {

        if (row == _editedRow && drawThisColumn == _editedColumn &&
            _editingCell != nil) {
            CiderFillBackground(_backgroundColor, _editingBorder,
                                "NSOutlineView editingBorder");
            [_editingCell setControlView: self];
            [_editingCell drawWithFrame: _editingFrame inView: self];
            if ([_editingCell focusRingType] != NSFocusRingTypeNone) {
                [[NSColor keyboardFocusIndicatorColor] setStroke];
                NSFrameRectWithWidth(_editingBorder, 2.0);
            }
        } else {
            NSCell *dataCell = [self preparedCellAtColumn: drawThisColumn
                                                      row: row];
            [dataCell drawWithFrame: [self frameOfCellAtColumn: drawThisColumn
                                                           row: row]
                             inView: self];
        }

        // Marker cell is drawn after data cell so it is on top

        NSTableColumn *column = [_tableColumns objectAtIndex: drawThisColumn];

        // special outline behavior. we indent the entire cell so as not to rely
        // on a custom NSCell class (who knows what you might want in the
        // outline view?)
        if (column == _outlineTableColumn) {
            id item = [self itemAtRow: row];

            if ([self isExpandable: item]) {
                NSRect outlineCellFrame = [self frameOfOutlineCellAtRow: row];

                if (!NSIsEmptyRect(outlineCellFrame)) {
                    if (isItemExpanded(self, item))
                        [_markerCell setState: NSOnState];
                    else
                        [_markerCell setState: NSOffState];

                    if ([_delegate respondsToSelector: @selector
                                   (outlineView:
                                           willDisplayOutlineCell:forTableColumn
                                                                 :item:)])
                        [_delegate outlineView: self
                                willDisplayOutlineCell: _markerCell
                                        forTableColumn: column
                                                  item: item];

                    [_markerCell setControlView: self];
                    [_markerCell drawWithFrame: outlineCellFrame inView: self];
                }
            }
        }
    }
}

// intercept mouse clicks destined for the "dead space" in the indented area or
// the triangle. proper adjustment of the highlighted area in the outline column
// is performed elsewhere.
- (void) mouseDown: (NSEvent *) event {
    NSPoint location = [self convertPoint: [event locationInWindow]
                                 fromView: nil];

    _clickedColumn = [self columnAtPoint: location];
    _clickedRow = [self rowAtPoint: location];
    _clickedItem = [self itemAtRow: _clickedRow];

    if (_clickedColumn >= 0 && _clickedRow >= 0 &&
        [_tableColumns objectAtIndex: _clickedColumn] == _outlineTableColumn) {
        if (NSPointInRect(location,
                          [self frameOfOutlineCellAtRow: _clickedRow]) &&
            [self isExpandable: _clickedItem]) {
            if (isItemExpanded(self, _clickedItem) == NO)
                [self expandItem: _clickedItem];
            else
                [self collapseItem: _clickedItem];

            return;
        }
    }

    [super mouseDown: event];
}

//
// NSTableColumn delegate override methods
//
- (BOOL) delegateShouldSelectTableColumn: (NSTableColumn *) tableColumn {
    if ([_delegate respondsToSelector: @selector(outlineView:
                                               shouldSelectTableColumn:)])
        return [_delegate outlineView: self
                shouldSelectTableColumn: tableColumn];

    return YES;
}

- (BOOL) delegateShouldSelectRow: (NSInteger) row {
    if ([_delegate respondsToSelector: @selector(outlineView:
                                               shouldSelectItem:)])
        return [_delegate outlineView: self
                     shouldSelectItem: [self itemAtRow: row]];

    return YES;
}

- (BOOL) delegateShouldEditTableColumn: (NSTableColumn *) tableColumn
                                   row: (NSInteger) row
{
    if ([_delegate respondsToSelector: @selector(outlineView:
                                               shouldEditTableColumn:item:)])
        return [_delegate outlineView: self
                shouldEditTableColumn: tableColumn
                                 item: [self itemAtRow: row]];

    return YES;
}

- (BOOL) delegateSelectionShouldChange {
    if ([_delegate respondsToSelector: @selector
                   (selectionShouldChangeInOutlineView:)])
        return [_delegate selectionShouldChangeInOutlineView: self];

    return YES;
}

- (void) noteSelectionIsChanging {
    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSOutlineViewSelectionIsChangingNotification
                          object: self];
}

- (void) noteSelectionDidChange {
    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSOutlineViewSelectionDidChangeNotification
                          object: self];
}

- (void) noteColumnDidResizeWithOldWidth: (CGFloat) oldWidth {
    [[NSNotificationCenter defaultCenter]
            postNotificationName: NSOutlineViewColumnDidResizeNotification
                          object: self
                        userInfo: [NSDictionary
                                          dictionaryWithObjectsAndKeys:
                                                  [NSNumber numberWithFloat:
                                                                    oldWidth],
                                                  @"NSOldWidth", nil]];
}

- (BOOL) dataSourceCanSetObjectValue {
    return [_dataSource respondsToSelector: @selector
                        (outlineView:setObjectValue:forTableColumn:byItem:)];
}

- (void) dataSourceSetObjectValue: (id) object
                   forTableColumn: (NSTableColumn *) tableColumn
                              row: (NSInteger) row
{
    [_dataSource outlineView: self
              setObjectValue: object
              forTableColumn: tableColumn
                      byItem: [self itemAtRow: row]];
}

/*
 * An outline vends its views by ITEM, not by row, so both halves of the view based path are
 * redirected. Everything else about it is the table's.
 */
/*
 * AN OUTLINE VIEW IS ASKED BY ITEM, and nothing here ever asked. iA Writer's location sidebar
 * implements outlineView:heightOfRowByItem:, so every group row stayed at the standard height and
 * its label, which wants 17 points, was clamped into 16.
 */
- (CGFloat) _ciderHeightOfRow: (NSInteger) row {
    if (_delegate != nil &&
        [_delegate respondsToSelector: @selector(outlineView:heightOfRowByItem:)] == YES)
        return [_delegate outlineView: self heightOfRowByItem: [self itemAtRow: row]];

    return [super _ciderHeightOfRow: row];
}

- (BOOL) _isViewBased {
    BOOL viewBased = [_delegate respondsToSelector: @selector(outlineView:viewForTableColumn:item:)];

    if (getenv("CIDER_TRACE_FRAMES") != NULL) {
        static BOOL said = NO;

        if (!said) {
            said = YES;
            fprintf(stderr, "CIDER_FRAME NSOutlineView viewBased=%d delegate=%s dataSource=%s\n",
                    viewBased, object_getClassName(_delegate), object_getClassName(_dataSource));
        }
    }
    return viewBased;
}

- (NSView *) _viewForTableColumn: (NSTableColumn *) column row: (NSInteger) row {
    if (![self _isViewBased])
        return nil;
    return [_delegate outlineView: self
               viewForTableColumn: column
                             item: [self itemAtRow: row]];
}

/*
 * ASK ONLY IF IT ANSWERS. objectValueForTableColumn:byItem: is what a CELL based outline view wants
 * and it is OPTIONAL: a view based one supplies its rows through outlineView:viewForTableColumn:item:
 * and never implements this. Sending it regardless raised on iA Writer's organiser, from inside
 * drawRow:, so the first draw of the sidebar ended the application. The guarded accessor below it
 * has always existed; this override went around it.
 */
- (id) dataSourceObjectValueForTableColumn: (NSTableColumn *) tableColumn
                                       row: (NSInteger) row
{
    SEL byItem = @selector(outlineView:objectValueForTableColumn:byItem:);

    if ([_dataSource respondsToSelector: byItem] || [_delegate respondsToSelector: byItem])
        return [self _objectValueForTableColumn: tableColumn byItem: [self itemAtRow: row]];

    /*
     * NOT nil: the superclass consults the column's value BINDING when no data source method
     * answers, and an outline driven by an NSTreeController has nothing else. Returning nil here
     * drew every row as an empty stripe.
     */
    return [super dataSourceObjectValueForTableColumn: tableColumn row: row];
}

- (void) _willDisplayCell: (NSCell *) cell
           forTableColumn: (NSTableColumn *) column
                      row: (NSInteger) row
{
    if ([_delegate respondsToSelector: @selector
                   (outlineView:willDisplayCell:forTableColumn:item:)])
        [_delegate outlineView: self
                willDisplayCell: cell
                 forTableColumn: column
                           item: [self itemAtRow: row]];
}

@end
