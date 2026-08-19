/*
 * Does a keychain query RETURN, and with what.
 *
 * MoneyMoney reaches its own startup screen and stops there. Its
 * -[LockViewController applicationDidFinishLaunching:] runs readAutoLoginPassword,
 * readTouchIdPassword and readIWatchPassword right after the code-signature check, and the process
 * then sits with every thread asleep and one of them blocked in a Mach receive. A keychain call
 * that never comes back would look exactly like that.
 *
 * THIS PROBE NEVER TOUCHES A REAL SECRET, and that is deliberate rather than incidental: the
 * application it is diagnosing talks to banks. The query names a service that cannot exist, asks
 * for no data, and the only thing printed is the OSStatus. Nothing here enumerates the keychain and
 * nothing prints an item.
 */
#import <CoreFoundation/CoreFoundation.h>
#import <Security/SecItem.h>
#import <stdio.h>

int main(void) {
    /* Unbuffered: the interesting outcome is the one that never returns. */
    setvbuf(stdout, NULL, _IONBF, 0);

    CFMutableDictionaryRef query = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService,
                         CFSTR("cider-probe-service-that-does-not-exist"));
    CFDictionarySetValue(query, kSecAttrAccount, CFSTR("cider-probe-account"));
    /*
     * A WELL FORMED QUERY, and getting this wrong made the whole instrument lie. Without a return
     * attribute the query is invalid, the client rejects it LOCALLY with errSecParam (-50), and
     * that -50 came back in a run where secd was not even running. A -50 therefore proved nothing
     * about whether anything answered. Asking for the attributes back makes the query one that has
     * to reach the server, so the meanings separate:
     *
     *   -25300 errSecItemNotFound  the keychain answered, and there is no such item (expected)
     *   a hang                     nothing is serving
     *   -50 errSecParam            the query is malformed again, not a statement about the server
     *
     * Still no kSecReturnData: this asks for attributes of a service name that cannot exist, so it
     * cannot return a secret even if one somehow matched. The application it diagnoses talks to
     * banks.
     */
    CFDictionarySetValue(query, kSecReturnAttributes, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

    printf("CIDER_KEYCHAIN calling SecItemCopyMatching\n");

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching(query, &result);

    printf("CIDER_KEYCHAIN SecItemCopyMatching=%d result=%s\n", (int) status,
           result != NULL ? "non-null" : "null");
    if (result != NULL) {
        CFRelease(result);
    }
    CFRelease(query);
    return 0;
}
