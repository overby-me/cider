#import <CoreGraphics/CGSubWindow.h>
#import <X11/Xlib.h>

@class X11Window;

@interface X11SubWindow : CGSubWindow {
    X11Window *_parent;
    Display *_display;
    Window _window;
}

- initWithParentWindow: (X11Window *) parent frame: (CGRect) frame;

@end
