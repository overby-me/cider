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

#import <AppKit/AppKit.h>

@class NSColor;

APPKIT_EXPORT NSString *const NSColorListDidChangeNotification;

/* Raised by the mutating methods when the receiver is not editable, which the system lists are not.
 * An application that offers to edit a colour list catches this to tell the user why it cannot. */

@interface NSColorList : NSObject {
    NSMutableArray *_keys;
    NSMutableArray *_colors;
    NSString *_name;
    NSString *_path;
    /* Whether the mutating methods will do anything. The lists this framework builds for itself are
     * the system ones and are not; a list an application creates is, which is what AppKit documents
     * and what a colour panel relies on to know which lists it may offer to edit. */
    BOOL _isEditable;
}

+ (NSArray *) availableColorLists;

- initWithName: (NSString *) name fromFile: (NSString *) path;
- initWithName: (NSString *) name;

+ (NSColorList *) colorListNamed: (NSString *) name;

- (BOOL) isEditable;
- (NSString *) name;
- (NSArray *) allKeys;
- (NSColor *) colorWithKey: (NSString *) key;

- (void) setColor: (NSColor *) color forKey: (NSString *) key;
- (void) removeColorWithKey: (NSString *) key;
- (void) insertColor: (NSColor *) color
                 key: (NSString *) key
             atIndex: (unsigned) index;

- (void) writeToFile: (NSString *) path;
- (void) removeFile;

@end
