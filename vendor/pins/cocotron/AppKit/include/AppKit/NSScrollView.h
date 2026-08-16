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

#import <AppKit/AppKitExport.h>
#import <AppKit/NSView.h>
#import <AppKit/NSControl.h>
#import <AppKit/NSScroller.h>
#import <Foundation/NSString.h>

@class NSClipView, NSScroller, NSColor, NSRulerView;

APPKIT_EXPORT NSString *const NSScrollViewDidEndLiveScrollNotification;
APPKIT_EXPORT NSString *const NSScrollViewWillStartLiveScrollNotification;
APPKIT_EXPORT NSString *const NSScrollViewDidLiveScrollNotification;

@interface NSScrollView : NSView {
    NSClipView *_clipView;
    NSClipView *_headerClipView;
    NSView *_cornerView;
    NSScroller *_verticalScroller;
    NSScroller *_horizontalScroller;
    NSRulerView *_horizontalRuler;
    NSRulerView *_verticalRuler;
    NSColor *_backgroundColor;
    CGFloat _verticalLineScroll;
    CGFloat _verticalPageScroll;
    CGFloat _horizontalLineScroll;
    CGFloat _horizontalPageScroll;
    int _borderType;
    BOOL _drawsBackground;
    BOOL _hasVerticalScroller;
    BOOL _hasHorizontalScroller;
    BOOL _hasHorizontalRuler;
    BOOL _hasVerticalRuler;
    BOOL _rulersVisible;
    BOOL _scrollsDynamically;
    BOOL _autohidesScrollers;
    NSCursor *_documentCursor;
    BOOL _allowsMagnification;
    CGFloat _magnification;
    CGFloat _minMagnification;
    CGFloat _maxMagnification;
    NSInteger _verticalScrollElasticity;
    NSInteger _horizontalScrollElasticity;
    BOOL _usesPredominantAxisScrolling;
}

+ (NSSize) frameSizeForContentSize: (NSSize) contentSize
             hasHorizontalScroller: (BOOL) hasHorizontalScroller
               hasVerticalScroller: (BOOL) hasVerticalScroller
                        borderType: (NSBorderType) borderType;
+ (NSSize)frameSizeForContentSize: (NSSize)cSize 
          horizontalScrollerClass: (Class)horizontalScrollerClass 
            verticalScrollerClass: (Class)verticalScrollerClass 
                       borderType: (NSBorderType)type 
                      controlSize: (NSControlSize)controlSize 
                    scrollerStyle: (NSScrollerStyle)scrollerStyle;
+ (NSSize) contentSizeForFrameSize: (NSSize) fSize
             hasHorizontalScroller: (BOOL) hasHorizontalScroller
               hasVerticalScroller: (BOOL) hasVerticalScroller
                        borderType: (NSBorderType) borderType;
+ (NSSize)contentSizeForFrameSize: (NSSize)fSize 
          horizontalScrollerClass: (Class)horizontalScrollerClass 
            verticalScrollerClass: (Class)verticalScrollerClass 
                       borderType: (NSBorderType)type 
                      controlSize: (NSControlSize)controlSize 
                    scrollerStyle: (NSScrollerStyle)scrollerStyle;

+ (void) setRulerViewClass: (Class) aClass;
+ (Class) rulerViewClass;

- (NSSize) contentSize;

- documentView;
- (NSClipView *) contentView;
- (NSRect) documentVisibleRect;

- (BOOL) drawsBackground;
- (NSColor *) backgroundColor;
- (NSBorderType) borderType;
- (NSScroller *) verticalScroller;
- (NSScroller *) horizontalScroller;
- (void) setVerticalRulerView: (NSRulerView *) ruler;
- (NSRulerView *) verticalRulerView;
- (void) setHorizontalRulerView: (NSRulerView *) ruler;
- (NSRulerView *) horizontalRulerView;
- (BOOL) hasVerticalScroller;
- (BOOL) hasHorizontalScroller;
- (BOOL) hasVerticalRuler;
- (BOOL) hasHorizontalRuler;
- (BOOL) rulersVisible;
- (CGFloat) verticalLineScroll;
- (CGFloat) horizontalLineScroll;
- (CGFloat) verticalPageScroll;
- (CGFloat) horizontalPageScroll;
- (CGFloat) lineScroll;
- (CGFloat) pageScroll;
- (BOOL) scrollsDynamically;
- (BOOL) autohidesScrollers;

- (NSCursor *) documentCursor;
- (CGFloat) magnification;
- (CGFloat) minMagnification;
- (CGFloat) maxMagnification;
- (BOOL) allowsMagnification;

- (void) setDocumentView: (NSView *) view;
- (void) setContentView: (NSClipView *) clipView;
- (void) setDrawsBackground: (BOOL) value;
- (void) setBackgroundColor: (NSColor *) color;
- (void) setBorderType: (NSBorderType) borderType;
- (void) setVerticalScroller: (NSScroller *) scroller;
- (void) setHorizontalScroller: (NSScroller *) scroller;
- (void) setHasVerticalScroller: (BOOL) flag;
- (void) setHasHorizontalScroller: (BOOL) flag;
- (void) setHasVerticalRuler: (BOOL) flag;
- (void) setHasHorizontalRuler: (BOOL) flag;
- (void) setRulersVisible: (BOOL) flag;
- (void) setVerticalLineScroll: (CGFloat) value;
- (void) setHorizontalLineScroll: (CGFloat) value;
- (void) setVerticalPageScroll: (CGFloat) value;
- (void) setHorizontalPageScroll: (CGFloat) value;
- (void) setLineScroll: (CGFloat) value;
- (void) setPageScroll: (CGFloat) value;
- (void) setScrollsDynamically: (BOOL) flag;
- (void) setDocumentCursor: (NSCursor *) cursor;
- (void) setAutohidesScrollers: (BOOL) value;
- (void) setMagnification: (CGFloat) value;
- (void) setMinMagnification: (CGFloat) value;
- (void) setMaxMagnification: (CGFloat) value;
- (void) setAllowsMagnification: (BOOL) value;

- (void) tile;
- (void) reflectScrolledClipView: (NSClipView *) clipView;

@end

/* Elasticity is the rubber band at the end of a scroll, and the predominant axis flag locks a
 * two axis gesture to one of them. This backend has neither behaviour, so the values are KEPT AND
 * NOT ACTED ON: an application that sets them is describing what it wants from a trackpad, and
 * refusing the message outright kills it (iTerm2 does exactly this on the window it opens). */
typedef NS_ENUM(NSInteger, NSScrollElasticity) {
    NSScrollElasticityAutomatic = 0,
    NSScrollElasticityNone      = 1,
    NSScrollElasticityAllowed   = 2,
};

@interface NSScrollView (CiderElasticity)
- (NSScrollElasticity) verticalScrollElasticity;
- (void) setVerticalScrollElasticity: (NSScrollElasticity) elasticity;
- (NSScrollElasticity) horizontalScrollElasticity;
- (void) setHorizontalScrollElasticity: (NSScrollElasticity) elasticity;
- (BOOL) usesPredominantAxisScrolling;
- (void) setUsesPredominantAxisScrolling: (BOOL) flag;
@end

@interface NSScrollView (CiderScrollerStyle)
- (NSScrollerStyle) scrollerStyle;
- (void) setScrollerStyle: (NSScrollerStyle) style;
@end
