/* Copyright (c) 2006-2007 Christopher J. W. Lloyd

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

#import "NSCustomObject.h"
#import "NSIBObjectData.h"
#import "NSNibHelpConnector.h"
#import <AppKit/NSApplication.h>
#import <AppKit/NSMenu.h>
#include <stdio.h>

#import <AppKit/NSNib.h>
#include <objc/runtime.h>
#include <pthread.h>
#import <Foundation/NSThread.h>
#include <stdlib.h>
#import "NSNIBArchiveUnarchiver.h"
#import <AppKit/NSNibLoading.h>
#import <AppKit/NSRaise.h>
#import <AppKit/NSTableCornerView.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSURL.h>

NSString *const NSNibOwner = @"NSOwner";
NSString *const NSNibTopLevelObjects = @"NSNibTopLevelObjects";

@implementation NSNib

- initWithCoder: (NSCoder *) coder {
    if ([coder allowsKeyedCoding]) {
        _data = [[coder decodeObjectForKey: @"NSNibFileData"] retain];

        // TODO: NSNibFileIsKeyed
        // NSNibFileUseParentBundle
        // NSNibFileBundleName
        // NSNibFileImages
        // NSNibFileSounds
    } else {
        NSString *bundleIdentifier;
        BOOL isKeyed;
        NSArray *imageBlobs, *soundBlobs;
        NSArray *images, *sounds;

        [coder decodeValuesOfObjCTypes: "@s@@@@@", &_data, &isKeyed,
                                        &bundleIdentifier, &images, &imageBlobs,
                                        &sounds, &soundBlobs];

        // TODO
        [imageBlobs release];
        [images release];
        [soundBlobs release];
        [sounds release];
    }

    return self;
}

- initWithContentsOfFile: (NSString *) path {

    NIBDEBUG(@"initWithContentsOfFile: %@", path);

    /* AT THE ENTRY, so that silence downstream means something. A trace on the decode alone cannot
     * tell a nib that failed to decode from a nib that was never opened. */
    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB open %s\n", [path UTF8String]);
        fflush(stderr);
    }

    NSString *objects = path;
    BOOL isDirectory = NO;

    if (![[NSFileManager defaultManager] fileExistsAtPath: path
                                              isDirectory: &isDirectory]) {
        [self release];
        return nil;
    }
    if (isDirectory) {
        objects = [[path stringByAppendingPathComponent: @"keyedobjects"]
                stringByAppendingPathExtension: @"nib"];

        if ([[NSFileManager defaultManager] fileExistsAtPath: objects])
            _flags._isKeyed = TRUE;
        else
            objects = [[path stringByAppendingPathComponent: @"objects"]
                    stringByAppendingPathExtension: @"nib"];
    } else {
        // FIXME: Should we try to infer keyed-ness form the file itself in this
        // case?
        _flags._isKeyed = TRUE;
    }

    if (!objects && !isDirectory) {
        objects = path; // assume new-style compiled xib
        _flags._isKeyed = TRUE;
    }

    if ((_data = [[NSData alloc] initWithContentsOfFile: objects]) == nil) {
        [self release];
        return nil;
    }

    _allObjects = [NSMutableArray new];

    return self;
}

- initWithContentsOfURL: (NSURL *) url {

    NIBDEBUG(@"initWithContentsOfURL: %@", url);

    if (![url isFileURL]) {
        [self release];
        return nil;
    }

    return [self initWithContentsOfFile: [url path]];
}

- initWithNibNamed: (NSString *) name bundle: (NSBundle *) bundle {

    NIBDEBUG(@"initWithNibNamed: %@ bundle: %@", name, bundle);

    if (bundle == nil)
        bundle = [NSBundle mainBundle];

    NSString *path = [bundle pathForResource: name ofType: @"nib"];

    if (path == nil) {
        NSLog(@"%s: unable to init nib with name '%@'", __PRETTY_FUNCTION__,
              name);
        [self release];
        return nil;
    }

    return [self initWithContentsOfFile: path];
}

- (void) dealloc {
    [_data release];
    [_allObjects release];
    [super dealloc];
}

- unarchiver: (NSKeyedUnarchiver *) unarchiver didDecodeObject: object {
    if (object != nil)
        [_allObjects addObject: object];
    return object;
}

- (void) unarchiver: (NSKeyedUnarchiver *) unarchiver
        willReplaceObject: object
               withObject: replacement
{
    if (object != nil && replacement != nil) {
        NSUInteger index = [_allObjects indexOfObjectIdenticalTo: object];
        if (index != NSNotFound)
            [_allObjects replaceObjectAtIndex: index withObject: replacement];
    }
}

- (NSDictionary *) externalNameTable {
    return _nameTable;
}

- (BOOL) instantiateNibWithExternalNameTable: (NSDictionary *) nameTable {

    NIBDEBUG(@"instantiateNibWithExternalNameTable: %@", nameTable);

    if (getenv("CIDER_TRACE_NIB") != NULL) {
        fprintf(stderr, "CIDER_NIB instantiate bytes=%lu\n", (unsigned long) [_data length]);
        fflush(stderr);
    }

    NSIBObjectData *objectData;
    @autoreleasepool {
        _nameTable = [nameTable retain];

        NSCoder *unarchiver;
        int i, count;
        NSMenu *menu;
        NSArray *topLevelObjects;

        if ([_NSNIBArchiveUnarchiver isNIBArchiveData: _data]) {
            /* THE THIRD FORMAT. Xcode 4 and everything since writes NIBArchive, and the two
             * unarchivers above read neither of its halves. The object graph inside is the same
             * one the keyed archive carries, so only the container is different and everything
             * below this point is unchanged. */
            _NSNIBArchiveUnarchiver *nibArchive;

            unarchiver = nibArchive = [[[_NSNIBArchiveUnarchiver alloc]
                    initForReadingWithData: _data] autorelease];
            [nibArchive setDelegate: self];
            [nibArchive setClass: [NSTableCornerView class] forClassName: @"_NSCornerView"];
            [nibArchive setClass: [NSNibHelpConnector class] forClassName: @"NSIBHelpConnector"];

            objectData = [nibArchive decodeObjectForRootKey: @"IB.objectdata"];
        } else if (_flags._isKeyed) {
            NSKeyedUnarchiver *keyed;
            unarchiver = keyed = [[[NSKeyedUnarchiver alloc]
                    initForReadingWithData: _data] autorelease];
            [keyed setDelegate: self];

            /*
            TO DO:
            - utf8 in the multinational panel
            - misaligned objects in boxes everywhere
            */
            [keyed setClass: [NSTableCornerView class]
                    forClassName: @"_NSCornerView"];
            [keyed setClass: [NSNibHelpConnector class]
                    forClassName: @"NSIBHelpConnector"];

            objectData = [keyed decodeObjectForKey: @"IB.objectdata"];
        } else {
            NSUnarchiver *unkeyed;
            unarchiver = unkeyed = [[[NSUnarchiver alloc]
                    initForReadingWithData: _data] autorelease];

            [unkeyed decodeClassName: @"_NSCornerView"
                         asClassName: @"NSTableCornerView"];
            [unkeyed decodeClassName: @"NSIBHelpConnector"
                         asClassName: @"NSNibHelpConnector"];

            objectData = [unkeyed decodeObject];
        }

        /*
         * WHICH FORMAT THE FILE ACTUALLY IS, and whether anything came out of it.
         *
         * This class knows two archives: the keyed property list Interface Builder wrote until
         * Xcode 3, and the older typedstream. Xcode 4 and everything since writes a THIRD, whose
         * first eleven bytes are the ASCII text NIBArchive, and nothing here reads it. A nib that
         * fails to decode is silent: objectData comes back nil, no menu is built, no delegate is
         * connected and no window is ever made, which from the outside looks exactly like an
         * application that started and decided to do nothing. iTerm2 is that application.
         */
        if (getenv("CIDER_TRACE_NIB") != NULL) {
            const char *head = (_data != nil && [_data length] >= 11) ? [_data bytes] : "";
            char magic[12] = { 0 };

            if ([_data length] >= 11) {
                memcpy(magic, head, 11);
            }
            fprintf(stderr, "CIDER_NIB bytes=%lu keyed=%d magic=%s objectData=%s\n",
                    (unsigned long) [_data length], (int) _flags._isKeyed, magic,
                    (objectData != nil) ? "decoded" : "NIL");
            fflush(stderr);
        }

        /* THE FOUR PHASES AFTER THE DECODE, each announced. The decode is known to finish, the
         * trace says objectData=decoded, and loadNibFile still does not return for the Swift
         * Publisher document window, so the phase that holds it is one of these. */
        #define CIDER_NIB_PHASE(name)                                          \
            do {                                                               \
                if (getenv("CIDER_TRACE_NIB") != NULL) {                       \
                    fprintf(stderr, "CIDER_NIB phase %s\n", (name));           \
                    fflush(stderr);                                            \
                }                                                              \
            } while (0)

        CIDER_NIB_PHASE("buildConnections enter");
        [objectData buildConnectionsWithNameTable: _nameTable];
        CIDER_NIB_PHASE("buildConnections leave");

        if ((menu = [objectData mainMenu]) != nil) {
            // Rename the first item to have the application name.
            if ([menu numberOfItems] > 0) {
                NSMenuItem *firstItem = [menu itemAtIndex: 0];
                NSString *appName = [[NSBundle mainBundle]
                        objectForInfoDictionaryKey: (NSString *)
                                                            kCFBundleNameKey];
                [firstItem setTitle: appName];
            }
            [NSApp setMainMenu: menu];
        }

        CIDER_NIB_PHASE("mainMenu leave");

        topLevelObjects = [objectData topLevelObjects];

        // Top-level objects are always retained - this echoes observed Cocoa
        // behaviour
        [topLevelObjects makeObjectsPerformSelector: @selector(retain)];

        // if external table contains a mutable array for key
        // NSNibTopLevelObjects, then this array also retains all top-level
        // objects,
        if ([_nameTable objectForKey: NSNibTopLevelObjects]) {
            [[_nameTable objectForKey: NSNibTopLevelObjects]
                    setArray: topLevelObjects];
        }

        // We do not need to add the objects from nameTable to allObjects as
        // they get put into the uid->object table already Do we send
        // awakeFromNib to objects in the nameTable *not* present in the nib ?

        count = [_allObjects count];

        /*
         * CATCH IT WHERE IT LEAVES, then let it go on leaving.
         *
         * The frames CIDER_TRACE_EXCEPTIONS prints are captured AT THE RAISE, and most raises here
         * are caught a frame or two up, so that trace cannot say which exception escapes the nib
         * load. This one can: it only ever fires for an exception that has already walked out of
         * awakeFromNib, and it re-raises so the behaviour is unchanged.
         *
         * Swift Publisher needs it. Its document nib stops with no leave marker while the main
         * thread is back in the event loop, which is the signature of an unwind and not of a hang.
         */
        CIDER_NIB_PHASE("awakeFromNib enter");
        @try {
        for (i = 0; i < count; i++) {
            id object = [_allObjects objectAtIndex: i];

            if ([object respondsToSelector: @selector(awakeFromNib)]) {
                if (getenv("CIDER_TRACE_NIB") != NULL) {
                    /* WHICH THREAD, because a method that does not return while the application
                     * keeps pumping events is either a nested run loop on the main thread or an
                     * ordinary block on some other one, and those need different answers. */
                    fprintf(stderr, "CIDER_NIB awake %d/%d %s main=%d thread=%p\n", i, count,
                            class_getName([object class]), (int) [NSThread isMainThread],
                            (void *) pthread_self());
                    fflush(stderr);
                }
                [object awakeFromNib];
            }
        }
        } @catch (id exception) {
            if (getenv("CIDER_TRACE_NIB") != NULL) {
                fprintf(stderr, "CIDER_NIB ESCAPED at object %d/%d: %s: %s\n", i, count,
                        [[exception name] UTF8String] ?: "?",
                        [[exception reason] UTF8String] ?: "?");
                fflush(stderr);
            }
            @throw;
        }

        CIDER_NIB_PHASE("awakeFromNib leave");

        for (i = 0; i < count; i++) {
            id object = [_allObjects objectAtIndex: i];

            if ([object respondsToSelector: @selector(postAwakeFromNib)])
                [object performSelector: @selector(postAwakeFromNib)];
        }

        [[objectData visibleWindows]
                makeObjectsPerformSelector: @selector(makeKeyAndOrderFront:)
                                withObject: nil];

        [_nameTable release];
        _nameTable = nil;
    }

    return (objectData != nil);
}

- (BOOL) instantiateNibWithOwner: owner topLevelObjects: (NSArray **) objects {

    NIBDEBUG(@"instantiateNibWithOwner: %@ topLevelObjects: ", owner);

    NSMutableArray *topLevelObjects =
            (objects != NULL ? [[NSMutableArray alloc] init] : nil);
    NSDictionary *nameTable = [NSDictionary
            dictionaryWithObjectsAndKeys: owner, NSNibOwner, topLevelObjects,
                                          NSNibTopLevelObjects, nil];
    BOOL result = [self instantiateNibWithExternalNameTable: nameTable];

    if (objects != NULL) {
        if (result)
            *objects = [NSArray arrayWithArray: topLevelObjects];
        [topLevelObjects release];
    }

    return result;
}

#warning -[NSNib instantiateWithOwner:topLevelObjects:] method makes darling be a zombie process and need to restart device

/* - (BOOL) instantiateWithOwner: (id) owner topLevelObjects: (NSArray **) objects {
    return [self instantiateNibWithOwner: owner topLevelObjects: objects];
} */

@end
