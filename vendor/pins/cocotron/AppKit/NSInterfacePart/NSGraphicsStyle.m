/* Copyright (c) 2007 Christopher J. W. Lloyd

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
#import "NSInterfaceGraphics.h"
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContextFunctions.h>
#include <stdio.h>
#import <AppKit/NSGraphicsStyle.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSInterfacePartAttributedString.h>
#import <AppKit/NSInterfacePartDisabledAttributedString.h>
#import <AppKit/NSWindow.h>

@implementation NSGraphicsStyle

static NSDictionary *sNormalMenuTextAttributes = nil;
static NSDictionary *sSelectedMenuTextAttributes = nil;
static NSDictionary *sDimmedMenuTextAttributes = nil;
static NSDictionary *sDimmedMenuTextShadowAttributes = nil;
static NSDictionary *sScrollerButtonAttributes = nil;
/* THE APPLICATION NAME IN THE MENU BAR IS BOLD on macOS, and it is the only title that is. */
static NSDictionary *sBoldMenuTextAttributes = nil;
static NSDictionary *sBoldSelectedMenuTextAttributes = nil;

+ (void) initialize {
    if (sNormalMenuTextAttributes == nil) {
        NSFont *menuFont = [NSFont menuFontOfSize: 0];
        sNormalMenuTextAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys: menuFont, NSFontAttributeName,
                                              [NSColor menuItemTextColor],
                                              NSForegroundColorAttributeName,
                                              nil] retain];
        sSelectedMenuTextAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys:
                        menuFont, NSFontAttributeName,
                        [NSColor selectedMenuItemTextColor],
                        NSForegroundColorAttributeName, nil] retain];

        sDimmedMenuTextAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys: menuFont, NSFontAttributeName,
                                              [NSColor grayColor],
                                              NSForegroundColorAttributeName,
                                              nil] retain];

        sDimmedMenuTextShadowAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys: menuFont, NSFontAttributeName,
                                              [NSColor whiteColor],
                                              NSForegroundColorAttributeName,
                                              nil] retain];

        sScrollerButtonAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys: [NSFont labelFontOfSize: 8],
                                              NSFontAttributeName,
                                              [NSColor grayColor],
                                              NSForegroundColorAttributeName,
                                              nil] retain];


    }
}

- initWithView: (NSView *) view {
    _view = [view retain];
    return self;
}

- (void) dealloc {
    [_view release];
    [super dealloc];
}

@end

@implementation NSGraphicsStyle (NSMenu)

/*
 * A MENU ROW IS TWENTY FOUR POINTS TALL, and it was twenty one.
 *
 * Measured rather than guessed, from the reference screenshot the user sent: the text bands in it
 * are forty eight retina pixels apart, and the same eight items and three separators make a panel
 * 236 points tall. Ours came to 207, so every row was three points short and the whole menu read as
 * cramped next to the real one. The text itself is the same size in both; it is the space around it
 * that was missing.
 *
 * The parts of a row are centred in it by -[NSPopUpView drawRect:], so both halves are the same and
 * nothing moves off centre.
 */
#define TITLE_TOP_MARGIN 3.5
#define TITLE_BOTTOM_MARGIN 3.5
/* The state column, its gap to the title, and the two insets that make a highlight a pill rather
 * than a band. Apple numbers, measured on screen at the same point size. */
#define MENU_GUTTER_WIDTH 12
#define MENU_GUTTER_GAP 6
#define MENU_SELECTION_INSET 2
#define MENU_SELECTION_RADIUS 4
#define MENU_BAR_SELECTION_INSET 2
#define MENU_CORNER_RADIUS 10
#define MENU_BACKGROUND_ALPHA 0.94
#define MENU_BACKGROUND_WHITE 0.96
/* The accent, spelled out here as well as in the colour table: these are drawn shapes rather than
 * system colours, and a control that fills itself with pure blue is the same wrong note. */
#define ACCENT_RED 0.0
#define ACCENT_GREEN 0.478
#define ACCENT_BLUE 1.0
#define CHECK_BOX_SIDE 14
#define CHECK_BOX_RADIUS 3.5
#define TEXT_FIELD_RADIUS 4
#define STEPPER_RADIUS 3
#define BRANCH_ARROW_LEFT_MARGIN 2
#define BRANCH_ARROW_RIGHT_MARGIN 2

- (NSInterfacePartAttributedString *) branchArrow {
    static NSInterfacePartAttributedString *sBranchArrow = nil;

    if (sBranchArrow == nil)
        sBranchArrow = [[NSInterfacePartAttributedString alloc]
                initWithMarlettCharacter: 0x34];
    return sBranchArrow;
}

- (NSInterfacePartAttributedString *) checkMark {
    static NSInterfacePartAttributedString *sCheckMark = nil;

    if (sCheckMark == nil)
        sCheckMark = [[NSInterfacePartAttributedString alloc]
                initWithMarlettCharacter: 0x61];
    return sCheckMark;
}

/*
 * THE MENU METRICS ARE APPLE METRICS NOW, not the Win32 ones this file was written for.
 *
 * A menu is the most looked-at surface in the application and every number here shows: the gap a
 * separator sits in, the column a check mark reserves, how far the text is from the edge, how wide
 * the submenu arrow column is. Measured against macOS Sonoma at the same font size: item height 22,
 * text at 21 from the menu edge, separator slot 11 with a single hairline in the middle, key
 * equivalents ending 14 from the right edge.
 */
- (NSSize) menuItemSeparatorSize {
    return NSMakeSize(0, 11);
}

- (Margins) menuItemBranchArrowMargins {
    Margins result = [self menuItemTextMargins];

    result.left = BRANCH_ARROW_LEFT_MARGIN;
    result.right = BRANCH_ARROW_RIGHT_MARGIN;
    /* THE COLUMN IS NOT THE ARROW. The arrow column is fourteen points wide so a key equivalent
     * stops where Apple stops it, and the triangle inside it is four by eight: subtracting the old
     * two point margins from a five point box left a ONE point wide triangle, which is the tick
     * that appeared beside every submenu instead of an arrow. */
    result.left = 4;
    result.right = 6;

    return result;
}

- (NSSize) menuItemBranchArrowSize {
    return NSMakeSize(14, 12);
}

- (NSSize) menuItemCheckMarkSize {
    NSSize result = [[self checkMark] size];

    return result;
}

- (Margins) menuItemGutterMargins {
    Margins result;

    result.left = 0;
    result.right = 0;
    result.top = TITLE_TOP_MARGIN;
    result.bottom = TITLE_BOTTOM_MARGIN;

    return result;
}

- (NSSize) menuItemGutterSize {
    NSSize result = NSZeroSize;
    Margins margins = [self menuItemGutterMargins];

    result = [self menuItemCheckMarkSize];

    result.height += (margins.top + margins.bottom);
    result.width += (margins.left + margins.right);
    /* A FIXED COLUMN, not one that follows the check mark glyph. Apple reserves the same width in
     * every menu whether anything is checked or not, which is what makes the titles of two
     * different menus line up under each other. */
    result.width = MAX(result.width, MENU_GUTTER_WIDTH);

    return result;
}

- (Margins) menuItemTextMargins {
    Margins result;

    result.left = 0;
    result.right = 0;
    result.top = TITLE_TOP_MARGIN;
    result.bottom = TITLE_BOTTOM_MARGIN;

    return result;
}

/*
 * The application name, which is the first title in the bar and the only bold one.
 *
 * BUILT ON DEMAND RATHER THAN IN +initialize. The first version made these next to the other menu
 * attributes and the name came out the same weight as everything else: at class initialisation
 * time boldSystemFontOfSize answers before the font machinery can give a bold face, and the
 * dictionary then carries no font at all. Asking at draw time gets the face.
 */
static NSDictionary *cider_bold_menu_attributes(BOOL selected) {
    if (sBoldMenuTextAttributes == nil) {
        NSFont *menuFont = [NSFont menuFontOfSize: 0];
        NSFont *bold = [NSFont boldSystemFontOfSize: [menuFont pointSize]];

        if (bold == nil) {
            bold = menuFont;
        }
        sBoldMenuTextAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys: bold, NSFontAttributeName,
                                              [NSColor menuItemTextColor],
                                              NSForegroundColorAttributeName,
                                              nil] retain];
        sBoldSelectedMenuTextAttributes = [[NSDictionary
                dictionaryWithObjectsAndKeys: bold, NSFontAttributeName,
                                              [NSColor selectedMenuItemTextColor],
                                              NSForegroundColorAttributeName,
                                              nil] retain];
    }
    {
        static int said = 0;

        if (!said && getenv("CIDER_TRACE_FONTS") != NULL) {
            said = 1;
            NSFont *f = [sBoldMenuTextAttributes objectForKey: NSFontAttributeName];

            fprintf(stderr, "CIDER_MENUBAR_BOLD font=%s size=%g\n",
                    [[f fontName] UTF8String], (double) [f pointSize]);
            fflush(stderr);
        }
    }
    return selected ? sBoldSelectedMenuTextAttributes : sBoldMenuTextAttributes;
}

- (NSSize) menuBarAppTitleSize: (NSString *) title {
    NSSize result = [title sizeWithAttributes: cider_bold_menu_attributes(NO)];
    Margins margins = [self menuItemTextMargins];

    result.height += (margins.top + margins.bottom);
    result.width += (margins.left + margins.right);

    return result;
}

- (void) drawMenuBarAppTitle: (NSString *) string
                      inRect: (NSRect) rect
                    selected: (BOOL) selected
{
    Margins margins = [self menuItemTextMargins];

    rect.size.width = ceilf(rect.size.width);
    rect.origin.x += margins.left;
    rect.origin.y += margins.top;
    rect.size.width -= (margins.left + margins.right);
    rect.size.height -= (margins.top + margins.bottom);

    [string drawInRect: rect withAttributes: cider_bold_menu_attributes(selected)];
}

/*
 * THE SYMBOLS ONLY IF THE FONT HAS THEM, and it does not.
 *
 * A Mac shortcut is drawn with symbols, and NSMenuItem builds them. The menu font here resolves to
 * TeX Gyre Heros, a Helvetica clone with no Command glyph: measured, the Command symbol is ZERO
 * points wide, so the string was drawn into a rect measured without it and only the letter after it
 * survived. Every shortcut in every menu read H or Q with nothing in front.
 *
 * The test is the measurement itself rather than a font name, so a prefix whose UI font does have
 * the glyphs keeps the symbols. When it does not, the text forms go in.
 */
/*
 * AND A FONT THAT CAN DRAW THEM, if this system has one.
 *
 * The menu font resolves to TeX Gyre Heros here, a Helvetica clone with no Command glyph, so the
 * first version of this fell back to Cmd+ and Alt+ in text. That is legible and it is not what a
 * Mac shows. DejaVu Sans does have the symbols and is present in every prefix this has been run in,
 * so the key equivalent -- and ONLY the key equivalent -- is drawn in the first family that
 * measures the Command symbol as wider than nothing. Everything else stays in the menu font.
 */
static NSDictionary *cider_key_symbol_attributes(void) {
    static NSDictionary *attributes = nil;
    static BOOL looked = NO;

    if (looked) {
        return attributes;
    }
    looked = YES;

    NSFont *menuFont = [sNormalMenuTextAttributes objectForKey: NSFontAttributeName];

    if ([@"\u2318" sizeWithAttributes: sNormalMenuTextAttributes].width > 0.0) {
        attributes = [sNormalMenuTextAttributes retain];
        return attributes;
    }

    NSArray *candidates = [NSArray arrayWithObjects: @"DejaVu Sans", @"Noto Sans Symbols 2",
                                                     @"FreeSans", @"Unifont", nil];
    NSInteger i, count = [candidates count];

    for (i = 0; i < count; i++) {
        NSFont *font = [NSFont fontWithName: [candidates objectAtIndex: i]
                                       size: [menuFont pointSize]];

        if (font == nil) {
            continue;
        }

        NSDictionary *probe = [NSDictionary
                dictionaryWithObjectsAndKeys: font, NSFontAttributeName,
                                              [NSColor menuItemTextColor],
                                              NSForegroundColorAttributeName, nil];

        if ([@"\u2318" sizeWithAttributes: probe].width > 0.0) {
            attributes = [probe retain];
            return attributes;
        }
    }
    return attributes;
}

- (NSSize) menuKeyEquivalentSize: (NSString *) description {
    NSDictionary *attributes = cider_key_symbol_attributes();
    Margins margins = [self menuItemTextMargins];
    NSSize result = [description
            sizeWithAttributes: (attributes != nil) ? attributes : sNormalMenuTextAttributes];

    result.height += (margins.top + margins.bottom);
    result.width += (margins.left + margins.right);

    return result;
}

- (void) drawMenuKeyEquivalent: (NSString *) description
                        inRect: (NSRect) rect
                       enabled: (BOOL) enabled
                      selected: (BOOL) selected
{
    NSDictionary *attributes = cider_key_symbol_attributes();

    if (attributes == nil || attributes == sNormalMenuTextAttributes || !enabled || selected) {
        /* The shared attributes carry the selected and disabled colours, and the symbol font only
         * matters when the menu font cannot draw the symbols at all. */
        [self drawMenuItemText: description inRect: rect enabled: enabled selected: selected];
        return;
    }

    Margins margins = [self menuItemTextMargins];

    rect.size.width = ceilf(rect.size.width);
    rect.origin.x += margins.left;
    rect.origin.y += margins.top;
    rect.size.width -= (margins.left + margins.right);
    rect.size.height -= (margins.top + margins.bottom);
    [description drawInRect: rect withAttributes: attributes];
}

- (NSString *) menuKeyEquivalentDisplay: (NSString *) description {
    if ([description length] == 0) {
        return description;
    }
    if (cider_key_symbol_attributes() != nil) {
        return description;
    }

    static NSString *symbols[] = {@"\u2303", @"\u2325", @"\u21e7", @"\u2318", @"\u2191",
                                  @"\u2193", @"\u2190", @"\u2192", @"\u2326", @"\u2196",
                                  @"\u2198", @"\u21de", @"\u21df", @"\u21a9", @"\u21e5",
                                  @"\u238b", @"\u232b"};
    static NSString *words[] = {@"Ctrl+", @"Alt+",  @"Shift+", @"Cmd+",  @"Up",   @"Down",
                                @"Left",  @"Right", @"Del",    @"Home",  @"End",  @"PgUp",
                                @"PgDn",  @"Return", @"Tab",   @"Esc",   @"Back"};
    NSMutableString *out = [[description mutableCopy] autorelease];
    NSUInteger i;

    for (i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
        [out replaceOccurrencesOfString: symbols[i]
                             withString: words[i]
                                options: 0
                                  range: NSMakeRange(0, [out length])];
    }
    return out;
}

- (NSSize) menuItemTextSize: (NSString *) title {
    NSSize result = NSZeroSize;
    Margins margins = [self menuItemTextMargins];

    result = [title sizeWithAttributes: sNormalMenuTextAttributes];
    result.height += (margins.top + margins.bottom);
    result.width += (margins.left + margins.right);

    return result;
}

- (NSSize) menuItemAttributedTextSize: (NSAttributedString *) title {
    NSSize result = NSZeroSize;
    Margins margins = [self menuItemTextMargins];

    result = [title size];

    result.height += (margins.top + margins.bottom);
    result.width += (margins.left + margins.right);

    return result;
}

- (CGFloat) menuBarHeight {
    NSDictionary *attributes = [NSDictionary
            dictionaryWithObjectsAndKeys: [NSFont menuFontOfSize: 0],
                                          NSFontAttributeName, nil];
    CGFloat result = [@"Menu" sizeWithAttributes: attributes].height;

    result += 2; // border top/bottom margin
    result += 4; // border
    result += 1; // sunken title baseline

    return result;
}

- (CGFloat) menuItemGutterGap {
    return MENU_GUTTER_GAP;
}

/* ONE HAIRLINE, CENTRED IN ITS SLOT. The two line engraving here is a Windows separator, and it
 * was drawn at the TOP of the slot: on screen the line sat directly under the item above it and
 * touched the descenders of its text. Apple draws a single light rule with equal air above and
 * below, and the air is what makes a group read as a group. */
- (void) drawMenuSeparatorInRect: (NSRect) rect {
    CGFloat y = floor(NSMidY(rect));
    /* INSET, as macOS draws it: the rule stops short of both edges rather than cutting the panel in
     * two. Ten points each side, which is what the reference screenshot measures. */
    CGFloat inset = (rect.size.width > 40.0) ? 10.0 : 0.0;

    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.12] setFill];
    NSRectFillUsingOperation(
            NSMakeRect(rect.origin.x + inset, y, rect.size.width - inset * 2.0, 1),
            NSCompositeSourceOver);
}

/*
 * THE SEARCH FIELD AT THE TOP OF THE HELP MENU, drawn rather than laid out.
 *
 * macOS puts a real NSSearchField in that menu. This is a menu view, and a control inside a menu
 * item would have to be tracked, focused and resized by code that does not exist here; what the
 * user sees is a rounded white well with a magnifier and the text they typed, and that is what this
 * draws. The caret is the end of the text, because the field always has the focus while the menu is
 * open.
 */
- (void) drawMenuSearchFieldInRect: (NSRect) rect query: (NSString *) query {
    NSRect well = NSInsetRect(rect, 8.0, 3.0);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect: well
                                                         xRadius: 6.0
                                                         yRadius: 6.0];

    [[NSColor whiteColor] setFill];
    [shape fill];
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.18] setStroke];
    [shape setLineWidth: 1.0];
    [shape stroke];

    /* THE MAGNIFIER IS TWO STROKES, a circle and a handle, because there is no icon set here and a
     * glyph from a font is not guaranteed to exist in whatever face the menu is using. */
    CGFloat centreY = NSMidY(well);
    NSRect lens = NSMakeRect(NSMinX(well) + 6.0, centreY - 4.0, 8.0, 8.0);
    NSBezierPath *glass = [NSBezierPath bezierPathWithOvalInRect: lens];

    [[NSColor colorWithCalibratedWhite: 0.45 alpha: 1.0] setStroke];
    [glass setLineWidth: 1.5];
    [glass stroke];

    NSBezierPath *handle = [NSBezierPath bezierPath];
    /* WHICH WAY IS DOWN. A menu view is FLIPPED, so subtracting from y moves the handle UP and the
     * magnifier came out as the Mars symbol: a circle with the stem pointing up and to the right.
     * Ask the view rather than assuming either convention. */
    CGFloat down = [_view isFlipped] ? 1.0 : -1.0;

    [handle moveToPoint: NSMakePoint(NSMaxX(lens) - 1.0, centreY + 3.0 * down)];
    [handle lineToPoint: NSMakePoint(NSMaxX(lens) + 2.5, centreY + 6.0 * down)];
    [handle setLineWidth: 1.5];
    [handle stroke];

    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

    [attributes setObject: [NSFont menuFontOfSize: 0] forKey: NSFontAttributeName];
    [attributes setObject: [NSColor blackColor] forKey: NSForegroundColorAttributeName];

    NSSize size = [query sizeWithAttributes: attributes];
    NSPoint where = NSMakePoint(NSMaxX(lens) + 7.0, centreY - size.height / 2.0);

    [query drawAtPoint: where withAttributes: attributes];

    /* The caret, because the keyboard is pointed at this field the whole time the menu is up. */
    NSRect caret = NSMakeRect(where.x + size.width + 1.0, centreY - size.height / 2.0 + 1.0, 1.0,
                              size.height - 2.0);

    [[NSColor blackColor] setFill];
    NSRectFill(caret);
}

/*
 * A GREY HEADING OVER A GROUP, which is what macOS puts above the results of a menu search: small,
 * grey, and not selectable.
 */
- (void) drawMenuSectionHeaderInRect: (NSRect) rect title: (NSString *) title {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    NSFont *font = [NSFont menuFontOfSize: [NSFont smallSystemFontSize]];

    if (font != nil) {
        [attributes setObject: font forKey: NSFontAttributeName];
    }
    [attributes setObject: [NSColor colorWithCalibratedWhite: 0.45 alpha: 1.0]
                   forKey: NSForegroundColorAttributeName];

    NSSize size = [title sizeWithAttributes: attributes];
    NSPoint where = NSMakePoint(rect.origin.x + 12.0, NSMidY(rect) - size.height / 2.0);

    [title drawAtPoint: where withAttributes: attributes];
}

- (void) drawMenuGutterInRect: (NSRect) rect {
    // Nothing to do.
}

- (void) drawMenuItemText: (NSString *) string
                   inRect: (NSRect) rect
                  enabled: (BOOL) enabled
                 selected: (BOOL) selected
{
    // Ensure we have enough width - fractional widths give float comparison
    // trouble
    rect.size.width = ceilf(rect.size.width);

    Margins margins = [self menuItemTextMargins];

    rect.origin.x += margins.left;
    rect.origin.y += margins.top;
    rect.size.width -= (margins.left + margins.right);
    rect.size.height -= (margins.top + margins.bottom);

    if (enabled) {
        if (selected) {
            [string drawInRect: rect
                    withAttributes: sSelectedMenuTextAttributes];
        } else {
            [string drawInRect: rect withAttributes: sNormalMenuTextAttributes];
        }
    } else {
        if (!selected) {
            NSRect offsetRect = rect;
            offsetRect.origin.x += 1;
            offsetRect.origin.y += 1;
            [string drawInRect: offsetRect
                    withAttributes: sDimmedMenuTextShadowAttributes];
        }
        [string drawInRect: rect withAttributes: sDimmedMenuTextAttributes];
    }
}

- (void) drawAttributedMenuItemText: (NSAttributedString *) string
                             inRect: (NSRect) rect
                            enabled: (BOOL) enabled
                           selected: (BOOL) selected
{
    // Ensure we have enough width - fractional widths give float comparison
    // trouble
    rect.size.width = ceilf(rect.size.width);

    NSMutableAttributedString *mutableString = [string mutableCopy];

    Margins margins = [self menuItemTextMargins];

    rect.origin.x += margins.left;
    rect.origin.y += margins.top;
    rect.size.width -= (margins.left + margins.right);
    rect.size.height -= (margins.top + margins.bottom);

    NSRange range = NSMakeRange(0, [string length]);

    if (enabled) {
        if (!selected) {
            [mutableString
                    addAttributes:
                            [NSDictionary
                                    dictionaryWithObject:
                                            [NSColor menuItemTextColor]
                                                  forKey: NSForegroundColorAttributeName]
                            range: range];
        }
        [mutableString drawInRect: rect];
    } else {
        if (!selected) {
            [mutableString
                    addAttributes:
                            [NSDictionary
                                    dictionaryWithObject: [NSColor grayColor]
                                                  forKey: NSForegroundColorAttributeName]
                            range: range];
            NSRect offsetRect = rect;
            offsetRect.origin.x += 1;
            offsetRect.origin.y += 1;
            [mutableString drawInRect: offsetRect];
        }
        [mutableString drawInRect: rect];
    }
}

- (void) drawMenuCheckmarkInRect: (NSRect) rect
                         enabled: (BOOL) enabled
                        selected: (BOOL) selected
{
    NSColor *color;
    NSInterfacePartAttributedString *checkMark;
    Margins margins = [self menuItemTextMargins];

    if (enabled)
        color = selected ? [NSColor selectedControlTextColor]
                         : [NSColor menuItemTextColor];
    else
        color = [NSColor disabledControlTextColor];

    /*
     * A STROKED CHECK, NOT THE LETTER a.
     *
     * This drew character 0x61 from MARLETT, the Windows interface font, in which 0x61 is a check
     * mark. Marlett is not on this system and nothing substitutes for it, so every ticked menu item
     * had a lower case a in its gutter: View showed one beside Formatting Marks, Boundaries, Images
     * and Charts, Whitespace, Field Shadings and Sidebar, which is how this was found.
     *
     * Two strokes, the same weight and colour as the text beside them, in the same style as the
     * submenu chevron. THE VERTICAL DIRECTION IS ASKED FOR rather than assumed: a menu view is
     * FLIPPED, so the point of the check is at the LARGER y there and at the smaller y everywhere
     * else, and getting that wrong draws a tick standing on its head.
     */
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    NSRect box = rect;

    box.origin.x += margins.left;
    box.origin.y += margins.top;
    box.size.width -= (margins.left + margins.right);
    box.size.height -= (margins.top + margins.bottom);

    CGFloat w = box.size.width;
    CGFloat h = box.size.height;
    BOOL flipped = [_view isFlipped];
    CGFloat top = flipped ? NSMinY(box) : NSMaxY(box);
    CGFloat bottom = flipped ? NSMaxY(box) : NSMinY(box);
    CGFloat rise = (top - bottom);

    [color set];
    CGContextSetLineWidth(context, 1.6);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, NSMinX(box) + w * 0.10, bottom + rise * 0.52);
    CGContextAddLineToPoint(context, NSMinX(box) + w * 0.38, bottom + rise * 0.20);
    CGContextAddLineToPoint(context, NSMinX(box) + w * 0.92, bottom + rise * 0.82);
    CGContextStrokePath(context);

    (void) checkMark;
}

- (void) drawMenuBranchArrowInRect: (NSRect) rect
                           enabled: (BOOL) enabled
                          selected: (BOOL) selected
{
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    NSColor *color;
    Margins margins = [self menuItemBranchArrowMargins];
    NSRect themeRect = rect;

    if (enabled)
        color = selected ? [NSColor selectedControlTextColor]
                         : [NSColor menuItemTextColor];
    else
        color = [NSColor disabledControlTextColor];

    [color set];

    themeRect.origin.x += margins.left;
    themeRect.origin.y += margins.top;
    themeRect.size.width -= (margins.left + margins.right);
    themeRect.size.height -= (margins.top + margins.bottom);

    /*
     * A CHEVRON, NOT A FILLED TRIANGLE. The reference screenshot the user supplied shows what macOS
     * puts beside a submenu: two strokes meeting at a point, the same weight as the text. A solid
     * triangle is what this drew, and it is the older look from a different decade.
     *
     * NOT INSET. The arrow box after its margins is about four points by eight, so taking two more
     * off each side leaves a rectangle with no width at all: the first version of this drew a
     * vertical BAR beside every submenu, which is what the screenshot showed.
     */
    NSRect chevron = themeRect;
    CGFloat middle = NSMidY(chevron);

    CGContextSetLineWidth(context, 1.5);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, NSMinX(chevron), NSMaxY(chevron));
    CGContextAddLineToPoint(context, NSMaxX(chevron), middle);
    CGContextAddLineToPoint(context, NSMinX(chevron), NSMinY(chevron));
    CGContextStrokePath(context);
}

/* A ROUNDED PILL INSET FROM THE EDGES, which is what an Apple menu highlights with. A full width
 * rectangle that touches both walls of the menu is the Windows look and was the giveaway that this
 * menu was not a Mac one. */
- (void) drawMenuSelectionInRect: (NSRect) rect enabled: (BOOL) enabled {
    if (enabled) {
        NSRect pill = NSInsetRect(rect, MENU_SELECTION_INSET, 0);

        [[NSColor selectedMenuItemColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect: pill
                                         xRadius: MENU_SELECTION_RADIUS
                                         yRadius: MENU_SELECTION_RADIUS] fill];
    }
}

/*
 * ROUNDED AND TRANSLUCENT, which is what a menu looks like on macOS and what the square opaque
 * rectangle here was not.
 *
 * The whole surface is cleared to nothing first, so the corners outside the rounded shape are
 * transparent rather than the colour they would otherwise keep; the backend gives a transient
 * window an alpha channel for exactly this. Then the shape is filled at slightly less than full
 * opacity and outlined with a hairline, which is what separates a menu from the window behind it
 * when both are light.
 *
 * A menu that is not transient, or a backend with no alpha, simply gets a rounded rect over an
 * opaque clear colour, which still looks better than the square one.
 */
- (void) drawMenuWindowBackgroundInRect: (NSRect) rect {
    NSRect bounds = rect;
    NSBezierPath *shape;

    if (getenv("CIDER_TRACE_VCL") != NULL) {
        fprintf(stderr, "CIDER_MENUBG rect=%gx%g+%g+%g view=%s viewbounds=%gx%g+%g+%g\n",
                rect.size.width, rect.size.height, rect.origin.x, rect.origin.y,
                object_getClassName(_view), [_view bounds].size.width,
                [_view bounds].size.height, [_view bounds].origin.x, [_view bounds].origin.y);
        fflush(stderr);
    }

    NSRectFillUsingOperation(bounds, NSCompositeClear);

    shape = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect(bounds, 0.5, 0.5)
                                           xRadius: MENU_CORNER_RADIUS
                                           yRadius: MENU_CORNER_RADIUS];
    /* BUILT FROM COMPONENTS, not from menuBackgroundColor with an alpha applied. A system colour
     * here is a catalog colour, and asking one of those for a variant of itself is not something
     * this AppKit answers: the fill silently did nothing and the menu came out empty, which on a
     * surface that had just been cleared to nothing meant a black rectangle. */
    [[NSColor colorWithCalibratedRed: MENU_BACKGROUND_WHITE
                              green: MENU_BACKGROUND_WHITE
                               blue: MENU_BACKGROUND_WHITE
                              alpha: MENU_BACKGROUND_ALPHA] setFill];
    [shape fill];
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.18] setStroke];
    [shape setLineWidth: 1.0];
    [shape stroke];
}

- (void) drawMenuBarItemBorderInRect: (NSRect) rect
                               hover: (BOOL) hovering
                            selected: (BOOL) selected
{
    if (selected || hovering) {
        NSRect pill = NSInsetRect(rect, 0, MENU_BAR_SELECTION_INSET);

        [[NSColor selectedMenuItemColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect: pill
                                         xRadius: MENU_SELECTION_RADIUS
                                         yRadius: MENU_SELECTION_RADIUS] fill];
    }
}

- (void) drawMenuBarBackgroundInRect: (NSRect) rect {
    [[NSColor mainMenuBarColor] setFill];
    NSRectFill(rect);
}

@end

@implementation NSGraphicsStyle (NSButton)

- (void) drawUnborderedButtonInRect: (NSRect) rect defaulted: (BOOL) defaulted {
    if (defaulted) {
        [[NSColor blackColor] setFill];
        NSRectFill(rect);
    }
}

- (void) drawPushButtonNormalInRect: (NSRect) rect defaulted: (BOOL) defaulted {
    /*
     * WHO DRAWS LAST, which decides whether a missing button label is the wrong COLOUR or the wrong
     * ORDER. Set CIDER_BEZEL_ALPHA and this bezel becomes half transparent: a label drawn BEFORE it
     * shows through, and a label that is simply not there stays not there. Two explanations that
     * look identical on an opaque button, separated by one run.
     */
    CGFloat alpha = (getenv("CIDER_BEZEL_ALPHA") != NULL) ? 0.5 : 1.0;

    /*
     * THE DEFAULT BUTTON IS FILLED WITH THE ACCENT COLOUR, which is what its white label expects.
     * The old default look was a BLACK RING around a white button, which is a different decade of
     * macOS, and it left an application that draws its own label in the emphasised text colour with
     * white on white.
     */
    if (defaulted) {
        [[NSColor colorWithCalibratedRed: 0.0 green: 0.48 blue: 1.0 alpha: alpha] set];
        [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4 yRadius: 4] fill];
        return;
    }

    [[NSColor colorWithCalibratedWhite: 0.78 alpha: alpha] set];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4 yRadius: 4] fill];
    rect = NSInsetRect(rect, 1, 1);
    [[NSColor colorWithCalibratedWhite: 1.0 alpha: alpha] set];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4 yRadius: 4] fill];
}

- (void) drawPushButtonPressedInRect: (NSRect) rect {
    [[NSColor colorWithCalibratedWhite: 0.78 alpha: 1.0] set];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4 yRadius: 4] fill];
    rect = NSInsetRect(rect, 1, 1);
    [[NSColor colorWithCalibratedRed: 0.0 green: 0.58 blue: 0.97
                               alpha: 1.0] set];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4 yRadius: 4] fill];
}

- (void) drawPushButtonHighlightedInRect: (NSRect) rect {
    NSInterfaceDrawHighlightedButton(rect, rect);
}

/*
 * A CHECK BOX AND A RADIO BUTTON ARE DRAWN, NOT BLITTED.
 *
 * Cocotron ships them as TIFF images, and they are Windows controls: a square sunken box with a
 * black tick, a square dot. Nothing about them can be made to look like a Mac control by scaling,
 * so the two names are intercepted here and the control is drawn instead -- a rounded square and a
 * circle, white with a grey edge when off and accent blue with a white mark when on, at the size
 * Apple uses rather than the size the TIFF happens to be.
 */
static BOOL isSwitchImage(NSString *name) {
    return [name isEqualToString: @"NSSwitch"] ||
           [name isEqualToString: @"NSHighlightedSwitch"];
}

static BOOL isRadioImage(NSString *name) {
    return [name isEqualToString: @"NSRadioButton"] ||
           [name isEqualToString: @"NSHighlightedRadioButton"];
}

static BOOL isOnImage(NSString *name) {
    return [name isEqualToString: @"NSHighlightedSwitch"] ||
           [name isEqualToString: @"NSHighlightedRadioButton"];
}

- (NSColor *) accentColorEnabled: (BOOL) enabled {
    if (!enabled) {
        return [NSColor colorWithCalibratedWhite: 0.72 alpha: 1.0];
    }
    return [NSColor colorWithCalibratedRed: ACCENT_RED
                                     green: ACCENT_GREEN
                                      blue: ACCENT_BLUE
                                     alpha: 1.0];
}

- (void) drawCheckBoxInRect: (NSRect) rect
                         on: (BOOL) on
                      mixed: (BOOL) mixed
                    enabled: (BOOL) enabled
{
    NSRect box = NSInsetRect(rect, 0.5, 0.5);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect: box
                                                         xRadius: CHECK_BOX_RADIUS
                                                         yRadius: CHECK_BOX_RADIUS];

    if (on || mixed) {
        [[self accentColorEnabled: enabled] setFill];
        [shape fill];
    } else {
        [[NSColor whiteColor] setFill];
        [shape fill];
        [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.28] setStroke];
        [shape setLineWidth: 1.0];
        [shape stroke];
    }

    if (mixed) {
        NSRect dash = NSInsetRect(box, NSWidth(box) * 0.25, NSHeight(box) * 0.44);
        [[NSColor whiteColor] setFill];
        NSRectFill(dash);
        return;
    }
    if (on) {
        /* The tick, as three points rather than a glyph: a font that has no check mark is one more
         * thing to go missing, and this one is four lines of geometry. */
        NSBezierPath *tick = [NSBezierPath bezierPath];

        [tick moveToPoint: NSMakePoint(NSMinX(box) + NSWidth(box) * 0.24,
                                       NSMinY(box) + NSHeight(box) * 0.52)];
        [tick lineToPoint: NSMakePoint(NSMinX(box) + NSWidth(box) * 0.44,
                                       NSMinY(box) + NSHeight(box) * 0.30)];
        [tick lineToPoint: NSMakePoint(NSMinX(box) + NSWidth(box) * 0.78,
                                       NSMinY(box) + NSHeight(box) * 0.72)];
        [tick setLineWidth: 2.0];
        [tick setLineCapStyle: NSRoundLineCapStyle];
        [tick setLineJoinStyle: NSRoundLineJoinStyle];
        [[NSColor whiteColor] setStroke];
        [tick stroke];
    }
}

- (void) drawRadioButtonInRect: (NSRect) rect
                            on: (BOOL) on
                       enabled: (BOOL) enabled
{
    NSRect box = NSInsetRect(rect, 0.5, 0.5);
    NSBezierPath *shape = [NSBezierPath bezierPathWithOvalInRect: box];

    if (on) {
        [[self accentColorEnabled: enabled] setFill];
        [shape fill];
        [[NSColor whiteColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:
                NSInsetRect(box, NSWidth(box) * 0.33, NSHeight(box) * 0.33)] fill];
    } else {
        [[NSColor whiteColor] setFill];
        [shape fill];
        [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.28] setStroke];
        [shape setLineWidth: 1.0];
        [shape stroke];
    }
}

- (NSSize) sizeOfButtonImage: (NSImage *) image
                     enabled: (BOOL) enabled
                       mixed: (BOOL) mixed
{
    NSString *name = [image name];

    if (isSwitchImage(name) || isRadioImage(name)) {
        return NSMakeSize(CHECK_BOX_SIDE, CHECK_BOX_SIDE);
    }
    return [image size];
}

- (void) drawButtonImage: (NSImage *) image
                  inRect: (NSRect) rect
                 enabled: (BOOL) enabled
                   mixed: (BOOL) mixed
{
    NSString *name = [image name];
    CGFloat fraction = enabled ? 1.0 : 0.5;

    if (isSwitchImage(name)) {
        [self drawCheckBoxInRect: rect
                              on: isOnImage(name)
                           mixed: mixed
                         enabled: enabled];
        return;
    }
    if (isRadioImage(name)) {
        [self drawRadioButtonInRect: rect on: isOnImage(name) enabled: enabled];
        return;
    }

    [image drawInRect: rect
             fromRect: NSZeroRect
            operation: NSCompositeSourceOver
             fraction: fraction];
}

@end

@implementation NSGraphicsStyle (NSBrowser)

- (void) drawBrowserTitleBackgroundInRect: (NSRect) rect {
    NSInterfaceDrawBrowserHeader(rect, rect);
}

- (void) drawBrowserHorizontalScrollerWellInRect: (NSRect) rect
                                        clipRect: (NSRect) clipRect
{
    NSDrawGrayBezel(rect, clipRect);
}

@end

@implementation NSGraphicsStyle (NSColorWell)

- (NSRect) drawColorWellBorderInRect: (NSRect) rect
                             enabled: (BOOL) enabled
                            bordered: (BOOL) bordered
                              active: (BOOL) active
{
    if (bordered) {
        if (active)
            NSInterfaceDrawHighlightedButton(rect, rect);
        else
            NSInterfaceDrawButton(rect, rect);

        rect = NSInsetRect(rect, 6, 6);

        if (enabled)
            NSDrawGrayBezel(rect, rect);
    } else {
        if (enabled) {
            NSDrawGrayBezel(rect, rect);
        }
    }

    return NSInsetRect(rect, 2, 2);
}

@end

@implementation NSGraphicsStyle (NSPopUpButton)

- (void) drawPopUpButtonWindowBackgroundInRect: (NSRect) rect {
    [[NSColor menuBackgroundColor] setFill];
    NSRectFill(rect);
    [[NSColor blackColor] setStroke];
    NSFrameRect(rect);
}

@end

@implementation NSGraphicsStyle (NSOutlineView)

- (void) drawOutlineViewGridInRect: (NSRect) rect {
    NSInterfaceDrawOutlineGrid(rect, NSCurrentGraphicsPort());
}

@end

@implementation NSGraphicsStyle (NSProgressIndicator)

- (NSRect) drawProgressIndicatorBackground: (NSRect) rect
                                  clipRect: (NSRect) clipRect
                                   bezeled: (BOOL) bezeled
{
    if (bezeled) {
        NSInterfaceDrawProgressIndicatorBezel(rect, clipRect);
        return NSInsetRect(rect, 2, 2);
    } else {
        [[[_view window] backgroundColor] setFill];
        NSRectFill(rect);
        return rect;
    }
}

- (void) drawProgressIndicatorChunk: (NSRect) rect {
    [[NSColor selectedControlColor] setFill];
    NSRectFill(rect);
}

// rough estimates
#define BLOCK_WIDTH 8.0
#define BLOCK_SPACING 2.0

- (void) drawProgressIndicatorIndeterminate: (NSRect) rect
                                   clipRect: (NSRect) clipRect
                                    bezeled: (BOOL) bezeled
                                  animation: (double) animation
{
    if (bezeled)
        rect = [self drawProgressIndicatorBackground: rect
                                            clipRect: clipRect
                                             bezeled: bezeled];

    NSRect progressRect = rect;
    NSRect blockRect = progressRect;
    int numBlocks;

    numBlocks = (animation * progressRect.size.width) /
                (BLOCK_WIDTH + BLOCK_SPACING);

    if (numBlocks > 0)
        numBlocks++;

    while (numBlocks-- >= 0) {
        blockRect.size.width = BLOCK_WIDTH;

        if (NSMaxX(blockRect) > NSMaxX(progressRect))
            blockRect.size.width -= (NSMaxX(blockRect) - NSMaxX(progressRect));

        if (blockRect.size.width > 0) {
            if (numBlocks < 2) {
                [self drawProgressIndicatorChunk: blockRect];
            }
            blockRect.origin.x += BLOCK_WIDTH + BLOCK_SPACING;
        }
    }
}

- (void) drawProgressIndicatorDeterminate: (NSRect) rect
                                 clipRect: (NSRect) clipRect
                                  bezeled: (BOOL) bezeled
                                    value: (double) value
{
    if (bezeled)
        rect = [self drawProgressIndicatorBackground: rect
                                            clipRect: clipRect
                                             bezeled: bezeled];

    NSRect progressRect = rect;
    NSRect blockRect = progressRect;
    int numBlocks;

    numBlocks =
            (value * progressRect.size.width) / (BLOCK_WIDTH + BLOCK_SPACING);

    if (numBlocks > 0)
        numBlocks++;

    while (numBlocks-- >= 0) {
        blockRect.size.width = BLOCK_WIDTH;

        if (NSMaxX(blockRect) > NSMaxX(progressRect))
            blockRect.size.width -= (NSMaxX(blockRect) - NSMaxX(progressRect));

        if (blockRect.size.width > 0) {
            [self drawProgressIndicatorChunk: blockRect];
            blockRect.origin.x += BLOCK_WIDTH + BLOCK_SPACING;
        }
    }
}

@end

@implementation NSGraphicsStyle (NSScroller)

- (void) drawScrollerButtonInRect: (NSRect) rect
                          enabled: (BOOL) enabled
                          pressed: (BOOL) pressed
                         vertical: (BOOL) vertical
                         upOrLeft: (BOOL) upOrLeft
{
    /*
       unichar code=vertical?(upOrLeft?0x74:0x75):(upOrLeft?0x33:0x34);
       Class   class;
       NSInterfacePart *arrow;

       if(enabled)
        class=[NSInterfacePartAttributedString class];
       else
        class=[NSInterfacePartDisabledAttributedString class];

       arrow=[[[class alloc] initWithMarlettCharacter:code] autorelease];
    */
    /* NO ARROWS. macOS stopped drawing scroll arrows in 10.7 and never went back; what was here was
     * a push button with a triangle in it at each end of every scroll bar. The space the scroller
     * reserves is filled with the track so the bar is one continuous colour. */
    if (!NSIsEmptyRect(rect)) {
        [self drawScrollerTrackInRect: rect vertical: vertical upOrLeft: upOrLeft];
    }
}

/*
 * A SCROLLER THE WAY APPLE DRAWS ONE: a light track, a grey rounded knob, and no arrows.
 *
 * The knob was drawPushButtonNormalInRect, so every scroll bar in the application was a row of
 * Windows push buttons: a raised knob with a border, and an arrow button at each end that macOS has
 * not had since 10.7. The user named it on the document scroll bar: light background, grey element,
 * darker while it is being dragged.
 *
 * The knob is filled with BLACK AT AN ALPHA rather than a grey, which is what makes it read
 * correctly over both the light track and whatever an application draws behind an overlay scroller.
 */
- (void) drawScrollerKnobInRect: (NSRect) rect
                       vertical: (BOOL) vertical
                      highlight: (BOOL) highlight
{
    CGFloat thickness = vertical ? NSWidth(rect) : NSHeight(rect);
    CGFloat inset = MAX(thickness * 0.22, 2.0);
    NSRect knob = vertical ? NSInsetRect(rect, inset, 2.0) : NSInsetRect(rect, 2.0, inset);
    CGFloat radius = (vertical ? NSWidth(knob) : NSHeight(knob)) / 2.0;

    if (NSIsEmptyRect(knob)) {
        return;
    }
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: highlight ? 0.55 : 0.32] setFill];
    [[NSBezierPath bezierPathWithRoundedRect: knob xRadius: radius yRadius: radius] fill];
}

- (void) drawScrollerTrackInRect: (NSRect) rect
                        vertical: (BOOL) vertical
                        upOrLeft: (BOOL) upOrLeft
{
    [[NSColor colorWithCalibratedWhite: 0.98 alpha: 1.0] setFill];
    NSRectFill(rect);
    /* The hairline that separates the track from the content it scrolls. */
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.10] setFill];
    NSRectFillUsingOperation(vertical
                                     ? NSMakeRect(NSMinX(rect), NSMinY(rect), 1, NSHeight(rect))
                                     : NSMakeRect(NSMinX(rect), NSMaxY(rect) - 1, NSWidth(rect), 1),
                             NSCompositeSourceOver);
}

- (void) drawScrollerTrackInRect: (NSRect) rect vertical: (BOOL) vertical {
    [self drawScrollerTrackInRect: rect vertical: vertical upOrLeft: NO];
}

@end

@implementation NSGraphicsStyle (NSSlider)

- (NSSize) sliderKnobSizeForControlSize: (NSControlSize) controlSize {

    switch (controlSize) {
    default:
    case NSRegularControlSize:     // aqua is 17x19
        return NSMakeSize(12, 15); // this is Windows specific, uxtheme part
                                   // size request was failing, hardcoded, sigh

    case NSSmallControlSize: // aqua is 13x15
        return NSMakeSize(9, 13);

    case NSMiniControlSize: // aqua is 11x11
        return NSMakeSize(11, 11);
    }
}

- (void) drawSliderKnobInRect: (NSRect) rect
                     vertical: (BOOL) vertical
                  highlighted: (BOOL) highlighted
                 hasTickMarks: (BOOL) hasTickMarks
             tickMarkPosition: (NSTickMarkPosition) tickMarkPosition
{
    NSDrawButton(rect, rect);

    if (highlighted) {
        [[NSColor whiteColor] setFill];
        NSRectFill(NSInsetRect(rect, 1, 1));
    }
}

- (void) drawSliderTrackInRect: (NSRect) rect
                      vertical: (BOOL) vertical
                  hasTickMarks: (BOOL) hasTickMarks
{
    NSRect groove = rect;

    if (vertical) {
        groove.size.width = 4;
        groove.origin.x = floor(rect.origin.x + (rect.size.width - 4) / 2);
    } else {
        groove.size.height = 4;
        groove.origin.y = floor(rect.origin.y + (rect.size.height - 4) / 2);
    }

    NSDrawGrayBezel(groove, rect);
}

- (void) drawSliderTickInRect: (NSRect) rect {
    [[NSColor blackColor] setFill];
    NSRectFill(rect);
}

@end

@implementation NSGraphicsStyle (NSStepper)

/*
 * A STEPPER IS TWO ROUNDED HALVES WITH A CHEVRON IN EACH, not a Marlett glyph in a Windows bezel.
 *
 * The user named this one from a screenshot of the Insert Table dialog: the up and down buttons
 * next to Columns, Rows and Heading rows were the only controls in it that still looked like
 * Windows. They were a character from the Marlett font drawn inside NSDrawButton, which is the
 * sunken grey bezel of every other Win32 control this file was written for.
 *
 * This is called once per HALF, with that half rect and a flag saying which. Each half gets its own
 * small rounded rect, which at thirteen by eleven reads as the one control Apple draws, and the
 * chevron is stroked rather than set in a typeface so it cannot go missing with a font.
 */
- (void) drawStepperButtonInRect: (NSRect) rect
                        clipRect: (NSRect) clipRect
                         enabled: (BOOL) enabled
                     highlighted: (BOOL) highlighted
                       upNotDown: (BOOL) upNotDown
{
    NSRect box = NSInsetRect(rect, 0.5, 0.5);

    /*
     * ONLY THE OUTER CORNERS ARE ROUND. Apple draws ONE rounded rect split across the middle, so
     * the corners that meet in the seam are square. Two independently rounded halves read as two
     * buttons rather than one stepper. There is no per corner radius here, so the half is drawn
     * with a rect that extends PAST the seam and the drawing is clipped to the half: what is left
     * is round on the outside and square where they meet.
     */
    NSRect grown = box;

    if (upNotDown) {
        grown.origin.y -= STEPPER_RADIUS * 2;
        grown.size.height += STEPPER_RADIUS * 2;
    } else {
        grown.size.height += STEPPER_RADIUS * 2;
    }

    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect: grown
                                                         xRadius: STEPPER_RADIUS
                                                         yRadius: STEPPER_RADIUS];

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);

    if (highlighted) {
        [[self accentColorEnabled: enabled] setFill];
    } else {
        [[NSColor colorWithCalibratedWhite: 0.99 alpha: 1.0] setFill];
    }
    [shape fill];
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.25] setStroke];
    [shape setLineWidth: 1.0];
    [shape stroke];
    /* The seam itself, which the clip cut off the growing rect. */
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.18] setFill];
    NSRectFillUsingOperation(NSMakeRect(NSMinX(box), upNotDown ? NSMinY(box) : NSMaxY(box) - 1,
                                        NSWidth(box), 1),
                             NSCompositeSourceOver);
    [NSGraphicsContext restoreGraphicsState];

    CGFloat midX = NSMidX(box);
    CGFloat midY = NSMidY(box);
    CGFloat half = MIN(NSWidth(box) * 0.24, 3.0);
    CGFloat rise = MIN(NSHeight(box) * 0.22, 2.5);
    NSBezierPath *chevron = [NSBezierPath bezierPath];

    if (upNotDown) {
        [chevron moveToPoint: NSMakePoint(midX - half, midY - rise / 2)];
        [chevron lineToPoint: NSMakePoint(midX, midY + rise / 2)];
        [chevron lineToPoint: NSMakePoint(midX + half, midY - rise / 2)];
    } else {
        [chevron moveToPoint: NSMakePoint(midX - half, midY + rise / 2)];
        [chevron lineToPoint: NSMakePoint(midX, midY - rise / 2)];
        [chevron lineToPoint: NSMakePoint(midX + half, midY + rise / 2)];
    }
    [chevron setLineWidth: 1.5];
    [chevron setLineCapStyle: NSRoundLineCapStyle];
    [chevron setLineJoinStyle: NSRoundLineJoinStyle];
    if (highlighted) {
        [[NSColor whiteColor] setStroke];
    } else if (enabled) {
        [[NSColor colorWithCalibratedWhite: 0.25 alpha: 1.0] setStroke];
    } else {
        [[NSColor colorWithCalibratedWhite: 0.25 alpha: 0.4] setStroke];
    }
    [chevron stroke];
}

@end

@implementation NSGraphicsStyle (NSTableView)

- (void) drawTableViewHeaderInRect: (NSRect) rect
                       highlighted: (BOOL) highlighted
{
    NSDrawButton(rect, rect);

    if (highlighted) {
        [[NSColor darkGrayColor] setFill];
        NSRectFill(NSInsetRect(rect, 2, 2));
    }
}

- (void) drawTableViewCornerInRect: (NSRect) rect {
    NSDrawButton(rect, rect);
}

@end

@implementation NSGraphicsStyle (NSBox)

- (void) drawBoxWithLineInRect: (NSRect) rect {
    [[NSColor colorWithCalibratedWhite: 0.78 alpha: 1.0] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4
                                     yRadius: 4] stroke];
}

- (void) drawBoxWithBezelInRect: (NSRect) rect clipRect: (NSRect) clipRect {
    [[NSColor colorWithCalibratedWhite: 0.78 alpha: 1.0] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4
                                     yRadius: 4] stroke];
}

- (void) drawBoxWithGrooveInRect: (NSRect) rect clipRect: (NSRect) clipRect {
    [[NSColor colorWithCalibratedWhite: 0.78 alpha: 1.0] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect: rect xRadius: 4
                                     yRadius: 4] stroke];
}

@end

@implementation NSGraphicsStyle (NSComboBox)

- (void) drawComboBoxButtonInRect: (NSRect) rect
                          enabled: (BOOL) enabled
                         bordered: (BOOL) bordered
                          pressed: (BOOL) pressed
{
    /*
     * THE BLUE SQUARE WITH THE ARROW IN IT, which is what this control looks like on Apple systems
     * and what the user asked for by name. It was a grey chiselled button with a black triangle
     * from a tiff, which is the look of a different decade and a different system.
     *
     * A rounded rectangle in the system accent blue with a WHITE chevron, dimmed to grey when the
     * control is disabled and darkened while it is held down. The corner radius and the inset are
     * the small numbers that decide whether it reads as native: the button sits INSIDE the field
     * rather than filling its whole height, which is why the rect is inset before anything is drawn
     * into it.
     */
    CGContextRef context = NSCurrentGraphicsPort();
    NSRect box = NSInsetRect(rect, 1.0, 2.0);
    CGFloat radius = 3.0;

    if (box.size.width <= 0 || box.size.height <= 0) {
        return;
    }

    CGContextSaveGState(context);

    if (!enabled) {
        [[NSColor colorWithCalibratedRed: 0.78 green: 0.78 blue: 0.80 alpha: 1.0] setFill];
    } else if (pressed) {
        [[NSColor colorWithCalibratedRed: 0.00 green: 0.36 blue: 0.80 alpha: 1.0] setFill];
    } else {
        [[NSColor colorWithCalibratedRed: 0.00 green: 0.48 blue: 1.00 alpha: 1.0] setFill];
    }
    [[NSBezierPath bezierPathWithRoundedRect: box xRadius: radius yRadius: radius] fill];

    /* The chevron, drawn rather than loaded: an image would have to exist at every size and would
     * be the wrong colour the moment the button is not blue. */
    CGFloat width = MIN(7.0, box.size.width - 4.0);
    CGFloat height = width / 2.0;
    CGFloat centreX = NSMidX(box);
    CGFloat centreY = NSMidY(box) + (pressed ? -0.5 : 0.0);

    if (width > 1.0) {
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, centreX - width / 2.0, centreY + height / 2.0);
        CGContextAddLineToPoint(context, centreX + width / 2.0, centreY + height / 2.0);
        CGContextAddLineToPoint(context, centreX, centreY - height / 2.0);
        CGContextClosePath(context);
        [[NSColor whiteColor] setFill];
        CGContextFillPath(context);
    }

    CGContextRestoreGState(context);
}

@end

@implementation NSGraphicsStyle (NSTabView)

- (void) drawTabInRect: (NSRect) rect
              clipRect: (NSRect) clipRect
                 color: (NSColor *) color
              selected: (BOOL) selected
{
    NSRect originalRect = rect;
    NSRect rects[8];
    NSColor *colors[8];
    int i;

    if (selected) {
        rect.origin.x -= 2;
        rect.size.width += 3;
    } else {
        rect.size.height -= 2;
    }

    for (i = 0; i < 8; i++)
        rects[i] = rect;

    colors[0] = [NSColor controlColor];
    if (selected) {
        rects[0].origin.y -= 1;
        rects[0].size.height += 1;
    }
    colors[1] = color;
    rects[1] = NSInsetRect(rect, 1, 1);
    colors[2] = [NSColor whiteColor];
    rects[2].size.width = 1;
    rects[2].size.height -= 2;
    if (selected) {
        rects[2].origin.y -= 1;
        rects[2].size.height += 1;
    }
    colors[3] = [NSColor whiteColor];
    rects[3].origin.x += 1;
    rects[3].origin.y += rect.size.height - 2;
    rects[3].size.width = 1;
    rects[3].size.height = 1;
    colors[4] = [NSColor whiteColor];
    rects[4].origin.x += 2;
    rects[4].origin.y += rect.size.height - 1;
    rects[4].size.width = rect.size.width - 4;
    rects[4].size.height = 1;
    colors[5] = [NSColor blackColor];
    rects[5].origin.x += rect.size.width - 2;
    rects[5].origin.y += rect.size.height - 2;
    rects[5].size.width = 1;
    rects[5].size.height = 1;
    colors[6] = [NSColor controlShadowColor];
    rects[6].origin.x += rect.size.width - 2;
    rects[6].size.width = 1;
    rects[6].size.height -= 2;
    colors[7] = [NSColor blackColor];
    rects[7].origin.x += rect.size.width - 1;
    rects[7].size.width = 1;
    rects[7].size.height -= 2;
    if (selected) {
        rects[7].origin.y -= 1;
        rects[7].size.height += 1;
    }

    for (i = 0; i < 8; i++) {
        [colors[i] setFill];
        NSRectFill(rects[i]);
    }

    if (selected) { // cleanup
        NSRect erase = originalRect;

        [[NSColor controlColor] setFill];
        erase.size.height = 2;
        erase = NSInsetRect(erase, 1, 0);
        NSRectFill(erase);
    }
}

- (void) drawTabPaneInRect: (NSRect) rect {
    NSDrawButton(rect, rect);
}

- (void) drawTabViewBackgroundInRect: (NSRect) rect {
    // do nothing
}

@end

@implementation NSGraphicsStyle (NSTextField)

/* A ROUNDED WELL WITH A HAIRLINE, which is what a text field and the text half of a combo box look
 * like on macOS. NSDrawWhiteBezel is a sunken Windows bezel, two grey lines and a white one, and it
 * is square: next to a rounded blue dropdown button it read as two controls from two systems. */
- (void) drawTextFieldBorderInRect: (NSRect) rect
                    bezeledNotLine: (BOOL) bezeledNotLine
{
    NSRect box = NSInsetRect(rect, 0.5, 0.5);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect: box
                                                         xRadius: TEXT_FIELD_RADIUS
                                                         yRadius: TEXT_FIELD_RADIUS];

    /* WHICH RECT IS OURS, when a white band appears above a rounded well and it is not clear who
     * painted it. Fills the rect this method was given, so whatever stays white was drawn by
     * somebody else and its geometry can be read off the screen. */
    if (getenv("CIDER_FIELD_MAGENTA") != NULL) {
        [[NSColor magentaColor] setFill];
        NSRectFill(rect);
    }
    if (bezeledNotLine) {
        [[NSColor whiteColor] setFill];
        [shape fill];
    }
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.25] setStroke];
    [shape setLineWidth: 1.0];
    [shape stroke];
}

/* THE FILL HAS TO BE THE SAME SHAPE AS THE BEZEL. NSTextFieldCell fills its background with a
 * plain rect GROWN BY ONE in each direction, which was invisible while the bezel was square and
 * became a white box poking out of the corners the moment it was rounded. The user saw it on the
 * Family field of the Character dialog and said it was in more places than that. */
- (void) drawTextFieldBackgroundInRect: (NSRect) rect color: (NSColor *) color {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(rect, 0.5, 0.5)
                                     xRadius: TEXT_FIELD_RADIUS
                                     yRadius: TEXT_FIELD_RADIUS] fill];
}

- (void) drawTextViewInsertionPointInRect: (NSRect) rect
                                    color: (NSColor *) color
{
    [color setFill];
    NSRectFill(rect);
}

@end

@implementation NSView (NSGraphicsStyle)

- (NSGraphicsStyle *) graphicsStyle {
    return [[[NSGraphicsStyle alloc] initWithView: self] autorelease];
}

@end

/* See the comment on the declaration: a nil view is legal here and costs nothing, because the only
 * thing the style ever reads out of one is the window background colour of a progress indicator. */
NSGraphicsStyle *NSGraphicsStyleForView(NSView *view) {
    return [[[NSGraphicsStyle alloc] initWithView: view] autorelease];
}
