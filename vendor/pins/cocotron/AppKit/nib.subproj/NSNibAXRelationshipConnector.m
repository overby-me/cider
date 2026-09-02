#import <objc/runtime.h>
#import "NSNibAXRelationshipConnector.h"

@implementation NSNibAXRelationshipConnector

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    /* The arity comes from the selector's colons and the return is an object: "v@:" claimed every
     * method took none and returned nothing, so a caller passing arguments wrote through slots the
     * invocation did not have, and one using the result read the leftover return register. */
    const char *name = sel_getName(aSelector);
    char types[256];
    size_t n = 0;

    types[n++] = '@';
    types[n++] = '@';
    types[n++] = ':';
    for (const char *p = name; *p != '\0' && n < sizeof(types) - 1; p++) {
        if (*p == ':')
            types[n++] = '@';
    }
    types[n] = '\0';
    return [NSMethodSignature signatureWithObjCTypes: types];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    id nothing = nil;
    [anInvocation setReturnValue: &nothing];
    NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end

@implementation NSNibAXAttributeConnector

- (void) encodeWithCoder: (NSCoder *) aCoder {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
}

- (id) initWithCoder: (NSCoder *) coder {
    printf("STUB %s\n", __PRETTY_FUNCTION__);
    return self;
}

@end
