/*
 * WKContentWorld.
 *
 * A content world is a namespace for JavaScript: the page world is the one the page itself runs in,
 * the default client world is the isolated one an application gets, and a named world is any other
 * isolated one. There is no JavaScript engine behind WKWebView here, so what this class does is
 * carry the identity: the two singletons are singletons, a named world is created once per name and
 * returned again for the same name, and the name reads back.
 *
 * It exists because the class SYMBOL is what stops a modern application at load time, before any of
 * its methods could matter: iTerm2 3.6.10 links WKContentWorld and dyld refuses to start without it.
 */

#import <WebKit/WKContentWorld.h>

@implementation WKContentWorld {
    NSString *_name;
}

+ (WKContentWorld *) pageWorld {
    static WKContentWorld *shared;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        shared = [[WKContentWorld alloc] init];
    });
    return shared;
}

+ (WKContentWorld *) defaultClientWorld {
    static WKContentWorld *shared;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        shared = [[WKContentWorld alloc] init];
    });
    return shared;
}

/* One world per name, which is what makes two lookups of the same name the same world. */
+ (WKContentWorld *) worldWithName: (NSString *) name {
    if (name == nil)
        return [self defaultClientWorld];

    static NSMutableDictionary *worlds;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        worlds = [[NSMutableDictionary alloc] init];
    });

    @synchronized (worlds) {
        WKContentWorld *world = [worlds objectForKey: name];

        if (world == nil) {
            world = [[WKContentWorld alloc] init];
            world->_name = [name copy];
            [worlds setObject: world forKey: name];
        }
        return world;
    }
}

- (NSString *) name {
    return _name;
}

- (void) dealloc {
    [_name release];
    [super dealloc];
}

@end
