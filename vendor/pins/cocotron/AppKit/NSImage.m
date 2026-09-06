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

#import <AppKit/NSBitmapImageRep.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#import <AppKit/NSCachedImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSCustomImageRep.h>
#import <AppKit/NSEPSImageRep.h>
#import <AppKit/NSGraphicsContextFunctions.h>
#import <AppKit/NSImage.h>
#import <string.h>
#import <dlfcn.h>
#import <AppKit/NSImageRep.h>
#import <AppKit/NSPDFImageRep.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSRaise.h>
#import <Foundation/NSKeyedArchiver.h>

NSImageName const NSImageNameActionTemplate = @"NSActionTemplate";
NSImageName const NSImageNameAddTemplate = @"NSAddTemplate";
NSImageName const NSImageNameAdvanced = @"NSAdvanced";
NSImageName const NSImageNameApplicationIcon = @"NSApplicationIcon";
NSImageName const NSImageNameBluetoothTemplate = @"NSBluetoothTemplate";
NSImageName const NSImageNameBonjour = @"NSBonjour";
NSImageName const NSImageNameBookmarksTemplate = @"NSBookmarksTemplate";
NSImageName const NSImageNameCaution = @"NSCaution";
NSImageName const NSImageNameColorPanel = @"NSColorPanel";
NSImageName const NSImageNameColumnViewTemplate = @"NSColumnViewTemplate";
NSImageName const NSImageNameComputer = @"NSComputer";
NSImageName const NSImageNameDotMac = @"NSDotMac";
NSImageName const NSImageNameEnterFullScreenTemplate =
        @"NSEnterFullScreenTemplate";
NSImageName const NSImageNameEveryone = @"NSEveryone";
NSImageName const NSImageNameExitFullScreenTemplate =
        @"NSExitFullScreenTemplate";
NSImageName const NSImageNameFlowViewTemplate = @"NSFlowViewTemplate";
NSImageName const NSImageNameFolder = @"NSFolder";
NSImageName const NSImageNameFolderBurnable = @"NSFolderBurnable";
NSImageName const NSImageNameFolderSmart = @"NSFolderSmart";
NSImageName const NSImageNameFollowLinkFreestandingTemplate =
        @"NSFollowLinkFreestandingTemplate";
NSImageName const NSImageNameFontPanel = @"NSFontPanel";
NSImageName const NSImageNameGoLeftTemplate = @"NSGoLeftTemplate";
NSImageName const NSImageNameGoRightTemplate = @"NSGoRightTemplate";
NSImageName const NSImageNameHomeTemplate = @"NSHomeTemplate";
NSImageName const NSImageNameIChatTheaterTemplate = @"NSIChatTheaterTemplate";
NSImageName const NSImageNameIconViewTemplate = @"NSIconViewTemplate";
NSImageName const NSImageNameInfo = @"NSInfo";
NSImageName const NSImageNameInvalidDataFreestandingTemplate =
        @"NSInvalidDataFreestandingTemplate";
NSImageName const NSImageNameLeftFacingTriangleTemplate =
        @"NSLeftFacingTriangleTemplate";
NSImageName const NSImageNameListViewTemplate = @"NSListViewTemplate";
NSImageName const NSImageNameLockLockedTemplate = @"NSLockLockedTemplate";
NSImageName const NSImageNameLockUnlockedTemplate = @"NSLockUnlockedTemplate";
NSImageName const NSImageNameMenuMixedStateTemplate =
        @"NSMenuMixedStateTemplate";
NSImageName const NSImageNameMenuOnStateTemplate = @"NSMenuOnStateTemplate";
NSImageName const NSImageNameMobileMe = @"NSMobileMe";
NSImageName const NSImageNameMultipleDocuments = @"NSMultipleDocuments";
NSImageName const NSImageNameNetwork = @"NSNetwork";
NSImageName const NSImageNamePathTemplate = @"NSPathTemplate";
NSImageName const NSImageNamePreferencesGeneral = @"NSPreferencesGeneral";
NSImageName const NSImageNameQuickLookTemplate = @"NSQuickLookTemplate";
NSImageName const NSImageNameRefreshFreestandingTemplate =
        @"NSRefreshFreestandingTemplate";
NSImageName const NSImageNameRefreshTemplate = @"NSRefreshTemplate";
NSImageName const NSImageNameRemoveTemplate = @"NSRemoveTemplate";
NSImageName const NSImageNameRevealFreestandingTemplate =
        @"NSRevealFreestandingTemplate";
NSImageName const NSImageNameRightFacingTriangleTemplate =
        @"NSRightFacingTriangleTemplate";
NSImageName const NSImageNameShareTemplate = @"NSShareTemplate";
NSImageName const NSImageNameSlideshowTemplate = @"NSSlideshowTemplate";
NSImageName const NSImageNameSmartBadgeTemplate = @"NSSmartBadgeTemplate";
NSImageName const NSImageNameStatusAvailable = @"NSStatusAvailable";
NSImageName const NSImageNameStatusNone = @"NSStatusNone";
NSImageName const NSImageNameStatusPartiallyAvailable =
        @"NSStatusPartiallyAvailable";
NSImageName const NSImageNameStatusUnavailable = @"NSStatusUnavailable";
NSImageName const NSImageNameStopProgressFreestandingTemplate =
        @"NSStopProgressFreestandingTemplate";
NSImageName const NSImageNameStopProgressTemplate = @"NSStopProgressTemplate";
NSImageName const NSImageNameTrashEmpty = @"NSTrashEmpty";
NSImageName const NSImageNameTrashFull = @"NSTrashFull";
NSImageName const NSImageNameUser = @"NSUser";
NSImageName const NSImageNameUserAccounts = @"NSUserAccounts";
NSImageName const NSImageNameUserGroup = @"NSUserGroup";
NSImageName const NSImageNameUserGuest = @"NSUserGuest";
NSImageName const NSImageNameGoBackTemplate = @"NSGoBackTemplate";
NSImageName const NSImageNameGoForwardTemplate = @"NSGoForwardTemplate";

NSImageHintKey const NSImageHintInterpolation = @"NSImageHintInterpolation";
NSImageHintKey const NSImageHintCTM = @"NSImageHintCTM";

NSImageName const NSImageNameTouchBarDeleteTemplate =
        @"NSTouchBarDeleteTemplate";
NSImageName const NSImageNameTouchBarPauseTemplate = @"NSTouchBarPauseTemplate";
NSImageName const NSImageNameTouchBarPlayTemplate = @"NSTouchBarPlayTemplate";
NSImageName const NSImageNameTouchBarRecordStopTemplate =
        @"NSTouchBarRecordStopTemplate";
NSImageName const NSImageNameTouchBarAddDetailTemplate =
        @"NSImageNameTouchBarAddDetailTemplate";
NSImageName const NSImageNameTouchBarAddTemplate =
        @"NSImageNameTouchBarAddTemplate";
NSImageName const NSImageNameTouchBarAlarmTemplate =
        @"NSImageNameTouchBarAlarmTemplate";
NSImageName const NSImageNameTouchBarAudioInputMuteTemplate =
        @"NSImageNameTouchBarAudioInputMuteTemplate";
NSImageName const NSImageNameTouchBarAudioInputTemplate =
        @"NSImageNameTouchBarAudioInputTemplate";
NSImageName const NSImageNameTouchBarAudioOutputMuteTemplate =
        @"NSImageNameTouchBarAudioOutputMuteTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeHighTemplate =
        @"NSImageNameTouchBarAudioOutputVolumeHighTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeLowTemplate =
        @"NSImageNameTouchBarAudioOutputVolumeLowTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeMediumTemplate =
        @"NSImageNameTouchBarAudioOutputVolumeMediumTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeOffTemplate =
        @"NSImageNameTouchBarAudioOutputVolumeOffTemplate";
NSImageName const NSImageNameTouchBarBookmarksTemplate =
        @"NSImageNameTouchBarBookmarksTemplate";
NSImageName const NSImageNameTouchBarColorPickerFill =
        @"NSImageNameTouchBarColorPickerFill";
NSImageName const NSImageNameTouchBarColorPickerFont =
        @"NSImageNameTouchBarColorPickerFont";
NSImageName const NSImageNameTouchBarColorPickerStroke =
        @"NSImageNameTouchBarColorPickerStroke";
NSImageName const NSImageNameTouchBarCommunicationAudioTemplate =
        @"NSImageNameTouchBarCommunicationAudioTemplate";
NSImageName const NSImageNameTouchBarCommunicationVideoTemplate =
        @"NSImageNameTouchBarCommunicationVideoTemplate";
NSImageName const NSImageNameTouchBarComposeTemplate =
        @"NSImageNameTouchBarComposeTemplate";
NSImageName const NSImageNameTouchBarDownloadTemplate =
        @"NSImageNameTouchBarDownloadTemplate";
NSImageName const NSImageNameTouchBarEnterFullScreenTemplate =
        @"NSImageNameTouchBarEnterFullScreenTemplate";
NSImageName const NSImageNameTouchBarExitFullScreenTemplate =
        @"NSImageNameTouchBarExitFullScreenTemplate";
NSImageName const NSImageNameTouchBarFastForwardTemplate =
        @"NSImageNameTouchBarFastForwardTemplate";
NSImageName const NSImageNameTouchBarFolderCopyToTemplate =
        @"NSImageNameTouchBarFolderCopyToTemplate";
NSImageName const NSImageNameTouchBarFolderMoveToTemplate =
        @"NSImageNameTouchBarFolderMoveToTemplate";
NSImageName const NSImageNameTouchBarFolderTemplate =
        @"NSImageNameTouchBarFolderTemplate";
NSImageName const NSImageNameTouchBarGetInfoTemplate =
        @"NSImageNameTouchBarGetInfoTemplate";
NSImageName const NSImageNameTouchBarGoBackTemplate =
        @"NSImageNameTouchBarGoBackTemplate";
NSImageName const NSImageNameTouchBarGoDownTemplate =
        @"NSImageNameTouchBarGoDownTemplate";
NSImageName const NSImageNameTouchBarGoForwardTemplate =
        @"NSImageNameTouchBarGoForwardTemplate";
NSImageName const NSImageNameTouchBarGoUpTemplate =
        @"NSImageNameTouchBarGoUpTemplate";
NSImageName const NSImageNameTouchBarHistoryTemplate =
        @"NSImageNameTouchBarHistoryTemplate";
NSImageName const NSImageNameTouchBarIconViewTemplate =
        @"NSImageNameTouchBarIconViewTemplate";
NSImageName const NSImageNameTouchBarListViewTemplate =
        @"NSImageNameTouchBarListViewTemplate";
NSImageName const NSImageNameTouchBarMailTemplate =
        @"NSImageNameTouchBarMailTemplate";
NSImageName const NSImageNameTouchBarNewFolderTemplate =
        @"NSImageNameTouchBarNewFolderTemplate";
NSImageName const NSImageNameTouchBarNewMessageTemplate =
        @"NSImageNameTouchBarNewMessageTemplate";
NSImageName const NSImageNameTouchBarOpenInBrowserTemplate =
        @"NSImageNameTouchBarOpenInBrowserTemplate";
NSImageName const NSImageNameTouchBarPlayheadTemplate =
        @"NSImageNameTouchBarPlayheadTemplate";
NSImageName const NSImageNameTouchBarPlayPauseTemplate =
        @"NSImageNameTouchBarPlayPauseTemplate";
NSImageName const NSImageNameTouchBarQuickLookTemplate =
        @"NSImageNameTouchBarQuickLookTemplate";
NSImageName const NSImageNameTouchBarRecordStartTemplate =
        @"NSImageNameTouchBarRecordStartTemplate";
NSImageName const NSImageNameTouchBarRefreshTemplate =
        @"NSImageNameTouchBarRefreshTemplate";
NSImageName const NSImageNameTouchBarRemoveTemplate =
        @"NSImageNameTouchBarRemoveTemplate";
NSImageName const NSImageNameTouchBarRewindTemplate =
        @"NSImageNameTouchBarRewindTemplate";
NSImageName const NSImageNameTouchBarRotateLeftTemplate =
        @"NSImageNameTouchBarRotateLeftTemplate";
NSImageName const NSImageNameTouchBarRotateRightTemplate =
        @"NSImageNameTouchBarRotateRightTemplate";
NSImageName const NSImageNameTouchBarSearchTemplate =
        @"NSImageNameTouchBarSearchTemplate";
NSImageName const NSImageNameTouchBarShareTemplate =
        @"NSImageNameTouchBarShareTemplate";
NSImageName const NSImageNameTouchBarSidebarTemplate =
        @"NSImageNameTouchBarSidebarTemplate";
NSImageName const NSImageNameTouchBarSkipAhead15SecondsTemplate =
        @"NSImageNameTouchBarSkipAhead15SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipAhead30SecondsTemplate =
        @"NSImageNameTouchBarSkipAhead30SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipAheadTemplate =
        @"NSImageNameTouchBarSkipAheadTemplate";
NSImageName const NSImageNameTouchBarSkipBack15SecondsTemplate =
        @"NSImageNameTouchBarSkipBack15SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipBack30SecondsTemplate =
        @"NSImageNameTouchBarSkipBack30SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipBackTemplate =
        @"NSImageNameTouchBarSkipBackTemplate";
NSImageName const NSImageNameTouchBarSkipToEndTemplate =
        @"NSImageNameTouchBarSkipToEndTemplate";
NSImageName const NSImageNameTouchBarSkipToStartTemplate =
        @"NSImageNameTouchBarSkipToStartTemplate";
NSImageName const NSImageNameTouchBarSlideshowTemplate =
        @"NSImageNameTouchBarSlideshowTemplate";
NSImageName const NSImageNameTouchBarTagIconTemplate =
        @"NSImageNameTouchBarTagIconTemplate";
NSImageName const NSImageNameTouchBarTextBoldTemplate =
        @"NSImageNameTouchBarTextBoldTemplate";
NSImageName const NSImageNameTouchBarTextBoxTemplate =
        @"NSImageNameTouchBarTextBoxTemplate";
NSImageName const NSImageNameTouchBarTextCenterAlignTemplate =
        @"NSImageNameTouchBarTextCenterAlignTemplate";
NSImageName const NSImageNameTouchBarTextItalicTemplate =
        @"NSImageNameTouchBarTextItalicTemplate";
NSImageName const NSImageNameTouchBarTextJustifiedAlignTemplate =
        @"NSImageNameTouchBarTextJustifiedAlignTemplate";
NSImageName const NSImageNameTouchBarTextLeftAlignTemplate =
        @"NSImageNameTouchBarTextLeftAlignTemplate";
NSImageName const NSImageNameTouchBarTextListTemplate =
        @"NSImageNameTouchBarTextListTemplate";
NSImageName const NSImageNameTouchBarTextRightAlignTemplate =
        @"NSImageNameTouchBarTextRightAlignTemplate";
NSImageName const NSImageNameTouchBarTextStrikethroughTemplate =
        @"NSImageNameTouchBarTextStrikethroughTemplate";
NSImageName const NSImageNameTouchBarTextUnderlineTemplate =
        @"NSImageNameTouchBarTextUnderlineTemplate";
NSImageName const NSImageNameTouchBarUserAddTemplate =
        @"NSImageNameTouchBarUserAddTemplate";
NSImageName const NSImageNameTouchBarUserGroupTemplate =
        @"NSImageNameTouchBarUserGroupTemplate";
NSImageName const NSImageNameTouchBarUserTemplate =
        @"NSImageNameTouchBarUserTemplate";
NSImageName const NSImageNameTouchBarVolumeDownTemplate =
        @"NSImageNameTouchBarVolumeDownTemplate";
NSImageName const NSImageNameTouchBarVolumeUpTemplate =
        @"NSImageNameTouchBarVolumeUpTemplate";

// Private class used so the context knows the flipped status of a locked image
// 10.4 does something like that - probably for more than just getting the
// flippiness - 10.6 uses some special NSSnapshotBitmapGraphicsContext
@interface NSImageCacheView : NSView {
    BOOL _flipped;
}
- (id) initWithFlipped: (BOOL) flipped;
@end
/*
 * A representation whose drawing IS a block, which is what +imageWithSize:flipped:drawingHandler:
 * hands back. The handler runs on every draw rather than once into a bitmap, because that is what
 * callers rely on when the block reads the current appearance or a tint colour.
 */
@interface CiderBlockImageRep : NSImageRep {
    BOOL (^_handler)(NSRect dstRect);
    BOOL _handlerWantsFlipped;
}
- initWithSize: (NSSize) size
       flipped: (BOOL) flipped
       handler: (BOOL (^)(NSRect dstRect)) handler;
@end

@implementation CiderBlockImageRep

- initWithSize: (NSSize) size
       flipped: (BOOL) flipped
       handler: (BOOL (^)(NSRect dstRect)) handler
{
    if ((self = [super init]) == nil)
        return nil;
    [self setSize: size];
    _handlerWantsFlipped = flipped;
    _handler = [handler copy];
    return self;
}

- (void) dealloc {
    [_handler release];
    [super dealloc];
}

- (BOOL) draw {
    NSSize size = [self size];
    NSRect rect = NSMakeRect(0, 0, size.width, size.height);

    if (_handler == NULL)
        return NO;

    if (!_handlerWantsFlipped)
        return _handler(rect);

    CGContextRef context = NSCurrentGraphicsPort();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, size.height);
    CGContextScaleCTM(context, 1, -1);
    BOOL result = _handler(rect);
    CGContextRestoreGState(context);
    return result;
}

@end

@implementation NSImageCacheView
- (id) initWithFlipped: (BOOL) flipped {
    if ((self = [super init])) {
        _flipped = flipped;
    }
    return self;
}
- (BOOL) isFlipped {
    return _flipped;
}
@end

/*
 * READING A COMPILED ASSET CATALOG.
 *
 * +[NSImage imageNamed:] below searches loose resource files only, so every image an application
 * ships inside Contents/Resources/Assets.car came back nil. Measured on Swift Publisher that is 143
 * lookups in one run, and a button with no image draws its title, which is why its whole toolbar
 * reads Button.
 *
 * The format, established by parsing a real catalog rather than from documentation:
 *
 *   The container is a BOM store: a big endian header, a block table of offset and length pairs,
 *   and a variable table naming the interesting blocks. CARHEADER, RENDITIONS, FACETKEYS and
 *   KEYFORMAT are the ones needed here. Everything INSIDE the blocks is little endian.
 *
 *   FACETKEYS is a tree whose key is the name an application asks for and whose value is a PARTIAL
 *   rendition key: a count followed by attribute and value pairs.
 *
 *   RENDITIONS is a tree whose key is a FULL rendition key, one uint16 per attribute in the order
 *   KEYFORMAT lists them, and whose value starts with ISTC and carries width, height, scale and
 *   pixel format.
 *
 *   Most named renditions are only a few hundred bytes because they are LINKS. A chunk tagged KLNI
 *   holds a rectangle and the key of another rendition, a PACKED SHEET holding many pieces of
 *   artwork, and the named image is that rectangle cropped out of the sheet.
 *
 *   A sheet body is SEVERAL LZFSE streams laid end to end, each ending with the bvx$ marker, and
 *   the decoded bytes are rows at a padded stride, so the stride is the decoded size divided by the
 *   height rather than width times four.
 *
 * ONE TRAP: a link key can name an attribute that KEYFORMAT does not list at all, attribute 16 in
 * the catalog this was written against. Requiring every attribute to be present matches nothing, so
 * an attribute absent from KEYFORMAT counts as satisfied.
 *
 * Only BGRA renditions are turned into images here. GA8 exists in these catalogs too and is not
 * handled yet, so a name that only has grey renditions still comes back nil.
 */

static uint32_t _CiderBE32(const uint8_t *p) {
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | (uint32_t) p[3];
}

static uint32_t _CiderLE32(const uint8_t *p) {
    return ((uint32_t) p[3] << 24) | ((uint32_t) p[2] << 16) | ((uint32_t) p[1] << 8) | (uint32_t) p[0];
}

static uint16_t _CiderLE16(const uint8_t *p) {
    return (uint16_t) (((uint16_t) p[1] << 8) | (uint16_t) p[0]);
}

typedef struct {
    const uint8_t *bytes;
    size_t length;
    uint32_t blockCount;
    uint32_t indexOffset;
    uint32_t varsOffset;
} _CiderCar;

static BOOL _CiderCarOpen(NSData *data, _CiderCar *car) {
    const uint8_t *b = [data bytes];

    if (data == nil || [data length] < 32 || memcmp(b, "BOMStore", 8) != 0)
        return NO;

    car->bytes = b;
    car->length = [data length];
    car->blockCount = _CiderBE32(b + 12);
    car->indexOffset = _CiderBE32(b + 16);
    car->varsOffset = _CiderBE32(b + 24);

    return car->indexOffset + 4 <= car->length && car->varsOffset + 4 <= car->length;
}

static const uint8_t *_CiderCarBlock(_CiderCar *car, uint32_t index, uint32_t *lengthOut) {
    const uint8_t *table = car->bytes + car->indexOffset;
    uint32_t count = _CiderBE32(table);

    if (index == 0 || index >= count)
        return NULL;

    uint32_t offset = _CiderBE32(table + 4 + 8 * index);
    uint32_t length = _CiderBE32(table + 4 + 8 * index + 4);

    if ((size_t) offset + length > car->length)
        return NULL;
    if (lengthOut != NULL)
        *lengthOut = length;

    return car->bytes + offset;
}

static uint32_t _CiderCarVariable(_CiderCar *car, const char *wanted) {
    const uint8_t *p = car->bytes + car->varsOffset;
    uint32_t count = _CiderBE32(p);
    size_t namelen = strlen(wanted);

    p += 4;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t index = _CiderBE32(p);
        uint8_t len = p[4];
        const char *name = (const char *) (p + 5);

        if (len == namelen && memcmp(name, wanted, len) == 0)
            return index;

        p += 5 + len;
    }

    return 0;
}

/* The leaf of a BOM tree, which is where the key and value block indexes live. */
static const uint8_t *_CiderCarLeaf(_CiderCar *car, const char *variable, uint32_t *countOut) {
    uint32_t index = _CiderCarVariable(car, variable);
    uint32_t length = 0;
    const uint8_t *tree = _CiderCarBlock(car, index, &length);

    if (tree == NULL || length < 21 || memcmp(tree, "tree", 4) != 0)
        return NULL;

    const uint8_t *path = _CiderCarBlock(car, _CiderBE32(tree + 8), &length);

    if (path == NULL || length < 12)
        return NULL;

    *countOut = (uint32_t) ((path[2] << 8) | path[3]);

    return path + 12;
}

static void _CiderCarLeafEntry(const uint8_t *leaf, uint32_t i, uint32_t *valueIndex, uint32_t *keyIndex) {
    *valueIndex = _CiderBE32(leaf + 8 * i);
    *keyIndex = _CiderBE32(leaf + 8 * i + 4);
}

/* The attribute order every full rendition key is written in. */
static uint32_t _CiderCarKeyFormat(_CiderCar *car, uint32_t *attrs, uint32_t max) {
    uint32_t length = 0;
    const uint8_t *kf = _CiderCarBlock(car, _CiderCarVariable(car, "KEYFORMAT"), &length);

    if (kf == NULL || length < 12)
        return 0;

    uint32_t count = _CiderLE32(kf + 8);

    if (count > max || 12 + 4 * count > length)
        return 0;

    for (uint32_t i = 0; i < count; i++)
        attrs[i] = _CiderLE32(kf + 12 + 4 * i);

    return count;
}

/* Does a full rendition key satisfy a partial one. An attribute the key format does not list at all
 * cannot be checked and is therefore treated as satisfied; requiring it matches nothing. */
static BOOL _CiderCarKeyMatches(const uint8_t *key, const uint32_t *attrs, uint32_t attrCount,
                                const uint16_t *wantAttr, const uint16_t *wantValue, uint32_t wantCount) {
    for (uint32_t w = 0; w < wantCount; w++) {
        BOOL found = NO;

        for (uint32_t a = 0; a < attrCount; a++) {
            if (attrs[a] != wantAttr[w])
                continue;
            found = YES;
            if (_CiderLE16(key + 2 * a) != wantValue[w])
                return NO;
            break;
        }

        (void) found;
    }

    return YES;
}

/* Every LZFSE stream in a rendition body, decoded and joined. The streams are laid end to end and
 * each ends with bvx$, so one decode call over the whole body returns only the first. */
static NSMutableData *_CiderCarDecodePayload(const uint8_t *csi, uint32_t csiLength) {
    /* SIX ARGUMENTS, and the last one is the whole point: without the algorithm the callee reads
     * whatever happened to be in that register, never matches COMPRESSION_LZFSE, and returns zero,
     * which is indistinguishable from a corrupt stream. */
    static size_t (*decode)(uint8_t *, size_t, const uint8_t *, size_t, void *, int) = NULL;
    static size_t (*scratchSize)(int) = NULL;
    static void *scratch = NULL;
    static BOOL looked = NO;

    if (!looked) {
        void *lib = dlopen("/usr/lib/libcompression.dylib", RTLD_LAZY);

        if (lib != NULL) {
            decode = dlsym(lib, "compression_decode_buffer");
            scratchSize = dlsym(lib, "compression_decode_scratch_buffer_size");
        }
        looked = YES;

        /* A SCRATCH BUFFER OF OUR OWN. Passing NULL is legal and makes lzfse allocate one itself,
         * which is one more thing that can quietly fail inside a guest; asking for the size and
         * providing it removes that variable. 0x801 is COMPRESSION_LZFSE. */
        if (scratchSize != NULL) {
            size_t need = scratchSize(0x801);

            if (need > 0)
                scratch = malloc(need);
        }

        if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL)
            fprintf(stderr, "CIDER_CAR libcompression %s, decode %s, scratch %p\n",
                    lib != NULL ? "opened" : "NOT OPENED",
                    decode != NULL ? "found" : "MISSING", scratch);
    }

    if (decode == NULL)
        return nil;

    NSMutableData *out = [NSMutableData data];
    uint32_t i = 0;
    uint32_t start = 0;
    BOOL open = NO;

    while (i + 4 <= csiLength) {
        const uint8_t *p = csi + i;

        if (p[0] == 'b' && p[1] == 'v' && p[2] == 'x' &&
            (p[3] == '2' || p[3] == '1' || p[3] == 'n' || p[3] == '-')) {
            start = i;
            open = YES;
        } else if (open && p[0] == 'b' && p[1] == 'v' && p[2] == 'x' && p[3] == '$') {
            uint32_t length = i + 4 - start;
            size_t capacity = (size_t) length * 64 + 65536;
            NSMutableData *chunk = [NSMutableData dataWithLength: capacity];
            size_t got = decode([chunk mutableBytes], capacity, csi + start, length, scratch, 0x801);

            if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL) {
                static int said;

                if (said < 4) {
                    said++;
                    fprintf(stderr, "CIDER_CAR stream at %u len %u -> %lu bytes\n", start, length,
                            (unsigned long) got);
                }
            }
            if (got > 0) {
                [chunk setLength: got];
                [out appendData: chunk];
            }
            open = NO;
        }
        i++;
    }

    return [out length] > 0 ? out : nil;
}

/* A rendition that is a link says where in a packed sheet its artwork sits, and which sheet. */
typedef struct {
    BOOL isLink;
    uint32_t x, y, width, height;
    uint16_t attr[16];
    uint16_t value[16];
    uint32_t count;
} _CiderCarLink;

static void _CiderCarReadLink(const uint8_t *csi, uint32_t csiLength, _CiderCarLink *link) {
    memset(link, 0, sizeof(*link));

    for (uint32_t i = 0; i + 24 <= csiLength; i++) {
        if (memcmp(csi + i, "KLNI", 4) != 0)
            continue;

        const uint8_t *p = csi + i;

        link->isLink = YES;
        link->x = _CiderLE32(p + 8);
        link->y = _CiderLE32(p + 12);
        link->width = _CiderLE32(p + 16);
        link->height = _CiderLE32(p + 20);

        const uint8_t *pairs = p + 26;
        uint32_t room = csiLength - i - 26;

        while (link->count < 16 && room >= 4) {
            uint16_t a = _CiderLE16(pairs);
            uint16_t v = _CiderLE16(pairs + 2);

            if (a == 0)
                break;
            link->attr[link->count] = a;
            link->value[link->count] = v;
            link->count++;
            pairs += 4;
            room -= 4;
        }
        return;
    }
}


/* Find the rendition a key points at, follow a link into its sheet if there is one, and hand back
 * the artwork as an image. Scale 100 is preferred, since that is what an unscaled screen wants. */
static NSImage *_CiderCarArtwork(_CiderCar *car, const uint32_t *attrs, uint32_t attrCount,
                                 const uint8_t *rends, uint32_t rendCount,
                                 const uint16_t *wantAttr, const uint16_t *wantValue, uint32_t wantCount) {
    const uint8_t *best = NULL;
    uint32_t bestLength = 0;

    for (uint32_t i = 0; i < rendCount; i++) {
        uint32_t vi, ki, klen = 0, vlen = 0;

        _CiderCarLeafEntry(rends, i, &vi, &ki);

        const uint8_t *key = _CiderCarBlock(car, ki, &klen);
        const uint8_t *val = _CiderCarBlock(car, vi, &vlen);

        if (key == NULL || val == NULL || vlen < 32 || klen < 2 * attrCount)
            continue;
        if (memcmp(val, "ISTC", 4) != 0)
            continue;
        if (!_CiderCarKeyMatches(key, attrs, attrCount, wantAttr, wantValue, wantCount))
            continue;
        /* BGRA and GA8 both appear in these catalogs. GA8 is eight bits of grey and eight of
         * alpha, which is how a template icon is stored, and skipping it left every glyph missing
         * while the bezels behind them came through. */
        if (memcmp(val + 24, "BGRA", 4) != 0 && memcmp(val + 24, " 8AG", 4) != 0)
            continue;

        uint32_t scale = _CiderLE32(val + 20);

        if (best == NULL || scale == 100) {
            best = val;
            bestLength = vlen;
            if (scale == 100)
                break;
        }
    }

    if (best == NULL) {
        if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL)
            fprintf(stderr, "CIDER_CAR no BGRA rendition matched\n");
        return nil;
    }

    uint32_t width = _CiderLE32(best + 12);
    uint32_t height = _CiderLE32(best + 16);
    uint32_t cropX = 0, cropY = 0;
    _CiderCarLink link;

    _CiderCarReadLink(best, bestLength, &link);

    const uint8_t *sheet = best;
    uint32_t sheetLength = bestLength;

    if (link.isLink) {
        sheet = NULL;
        for (uint32_t i = 0; i < rendCount; i++) {
            uint32_t vi, ki, klen = 0, vlen = 0;

            _CiderCarLeafEntry(rends, i, &vi, &ki);

            const uint8_t *key = _CiderCarBlock(car, ki, &klen);
            const uint8_t *val = _CiderCarBlock(car, vi, &vlen);

            if (key == NULL || val == NULL || vlen < 32 || klen < 2 * attrCount)
                continue;
            if (memcmp(val, "ISTC", 4) != 0)
                continue;
            if (memcmp(val + 24, "BGRA", 4) != 0 && memcmp(val + 24, " 8AG", 4) != 0)
                continue;
            if (!_CiderCarKeyMatches(key, attrs, attrCount, link.attr, link.value, link.count))
                continue;

            sheet = val;
            sheetLength = vlen;
            break;
        }

        if (sheet == NULL)
            return nil;

        cropX = link.x;
        cropY = link.y;
        width = link.width;
        height = link.height;
    }

    uint32_t sheetHeight = _CiderLE32(sheet + 16);
    NSMutableData *pixels = _CiderCarDecodePayload(sheet, sheetLength);

    if (pixels == nil || sheetHeight == 0) {
        if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL)
            fprintf(stderr, "CIDER_CAR payload decode failed (link=%d sheetH=%u)\n",
                    link.isLink, sheetHeight);
        return nil;
    }

    /* Rows are padded, so the stride comes from the decoded size rather than from the width. */
    uint32_t stride = (uint32_t) ([pixels length] / sheetHeight);
    BOOL grey = memcmp(sheet + 24, " 8AG", 4) == 0;
    uint32_t bpp = grey ? 2 : 4;

    if (stride < (cropX + width) * bpp || (cropY + height) > sheetHeight)
        return nil;

    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes: NULL
                          pixelsWide: width
                          pixelsHigh: height
                       bitsPerSample: 8
                     samplesPerPixel: 4
                            hasAlpha: YES
                            isPlanar: NO
                      colorSpaceName: NSDeviceRGBColorSpace
                         bytesPerRow: width * 4
                        bitsPerPixel: 32] autorelease];

    if (rep == nil)
        return nil;

    const uint8_t *src = [pixels bytes];
    uint8_t *dst = [rep bitmapData];

    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *in = src + (size_t) (cropY + y) * stride + (size_t) cropX * bpp;
        uint8_t *out = dst + (size_t) y * width * 4;

        for (uint32_t x = 0; x < width; x++) {
            if (grey) {
                out[0] = in[0];
                out[1] = in[0];
                out[2] = in[0];
                out[3] = in[1];
            } else {
                out[0] = in[2];
                out[1] = in[1];
                out[2] = in[0];
                out[3] = in[3];
            }
            in += bpp;
            out += 4;
        }
    }

    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(width, height)] autorelease];

    [image addRepresentation: rep];

    return image;
}

/* The whole walk: a name, then the artwork it stands for. */
static NSImage *_CiderImageFromAssetCatalog(NSString *name) {
    static NSData *catalog = nil;
    static BOOL tried = NO;

    if (!tried) {
        NSString *path = [[NSBundle mainBundle] pathForResource: @"Assets" ofType: @"car"];

        tried = YES;
        if (path != nil)
            catalog = [[NSData alloc] initWithContentsOfFile: path];
    }

    _CiderCar car;
    BOOL trace = getenv("CIDER_TRACE_IMAGESOURCE") != NULL;

    if (catalog == nil || !_CiderCarOpen(catalog, &car)) {
        if (trace) {
            static int said;
            if (!said++) fprintf(stderr, "CIDER_CAR no catalog (data %s)\n", catalog ? "loaded" : "nil");
        }
        return nil;
    }

    uint32_t attrs[32];
    uint32_t attrCount = _CiderCarKeyFormat(&car, attrs, 32);

    if (attrCount == 0)
        return nil;

    uint32_t facetCount = 0;
    const uint8_t *facets = _CiderCarLeaf(&car, "FACETKEYS", &facetCount);
    uint32_t rendCount = 0;
    const uint8_t *rends = _CiderCarLeaf(&car, "RENDITIONS", &rendCount);

    if (facets == NULL || rends == NULL) {
        if (trace) {
            static int said;
            if (!said++) fprintf(stderr, "CIDER_CAR trees facets=%p rends=%p attrs=%u\n",
                                 (void *) facets, (void *) rends, attrCount);
        }
        return nil;
    }
    if (trace) {
        static int said;
        if (!said++) fprintf(stderr, "CIDER_CAR opened, %u facets, %u renditions, %u attrs\n",
                             facetCount, rendCount, attrCount);
    }

    const char *wantName = [name UTF8String];
    size_t wantLen = strlen(wantName);
    uint16_t wantAttr[16], wantValue[16];
    uint32_t wantCount = 0;

    for (uint32_t i = 0; i < facetCount; i++) {
        uint32_t vi, ki, klen = 0, vlen = 0;

        _CiderCarLeafEntry(facets, i, &vi, &ki);

        const uint8_t *key = _CiderCarBlock(&car, ki, &klen);
        const uint8_t *val = _CiderCarBlock(&car, vi, &vlen);

        if (key == NULL || val == NULL || vlen < 6)
            continue;
        if (klen < wantLen || memcmp(key, wantName, wantLen) != 0 || (klen > wantLen && key[wantLen] != 0))
            continue;

        uint32_t pairs = _CiderLE16(val + 4);

        for (uint32_t p = 0; p < pairs && wantCount < 16 && 6 + 4 * p + 4 <= vlen; p++) {
            wantAttr[wantCount] = _CiderLE16(val + 6 + 4 * p);
            wantValue[wantCount] = _CiderLE16(val + 6 + 4 * p + 2);
            wantCount++;
        }
        break;
    }

    if (wantCount == 0) {
        if (trace) fprintf(stderr, "CIDER_CAR no facet named %s\n", wantName);
        return nil;
    }
    if (trace) fprintf(stderr, "CIDER_CAR facet %s has %u attributes\n", wantName, wantCount);

    return _CiderCarArtwork(&car, attrs, attrCount, rends, rendCount, wantAttr, wantValue, wantCount);
}

@implementation NSImage

+ (NSArray *) imageFileTypes {
    return [self imageUnfilteredFileTypes];
}

/*
 * THE UTIs WE CAN ACTUALLY READ, which is a real answer rather than a placeholder.
 *
 * imageTypes is the modern form of imageFileTypes and applications use it to decide what to accept
 * in an open panel or a drag. It did not exist here at all, and +[NSImage imageTypes] raised an
 * unrecognized selector out of -[CCMainWindowController awakeFromNib], which unwound the document
 * nib load and left Swift Publisher with no window.
 *
 * The list mirrors the decoders registered in O2ImageSource, PNG, TIFF, JPEG, BMP, GIF and ICNS,
 * so it is neither a guess nor an empty array claiming we can read nothing. If a decoder is added
 * there this list is what has to grow with it.
 */
+ (NSArray *) imageUnfilteredTypes {
    static NSArray *types = nil;

    if (types == nil) {
        types = [[NSArray alloc] initWithObjects:
                @"public.png",
                @"public.tiff",
                @"public.jpeg",
                @"com.microsoft.bmp",
                @"com.compuserve.gif",
                @"com.apple.icns",
                nil];
    }
    return types;
}

+ (NSArray *) imageTypes {
    return [self imageUnfilteredTypes];
}

+ (NSArray *) imageUnfilteredFileTypes {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *allClasses = [NSImageRep registeredImageRepClasses];
    int i, count = [allClasses count];

    for (i = 0; i < count; i++)
        [result addObjectsFromArray: [[allClasses objectAtIndex: i]
                                             imageUnfilteredFileTypes]];

    return result;
}

+ (NSArray *) imagePasteboardTypes {
    return [self imageUnfilteredPasteboardTypes];
}

+ (NSArray *) imageUnfilteredPasteboardTypes {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *allClasses = [NSImageRep registeredImageRepClasses];
    int i, count = [allClasses count];

    for (i = 0; i < count; i++)
        [result addObjectsFromArray: [[allClasses objectAtIndex: i]
                                             imageUnfilteredPasteboardTypes]];

    return result;
}

+ (BOOL) canInitWithPasteboard: (NSPasteboard *) pasteboard {
    NSString *available = [pasteboard
            availableTypeFromArray: [self imageUnfilteredPasteboardTypes]];

    return (available != nil) ? YES : NO;
}

+ (NSArray *) _checkBundles {
    return [NSArray
            arrayWithObjects: [NSBundle
                                      mainBundle], // Check the main bundle
                                                   // first according to the doc
                              [NSBundle bundleForClass: self], nil];
}

+ (NSMutableDictionary *) allImages {
    NSMutableDictionary *result = [[[NSThread currentThread] threadDictionary]
            objectForKey: @"__allImages"];

    if (result == nil) {
        result = [NSMutableDictionary dictionary];
        [[[NSThread currentThread] threadDictionary] setObject: result
                                                        forKey: @"__allImages"];
    }

    return result;
}

+ (NSImage *) imageWithSize: (NSSize) size
                    flipped: (BOOL) flipped
             drawingHandler: (BOOL (^)(NSRect dstRect)) drawingHandler
{
    NSImage *image = [[[NSImage alloc] initWithSize: size] autorelease];
    NSImageRep *rep = [[CiderBlockImageRep alloc] initWithSize: size
                                                       flipped: flipped
                                                       handler: drawingHandler];

    [image addRepresentation: [rep autorelease]];
    return image;
}

/* System arrow templates cocotron ships no file for. MoneyMoney's Big Sur toolbar asks imageNamed:
 * for NSGoLeftTemplate/NSGoRightTemplate for its back and forward segments, and a nil image leaves
 * the segment blank. Draw the triangle so the control is not empty when no file or catalog has it. */
static NSImage *_CiderStandardTemplateImage(NSString *name) {
    BOOL right = [name isEqualToString: @"NSGoRightTemplate"] ||
                 [name isEqualToString: @"NSGoForwardTemplate"] ||
                 [name isEqualToString: @"NSRightFacingTriangleTemplate"];
    BOOL left = [name isEqualToString: @"NSGoLeftTemplate"] ||
                [name isEqualToString: @"NSGoBackTemplate"] ||
                [name isEqualToString: @"NSLeftFacingTriangleTemplate"];

    if (!right && !left)
        return nil;

    CGFloat w = 9, h = 12;
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(w, h)] autorelease];

    [image lockFocus];
    NSBezierPath *path = [NSBezierPath bezierPath];

    if (right) {
        [path moveToPoint: NSMakePoint(2, 1)];
        [path lineToPoint: NSMakePoint(2, h - 1)];
        [path lineToPoint: NSMakePoint(w - 1, h / 2)];
    } else {
        [path moveToPoint: NSMakePoint(w - 2, 1)];
        [path lineToPoint: NSMakePoint(w - 2, h - 1)];
        [path lineToPoint: NSMakePoint(1, h / 2)];
    }
    [path closePath];
    [[NSColor blackColor] set];
    [path fill];
    [image unlockFocus];
    [image setTemplate: YES];
    return image;
}

+ imageNamed: (NSString *) name {
    if (name == nil)
        return nil;

    NSImage *image = [[self allImages] objectForKey: name];
    BOOL foundAFile = NO;

    if (image == nil) {
        NSArray *bundles = [self _checkBundles];
        int i, count = [bundles count];

        for (i = 0; i < count; i++) {
            NSBundle *bundle = [bundles objectAtIndex: i];
            NSString *path = [bundle pathForImageResource: name];

            if (path != nil) {
                foundAFile = YES;
                image = [[[NSImage alloc] initWithContentsOfFile: path]
                        autorelease];
                [image setName: name];
                if (image) {
                    break;
                }
            }
        }
    }

    /* NOTHING LOOSE ON DISK, SO TRY THE COMPILED CATALOG. Everything above reads resource FILES,
     * and a modern application ships its artwork in Contents/Resources/Assets.car instead. */
    /* A ONE SHOT SELF TEST. Whether an application asks for a catalog name at all varies from run
     * to run, so waiting for one to prove the reader works is waiting on the wrong thing. With the
     * trace on, ask for a name that is known to be in the Swift Publisher catalog and say what came
     * back. CIDER_CAR_SELFTEST names it. */
    if (getenv("CIDER_CAR_SELFTEST") != NULL) {
        static int ran;

        if (!ran++) {
            NSString *probeName = [NSString stringWithUTF8String: getenv("CIDER_CAR_SELFTEST")];
            NSImage *probe = _CiderImageFromAssetCatalog(probeName);
            NSSize size = probe != nil ? [probe size] : NSMakeSize(0, 0);

            fprintf(stderr, "CIDER_CAR selftest %s -> %s %.0fx%.0f\n", [probeName UTF8String],
                    probe != nil ? "IMAGE" : "nil", size.width, size.height);
            fflush(stderr);

            /* WRITE THE PIXELS OUT SO THEY CAN BE LOOKED AT. A size is not a picture: the only way
             * to know the reader produced the right artwork rather than the right dimensions is to
             * see it. Raw RGBA, with the dimensions on the first line. */
            const char *dumpPath = getenv("CIDER_CAR_SELFTEST_OUT");

            if (probe != nil && dumpPath != NULL) {
                NSArray *reps = [probe representations];
                NSBitmapImageRep *rep = [reps count] > 0 ? [reps objectAtIndex: 0] : nil;

                if (rep != nil && [rep isKindOfClass: [NSBitmapImageRep class]]) {
                    FILE *out = fopen(dumpPath, "wb");

                    if (out != NULL) {
                        int w = (int) [rep pixelsWide];
                        int h = (int) [rep pixelsHigh];

                        fprintf(out, "%d %d\n", w, h);
                        fwrite([rep bitmapData], 1, (size_t) w * h * 4, out);
                        fclose(out);
                    }
                }
            }
        }
    }

    BOOL fromCatalog = NO;

    if (image == nil) {
        image = _CiderImageFromAssetCatalog(name);
        if (image != nil) {
            [image setName: name];
            fromCatalog = YES;
        }
    }

    if (image == nil) {
        image = _CiderStandardTemplateImage(name);
        if (image != nil)
            [image setName: name];
    }

    /* WHICH NAMES COME BACK EMPTY, and where the ones that do not came from. A button whose image
     * is nil draws its title, so a toolbar full of the word Button is a list of lookups that
     * failed. The three outcomes are worth telling apart: a loose resource file, the compiled asset
     * catalog, or nothing at all. */
    if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL && getenv("CIDER_TRACE_IMAGESOURCE")[0] != (char) 0) {
        fprintf(stderr, "CIDER_IMAGESOURCE imageNamed %s -> %s\n", [name UTF8String],
                image == nil ? (foundAFile ? "FILE BUT NO DECODER" : "NOTHING")
                             : (fromCatalog ? "CATALOG" : (foundAFile ? "loose file" : "cache")));
        fflush(stderr);
    }

    // Cocoa AppKit always returns the same shared cached image
    return image;
}

- (void) encodeWithCoder: (NSCoder *) coder {
    NSUnimplementedMethod();
}

- initWithCoder: (NSCoder *) coder {
    if ([coder allowsKeyedCoding]) {
        NSKeyedUnarchiver *keyed = (NSKeyedUnarchiver *) coder;
        NSUInteger length;
        const unsigned char *tiff =
                [keyed decodeBytesForKey: @"NSTIFFRepresentation"
                          returnedLength: &length];
        NSBitmapImageRep *rep;

        if (tiff == NULL) {
            [self release];
            return nil;
        }

        rep = [NSBitmapImageRep
                imageRepWithData: [NSData dataWithBytes: tiff length: length]];
        if (rep == nil) {
            [self release];
            return nil;
        }

        _name = nil;
        _size = NSMakeSize(0, 0);
        _representations = [NSMutableArray new];

        [_representations addObject: rep];
    } else {
        NSInteger version = [coder versionForClassName: @"NSImage"];

        if (version >= 17) {
            _name = [[coder decodeObject] retain];

            NSUnarchiver *unarchiver = (NSUnarchiver *)coder;

            uint8_t byteOne = [unarchiver decodeByte];
            uint8_t byteTwo = [unarchiver decodeByte];

            // TODO: There's some logic involving these decoded
            // bytes and the internal _flags of NSImage to determine
            // decoding the rest of these.

            for (int i = 0; i < 12; ++i) {
                uint8_t btye = [unarchiver decodeByte];
            }

            _size = [coder decodeSize];

            short shortValue;
            [coder decodeValueOfObjCType:"s" at: &shortValue];

            uint8_t anotherBtye = [unarchiver decodeByte];

            NSBitmapImageRep *rep = [coder decodeObject];
            _representations = [NSMutableArray new];
            [_representations addObject: rep];

            _backgroundColor = [[coder decodeObject] retain];
            _delegate = [coder decodeObject];
        } else {
            [NSException raise: NSInvalidArgumentException
                    format: @"-[%@ %s] is not implemented for coder %@",
                            [self class], sel_getName(_cmd), coder];
        }
    }
    return self;
}

- initWithSize: (NSSize) size {
    _name = nil;
    _size = size;
    _representations = [NSMutableArray new];
    return self;
}

- init {
    return [self initWithSize: NSMakeSize(0, 0)];
}

- initWithData: (NSData *) data {
    Class repClass = [NSImageRep imageRepClassForData: data];
    NSArray *reps = nil;

    if ([repClass respondsToSelector: @selector(imageRepsWithData:)])
        reps = [repClass performSelector: @selector(imageRepsWithData:)
                              withObject: data];
    else if ([repClass respondsToSelector: @selector(imageRepWithData:)]) {
        NSImageRep *rep =
                [repClass performSelector: @selector(imageRepWithData:)
                               withObject: data];

        if (rep != nil)
            reps = [NSArray arrayWithObject: rep];
    }

    /* WHICH CLASS CLAIMED THE DATA AND WHAT IT PRODUCED. A nil returned here goes to a caller that
     * usually does not check it, and the picture simply never appears. */
    if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL && getenv("CIDER_TRACE_IMAGESOURCE")[0] != '\0') {
        fprintf(stderr, "CIDER_IMAGESOURCE NSImage initWithData bytes=%lu repClass=%s reps=%lu\n",
                (unsigned long) [data length],
                repClass ? class_getName(repClass) : "(nil)",
                (unsigned long) [reps count]);
        fflush(stderr);
    }

    if ([reps count] == 0) {
        [self release];
        return nil;
    }

    _name = nil;
    _size = NSMakeSize(0, 0);
    _representations = [NSMutableArray new];

    [_representations addObjectsFromArray: reps];

    return self;
}

- initWithContentsOfFile: (NSString *) path {
    NSArray *reps = [NSImageRep imageRepsWithContentsOfFile: path];

    if ([reps count] == 0) {
        [self release];
        return nil;
    }

    _name = nil;
    _size = NSMakeSize(0, 0);
    _representations = [NSMutableArray new];

    [_representations addObjectsFromArray: reps];

    return self;
}

- initWithContentsOfURL: (NSURL *) url {
    NSData *data = [NSData dataWithContentsOfURL: url];

    if (data == nil) {
        [self release];
        return nil;
    }

    return [self initWithData: data];
}

- initWithCGImage: (CGImageRef) cgImage size: (NSSize) size; {
    if (self = [self initWithSize: size]) {
        NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc]
                initWithCGImage: cgImage] autorelease];
        [_representations addObject: rep];
    }
    return self;
}

- initWithPasteboard: (NSPasteboard *) pasteboard {

    NSString *available =
            [pasteboard availableTypeFromArray:
                                [[self class] imageUnfilteredPasteboardTypes]];
    NSData *data = [pasteboard dataForType: available];
    if (data == nil) {
        [self release];
        return nil;
    }
    return [self initWithData: data];
}

- initByReferencingFile: (NSString *) path {
    return [self initWithContentsOfFile: path];
}

- initByReferencingURL: (NSURL *) url {
    // Better than nothing
    return [self initWithContentsOfURL: url];
}

- (void) dealloc {
    [_name release];
    [_backgroundColor release];
    [_representations release];
    [super dealloc];
}

- copyWithZone: (NSZone *) zone {
    NSImage *result = NSCopyObject(self, 0, zone);

    result->_name = [_name copy];
    result->_backgroundColor = [_backgroundColor copy];
    result->_representations = [_representations mutableCopy];

    return result;
}

- (NSString *) name {
    return _name;
}

- (NSSize) size {
    if (_size.width == 0.0 && _size.height == 0.0) {
        int i, count = [_representations count];
        NSSize largestSize = NSMakeSize(0, 0);

        for (i = 0; i < count; i++) {
            NSImageRep *check = [_representations objectAtIndex: i];
            NSSize checkSize = [check size];

            if (checkSize.width * checkSize.height >
                largestSize.width * largestSize.height)
                largestSize = checkSize;
        }

        return largestSize;
    }

    return _size;
}

- (NSColor *) backgroundColor {
    return _backgroundColor;
}

- (BOOL) isFlipped {
    return _isFlipped;
}

- (BOOL) isTemplate {
    return _isTemplate;
}

- (BOOL) scalesWhenResized {
    return _scalesWhenResized;
}

- (BOOL) matchesOnMultipleResolution {
    return _matchesOnMultipleResolution;
}

- (BOOL) usesEPSOnResolutionMismatch {
    return _usesEPSOnResolutionMismatch;
}

- (BOOL) prefersColorMatch {
    return _prefersColorMatch;
}

- (NSImageCacheMode) cacheMode {
    return _cacheMode;
}

- (BOOL) isCachedSeparately {
    return _isCachedSeparately;
}

- (BOOL) cacheDepthMatchesImageDepth {
    return _cacheDepthMatchesImageDepth;
}

- (BOOL) isDataRetained {
    return _isDataRetained;
}

- delegate {
    return _delegate;
}

- (BOOL) setName: (NSString *) name {
    if (_name != nil && [[NSImage allImages] objectForKey: _name] == self)
        [[NSImage allImages] removeObjectForKey: _name];

    name = [name copy];
    [_name release];
    _name = name;

    if ([[NSImage allImages] objectForKey: _name] != nil)
        return NO;

    [[NSImage allImages] setObject: self forKey: _name];
    return YES;
}

- (void) setSize: (NSSize) size {
    _size = size;
    [self recache];
}

- (void) setBackgroundColor: (NSColor *) value {
    value = [value copy];
    [_backgroundColor release];
    _backgroundColor = value;
}

- (void) setFlipped: (BOOL) value {
    _isFlipped = value;
}

- (void) setTemplate: (BOOL) value {
    _isTemplate = value;
}

- (void) setScalesWhenResized: (BOOL) value {
    _scalesWhenResized = value;
}

- (void) setMatchesOnMultipleResolution: (BOOL) value {
    _matchesOnMultipleResolution = value;
}

- (void) setUsesEPSOnResolutionMismatch: (BOOL) value {
    _usesEPSOnResolutionMismatch = value;
}

- (void) setPrefersColorMatch: (BOOL) value {
    _prefersColorMatch = value;
}

- (void) setCacheMode: (NSImageCacheMode) value {
    _cacheMode = value;
}

- (void) setCachedSeparately: (BOOL) value {
    _isCachedSeparately = value;
}

- (void) setCacheDepthMatchesImageDepth: (BOOL) value {
    _cacheDepthMatchesImageDepth = value;
}

- (void) setDataRetained: (BOOL) value {
    _isDataRetained = value;
}

- (void) setDelegate: delegate {
    _delegate = delegate;
}

/*
 * ANSWERING NO TO THIS IS NOT A HARMLESS STUB, it is a refusal to draw.
 *
 * This returned 0 unconditionally, and 0 is NO. Applications ask isValid before they use an image
 * and skip the drawing entirely when it says no, so every such image became a correctly sized,
 * correctly placed, completely empty rectangle, with no error anywhere to say why.
 *
 * That is precisely what an iTerm2 inline image was. The picture was decoded by the sandboxed
 * worker, drawn into a bitmap, encoded, carried back over NSXPCConnection, and rebuilt into a
 * 240x120 rep in the application, and then nothing ever drew it: no drawInRect, no
 * O2ContextDrawImage, just a grey placeholder and eleven of these lines in the log.
 *
 * Valid means there is something to draw, so that is what is measured: a representation with a
 * real size. An image that has not loaded yet has no representation and is honestly not drawable
 * yet, which is the same answer this gave before and so cannot be a regression.
 */
- (BOOL) isValid {
    NSInteger i, count = [_representations count];

    for (i = 0; i < count; i++) {
        NSSize size = [[_representations objectAtIndex: i] size];

        if (size.width > 0 && size.height > 0) {
            return YES;
        }
    }
    return NO;
}

- (NSArray *) representations {
    return _representations;
}

- (void) addRepresentation: (NSImageRep *) representation {
    if (representation != nil)
        [_representations addObject: representation];
}

- (void) addRepresentations: (NSArray *) array {
    int i, count = [array count];

    for (i = 0; i < count; i++)
        [self addRepresentation: [array objectAtIndex: i]];
}

- (void) removeRepresentation: (NSImageRep *) representation {
    [_representations removeObjectIdenticalTo: representation];
}

- (NSCachedImageRep *) _cachedImageRepCreateIfNeeded {
    int count = [_representations count];

    while (--count >= 0) {
        NSCachedImageRep *check = [_representations objectAtIndex: count];

        if ([check isKindOfClass: [NSCachedImageRep class]]) {

            if (_cacheIsValid)
                return check;

            [_representations removeObjectAtIndex: count];
        }
    }

    NSCachedImageRep *cached =
            [[NSCachedImageRep alloc] initWithSize: [self size]
                                             depth: 0
                                          separate: _isCachedSeparately
                                             alpha: YES];
    [self addRepresentation: cached];
    [cached release];
    return cached;
}

- (NSImageRep *) _bestUncachedRepresentationForDevice: (NSDictionary *) device {
    int i, count = [_representations count];

    for (i = 0; i < count; i++) {
        NSImageRep *check = [_representations objectAtIndex: i];

        if (![check isKindOfClass: [NSCachedImageRep class]]) {
            return check;
        }
    }

    return nil;
}

- (NSImageRep *)
        _bestUncachedFallbackCachedRepresentationForDevice:
                (NSDictionary *) device
                                                      size: (NSSize) size
{
    int i, count = [_representations count];
    NSImageRep *best = nil;

    size.width = ABS(size.width);
    size.height = ABS(size.height);

    for (i = 0; i < count; i++) {
        NSImageRep *check = [_representations objectAtIndex: i];

        if (![check isKindOfClass: [NSCachedImageRep class]]) {
            if (best == nil)
                best = check;
            else {
                NSSize checkSize = [check size];
                NSSize bestSize = [best size];
                CGFloat checkArea = checkSize.width * checkSize.height;
                CGFloat bestArea = bestSize.width * bestSize.height;
                CGFloat desiredArea = size.width * size.height;

                // downsampling is better than upsampling
                if (bestArea < desiredArea && checkArea >= desiredArea)
                    best = check;
                // downsampling a closer image is better
                if (checkArea < bestArea && checkArea >= desiredArea)
                    best = check;
                // if we have to upsample, biggest is better
                if (checkArea > bestArea && bestArea < desiredArea)
                    best = check;
            }
        }
    }

    if (best != nil)
        return best;

    for (i = 0; i < count; i++) {
        NSImageRep *check = [_representations objectAtIndex: i];

        if ([check isKindOfClass: [NSCachedImageRep class]]) {
            return check;
        }
    }

    return nil;
}

- (NSImageRep *) bestRepresentationForDevice: (NSDictionary *) device {
    if (device == nil)
        device = [[NSGraphicsContext currentContext] deviceDescription];

    if ([device objectForKey: NSDeviceIsPrinter] != nil) {
        int i, count = [_representations count];

        for (i = 0; i < count; i++) {
            NSImageRep *check = [_representations objectAtIndex: i];

            if (![check isKindOfClass: [NSCachedImageRep class]])
                return check;
        }
    }

    if ([device objectForKey: NSDeviceIsScreen] != nil) {
        NSImageRep *uncached =
                [self _bestUncachedRepresentationForDevice: device];
        NSImageCacheMode caching = _cacheMode;

        if (caching == NSImageCacheDefault) {
            if ([uncached isKindOfClass: [NSBitmapImageRep class]])
                caching = NSImageCacheBySize;
            else if ([uncached isKindOfClass: [NSPDFImageRep class]])
                caching = NSImageCacheAlways;
            else if ([uncached isKindOfClass: [NSEPSImageRep class]])
                caching = NSImageCacheAlways;
            else if ([uncached isKindOfClass: [NSCustomImageRep class]])
                caching = NSImageCacheAlways;
        }

        switch (caching) {

        case NSImageCacheDefault:
        case NSImageCacheAlways:
            break;

        case NSImageCacheBySize:
            if ([[uncached colorSpaceName]
                        isEqual: [device objectForKey:
                                                 NSDeviceColorSpaceName]]) {
                NSSize size = [self size];

                if ((size.width == [uncached pixelsWide]) &&
                    (size.height == [uncached pixelsHigh])) {
                    int deviceBPS = [[device
                            objectForKey: NSDeviceBitsPerSample] intValue];

                    if (deviceBPS == [uncached bitsPerSample])
                        return uncached;
                }
            }
            break;

        case NSImageCacheNever:
            return uncached;
        }

        NSCachedImageRep *cached = [self _cachedImageRepCreateIfNeeded];

        if (!_cacheIsValid) {
            [self lockFocusOnRepresentation: cached];
            NSRect rect;
            rect.origin.x = 0;
            rect.origin.y = 0;
            rect.size = [self size];

            if ([self scalesWhenResized]) {
                [self drawRepresentation: uncached inRect: rect];
            } else
                [uncached drawAtPoint: rect.origin];

            [self unlockFocus];
            _cacheIsValid = YES;
        }

        return cached;
    }

    return [_representations lastObject];
}

- (void) recache {
    // This doesn't actually remove the cache, it just marks it as invalid
    // This is important because you can change the size of a drawn image
    // and it doesn't destroy the cache. It is recached next time it is drawn.
    _cacheIsValid = NO;
}

- (void) cancelIncrementalLoad {
    NSUnimplementedMethod();
}

- (NSData *) TIFFRepresentation {
    return [self TIFFRepresentationUsingCompression: NSTIFFCompressionNone
                                             factor: 0.0];
}

- (NSData *) TIFFRepresentationUsingCompression: (NSTIFFCompression) compression
                                         factor: (float) factor
{
    NSMutableArray *bitmaps = [NSMutableArray array];

    for (NSImageRep *check in _representations) {
        if ([check isKindOfClass: [NSBitmapImageRep class]]) {
            [bitmaps addObject: check];
        } else if ([check isKindOfClass: [NSCachedImageRep class]]) {
            // We don't use the general case else we get flipped results for
            // flipped images since lockFocusOnRepresentation is flipping and
            // the Cache content is already flipped
            NSRect r = {.origin = NSZeroPoint, .size = check.size};
            [self lockFocus];
            NSBitmapImageRep *image =
                    [[NSBitmapImageRep alloc] initWithFocusedViewRect: r];
            [self unlockFocus];

            [bitmaps addObject: image];
            [image release];
        } else {
            NSSize size = [check size];
            NSBitmapImageRep *image = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes: NULL
                                  pixelsWide: size.width
                                  pixelsHigh: size.height
                               bitsPerSample: 8
                             samplesPerPixel: 4
                                    hasAlpha: YES
                                    isPlanar: NO
                              colorSpaceName: NSDeviceRGBColorSpace
                                 bytesPerRow: 0
                                bitsPerPixel: 32];

            [self lockFocusOnRepresentation: image];
            // we should probably use -draw here but not all reps implement it,
            // or not?
            [check draw];
            [self unlockFocus];

            [bitmaps addObject: image];
            [image release];
        }
    }

    return [NSBitmapImageRep TIFFRepresentationOfImageRepsInArray: bitmaps
                                                 usingCompression: compression
                                                           factor: factor];
}

- (void) lockFocus {
    [self lockFocusOnRepresentation: nil];
}

/*
 * DRAWING INTO AN IMAGE WITH THE ORIGIN AT THE TOP, which is what an application asks for when it
 * renders an icon it is about to put in a view whose coordinates run downwards.
 *
 * IT IS ON THE SAVE PATH, which is why a missing method here was not a cosmetic gap: Command S in
 * LibreOffice raised -[NSImage lockFocusFlipped:] as an unrecognized selector, the application
 * caught it, and the save panel never opened. Nothing was logged but the raise itself, and the
 * document simply did not save.
 *
 * The flip is the CTM, not a flag: translate to the top edge and invert Y, so a drawing operation
 * with a small y lands near the top. lockFocus does the rest and unlockFocus is unchanged, since
 * restoring the context discards the transform with it.
 */
- (void) lockFocusFlipped: (BOOL) flipped {
    [self lockFocus];

    if (flipped) {
        CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];

        if (context != NULL) {
            CGContextTranslateCTM(context, 0.0, [self size].height);
            CGContextScaleCTM(context, 1.0, -1.0);
        }
    }
}

- (void) lockFocusOnRepresentation: (NSImageRep *) representation {
    NSGraphicsContext *context = nil;
    CGContextRef graphicsPort;

    if (representation == nil) {
        // FIXME: Cocoa doesn't add the cached rep until the unlockFocus, it
        // just creates the drawing context then snaps the image during unlock
        // and adds it
        representation = [self _cachedImageRepCreateIfNeeded];

        [self lockFocusOnRepresentation: representation];
        NSRect rect;
        id uncached = [self _bestUncachedRepresentationForDevice: nil];
        rect.origin.x = 0;
        rect.origin.y = 0;
        rect.size = [self size];

        //    if([self scalesWhenResized])
        [uncached drawInRect: rect];
        // drawAtPoint: is not working with NSPDFImageRep
        // Should probably ditch all the caching stuff anyway as it is
        // deprecated
        //   else
        //   [uncached drawAtPoint:rect.origin];

        [self unlockFocus];
        _cacheIsValid = YES;
    }

    if ([representation isKindOfClass: [NSCachedImageRep class]])
        context = [NSGraphicsContext
                graphicsContextWithWindow: [(NSCachedImageRep *) representation
                                                   window]];
    else if ([representation isKindOfClass: [NSBitmapImageRep class]])
        context = [NSGraphicsContext
                graphicsContextWithBitmapImageRep: (NSBitmapImageRep *)
                                                           representation];

    if (context == nil) {
        [NSException raise: NSInvalidArgumentException
                    format: @"NSImageRep %@ can not be lockFocus'd"];
        return;
    }

    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext: context];

    graphicsPort = NSCurrentGraphicsPort();
    CGContextSaveGState(graphicsPort);
    CGContextClipToRect(graphicsPort,
                        NSMakeRect(0, 0, [representation size].width,
                                   [representation size].height));

    // Some fake view, just so the context knows if it's flipped or not
    NSView *view = [[[NSImageCacheView alloc] initWithFlipped: [self isFlipped]]
            autorelease];
    [[context focusStack] addObject: self];

    if ([self isFlipped]) {
        CGAffineTransform flip = {1, 0, 0, -1, 0, [self size].height};
        CGContextConcatCTM(graphicsPort, flip);
    }
}

- (void) unlockFocus {
    // Remove the pushed view
    [[[NSGraphicsContext currentContext] focusStack] removeLastObject];

    CGContextRef graphicsPort = NSCurrentGraphicsPort();

    CGContextRestoreGState(graphicsPort);

    [NSGraphicsContext restoreGraphicsState];
}

- (BOOL) drawRepresentation: (NSImageRep *) representation
                     inRect: (NSRect) rect
{
    NSColor *bg = [self backgroundColor];

    if (bg != nil) {
        [bg setFill];
        NSRectFill(rect);
    }

    return [representation drawInRect: rect];
}

- (void) compositeToPoint: (NSPoint) point
                 fromRect: (NSRect) rect
                operation: (NSCompositingOperation) operation
{
    [self compositeToPoint: point
                  fromRect: rect
                 operation: operation
                  fraction: 1.0];
}

- (void) compositeToPoint: (NSPoint) point
                 fromRect: (NSRect) source
                operation: (NSCompositingOperation) operation
                 fraction: (CGFloat) fraction
{
    /* Compositing is a blitting operation. We simulate it using the draw
       operation.

       Compositing does not honor all aspects of the CTM, e.g. it will keep an
       image upright regardless of the orientation of CTM. To deal with that we
       use a negative height in a flipped coordinate system. There are probably
       other cases which are not right here.
     */

    NSSize size = [self size];
    NSRect rect = NSMakeRect(point.x, point.y, size.width, size.height);

    NSGraphicsContext *graphicsContext = [NSGraphicsContext currentContext];
    CGContextRef context = [graphicsContext graphicsPort];

    CGContextSaveGState(context);
    if ([[NSGraphicsContext currentContext] isFlipped]) {
        rect.size.height = -rect.size.height;
    }

    [self drawInRect: rect
             fromRect: source
            operation: operation
             fraction: fraction];
    CGContextRestoreGState(context);
}

- (void) compositeToPoint: (NSPoint) point
                operation: (NSCompositingOperation) operation
{
    [self compositeToPoint: point operation: operation fraction: 1.0];
}

- (void) compositeToPoint: (NSPoint) point
                operation: (NSCompositingOperation) operation
                 fraction: (CGFloat) fraction
{
    [self compositeToPoint: point
                  fromRect: NSZeroRect
                 operation: operation
                  fraction: 1.0];
}

- (void) dissolveToPoint: (NSPoint) point fraction: (CGFloat) fraction {
    NSUnimplementedMethod();
}

- (void) dissolveToPoint: (NSPoint) point
                fromRect: (NSRect) rect
                fraction: (CGFloat) fraction
{
    NSUnimplementedMethod();
}

- (void) drawAtPoint: (NSPoint) point
            fromRect: (NSRect) source
           operation: (NSCompositingOperation) operation
            fraction: (CGFloat) fraction
{
    NSSize size = [self size];

    [self drawInRect: NSMakeRect(point.x, point.y, size.width, size.height)
             fromRect: source
            operation: operation
             fraction: fraction];
}

/*
 * THE WHOLE IMAGE INTO A RECT, which is the shorthand every other drawInRect: is built on.
 *
 * NSZeroRect for the source means the entire image, source over is what a plain draw does, and the
 * fraction is 1. iTerm2 calls this while it builds its window and the raise terminated it.
 */
- (void) drawInRect: (NSRect) rect {
    [self drawInRect: rect
            fromRect: NSZeroRect
           operation: NSCompositeSourceOver
            fraction: 1.0];
}

- (void) drawInRect: (NSRect) rect
           fromRect: (NSRect) source
          operation: (NSCompositingOperation) operation
           fraction: (CGFloat) fraction
{

    // Keep a lid on any intermediate allocations while producing caches
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSImageRep *any = [[[self
            _bestUncachedFallbackCachedRepresentationForDevice: nil
                                                          size: rect.size]
            retain] autorelease];

    /* DID THE APPLICATION EVEN ASK. An image that is never drawn and an image that is drawn and
     * comes out blank are the same rectangle from outside, and that is exactly the open question
     * about iTerm2 inline images: the picture is decoded, transported and rebuilt, and no draw of
     * it ever reaches the window. */
    if (getenv("CIDER_TRACE_IMAGESOURCE") != NULL && getenv("CIDER_TRACE_IMAGESOURCE")[0] != '\0') {
        NSSize mine = [self size];

        fprintf(stderr,
                "CIDER_IMAGESOURCE NSImage drawInRect %gx%g at %g,%g size=%gx%g reps=%lu best=%s\n",
                rect.size.width, rect.size.height, rect.origin.x, rect.origin.y,
                mine.width, mine.height, (unsigned long) [_representations count],
                any ? class_getName([any class]) : "(nil)");
        fflush(stderr);
    }
    NSImageRep *cachedRep = nil;
    CGContextRef context;
    NSRect fullRect = {.origin = NSZeroPoint, .size = self.size};
    BOOL drawFullImage =
            (NSIsEmptyRect(source) || NSEqualRects(source, fullRect));
    BOOL canCache = drawFullImage && !_isFlipped;

    if (canCache) {
        // If we're drawing the full image unflipped then we can just draw from
        // a cached rep or a bitmap rep (assuming we have one)
        if ([any isKindOfClass: [NSCachedImageRep class]] ||
            [any isKindOfClass: [NSBitmapImageRep class]]) {
            cachedRep = any;
        }
    }

    if (cachedRep == nil) {
        // Looks like we need to create a cached rep for this image
        NSImageRep *uncached = any;
        NSSize uncachedSize = [uncached size];
        BOOL useSourceRect = NSIsEmptyRect(source) ? NO : YES;
        NSSize cachedSize = useSourceRect ? source.size : uncachedSize;

        // Create a cached image rep to hold our image
        NSCachedImageRep *cached =
                [[[NSCachedImageRep alloc] initWithSize: cachedSize
                                                  depth: 0
                                               separate: YES
                                                  alpha: YES]
                        autorelease]; // remember that pool we created earlier

        // a non-nil object passed here means we need to manually add the rep
        [self lockFocusOnRepresentation: cached];

        context = NSCurrentGraphicsPort();
        if (useSourceRect) {
            // move to the origin of the source rect - remember we've locked
            // focus so we've got a fresh CTM to work with
            CGContextTranslateCTM(context, -source.origin.x, -source.origin.y);
        }
        if (_isFlipped) {
            // Flip the CTM so the image is drawn the right way up in the cache
            CGContextTranslateCTM(context, 0, uncachedSize.height);
            CGContextScaleCTM(context, 1, -1);
        }
        // Draw into the new cache rep
        [self drawRepresentation: uncached
                          inRect: NSMakeRect(0, 0, uncachedSize.width,
                                             uncachedSize.height)];

        [self unlockFocus];

        // And keep it if it makes sense
        if (canCache) {
            [self addRepresentation: cached];
        }

        cachedRep = cached;
    }

    // OK now we've got a rep we can draw

    context = NSCurrentGraphicsPort();

    CGContextSaveGState(context);

    if (CGContextSupportsGlobalAlpha(context) == NO) {
        // That should really be done by setting the context alpha - and the
        // compositing done in the context implementation
        if (fraction != 1.0) {
            // fraction is accomplished with a 1x1 alpha mask
            // FIXME: could use a float format image to completely preserve
            // fraction
            uint8_t bytes[1] = {MIN(MAX(0, fraction * 255), 255)};
            CGDataProviderRef provider =
                    CGDataProviderCreateWithData(NULL, bytes, 1, NULL);
            CGImageRef mask =
                    CGImageMaskCreate(1, 1, 8, 8, 1, provider, NULL, NO);

            CGContextClipToMask(context, rect, mask);
            CGImageRelease(mask);
            CGDataProviderRelease(provider);
        }
    } else {
        CGContextSetAlpha(context, fraction);
    }
    [[NSGraphicsContext currentContext] setCompositingOperation: operation];

    [self drawRepresentation: cachedRep inRect: rect];

    CGContextRestoreGState(context);

    [pool release];
}

- (void) drawInRect: (NSRect) rect
           fromRect: (NSRect) source
          operation: (NSCompositingOperation) operation
           fraction: (CGFloat) fraction
     respectFlipped: (BOOL) respectFlipped
                 hints: (NSDictionary<NSString *, id> *) hints
{
    printf("STUB %s\n", __PRETTY_FUNCTION__);

    [self drawInRect: rect
            fromRect: source
           operation: operation
            fraction: fraction];
}

- (NSString *) description {
    NSSize size = [self size];

    return [NSString
            stringWithFormat:
                    @"<%@[%p] name: %@ size: { %f, %f } representations: %@>",
                    [self class], self, _name, size.width, size.height,
                    _representations];
}

@end

@implementation NSBundle (NSImage)

- (NSString *) pathForImageResource: (NSString *) name {
    NSString *extension = [name pathExtension];
    if (extension && extension.length) {
        NSString *baseName = [name stringByDeletingPathExtension];
        return [self pathForResource: baseName ofType: extension];
    }
    NSArray *types = [NSImage imageFileTypes];
    int i, count = [types count];

    for (i = 0; i < count; i++) {
        NSString *type = [types objectAtIndex: i];
        NSString *path = [self pathForResource: name ofType: type];

        if (path != nil)
            return path;
    }

    return [self pathForResource: [name stringByDeletingPathExtension]
                          ofType: [name pathExtension]];
}

/*
 * THE IMAGE ITSELF, not the path to it. -imageForResource: is what an application actually calls,
 * and it was missing while the path lookup underneath it has been here all along, so iTerm2 raised
 * on it while building a terminal window. macOS also finds images in a compiled asset catalog and
 * this cannot, so a name that lives only in Assets.car answers nil rather than an image; a name
 * that is a file in the bundle answers the image.
 */
- (NSImage *) imageForResource: (NSString *) name {
    NSString *path = [self pathForImageResource: name];

    if (path == nil)
        return nil;

    NSImage *image = [[[NSImage alloc] initWithContentsOfFile: path] autorelease];

    [image setName: name];

    return image;
}

@end
