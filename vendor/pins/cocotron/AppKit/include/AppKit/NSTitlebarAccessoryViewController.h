#import <AppKit/NSViewController.h>
#import <Foundation/Foundation.h>

/* Where the accessory sits, as macOS names it. */
typedef NS_ENUM(NSInteger, NSLayoutAttribute_TitlebarCompat) {
    NSTitlebarAccessoryLayoutAttributeLeading = 5,
    NSTitlebarAccessoryLayoutAttributeTrailing = 6,
    NSTitlebarAccessoryLayoutAttributeBottom = 4,
};

@interface NSTitlebarAccessoryViewController : NSViewController {
    NSInteger _layoutAttribute;
    CGFloat _fullScreenMinHeight;
    BOOL _hidden;
}

/* REAL PROPERTIES, NOT THE CATCH ALL. The class answered every selector through a stub whose
 * signature said the method returns void, so an application that READ one of these got whatever was
 * in the return register. These three are the ones a caller sets on the way in. */
@property NSInteger layoutAttribute;
@property CGFloat fullScreenMinHeight;
@property (getter=isHidden) BOOL hidden;

@end
