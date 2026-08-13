// Does CFPreferencesCopyAppValue return something safe to use?
//
// LibreOffice crashes reading the system locale. The resolved guest stack is
// configmgr -> LocaleBackend::getPropertyValue -> ImplGetLocale ->
// CFLocaleCreateCanonicalLocaleIdentifierFromString -> CFStringGetCString -> objc_msgSend ->
// lookUpImpOrForward, and the disassembly of ImplGetLocale shows the string it passes came from
// a CFPreferences lookup with kCFPreferencesCurrentApplication.
//
// THAT IS A CLAIM ABOUT TWO FUNCTIONS, not about LibreOffice, so it is worth testing without
// LibreOffice: an 800 MB application that takes a container and a compositor to start is a poor
// instrument for a question this small.
//
// CFStringGetCString DISPATCHES TO OBJC when the object is not a native CF string, which is why
// a crash inside objc_msgSend is the interesting outcome rather than a confusing one: it means
// the value came back as something CF does not recognise as its own.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <stdio.h>

static void report(const char *what, CFTypeRef value)
{
	if (value == NULL) {
		printf("PREFS_PROBE %s=NULL\n", what);
		fflush(stdout);
		return;
	}
	printf("PREFS_PROBE %s=%p\n", what, value);
	fflush(stdout);

	// The type id FIRST, because asking a non-CF pointer for its type is the cheapest question
	// that can still tell the two failure modes apart.
	CFTypeID id = CFGetTypeID(value);
	printf("PREFS_PROBE %s typeid=%lu string_typeid=%lu match=%s\n", what,
		(unsigned long) id, (unsigned long) CFStringGetTypeID(),
		id == CFStringGetTypeID() ? "yes" : "NO");
	fflush(stdout);

	if (id == CFStringGetTypeID()) {
		char buf[256];
		Boolean ok = CFStringGetCString((CFStringRef) value, buf, sizeof(buf),
			kCFStringEncodingUTF8);
		printf("PREFS_PROBE %s cstring=%s value=%s\n", what, ok ? "ok" : "FAILED",
			ok ? buf : "-");
		fflush(stdout);
	}
}

int main(int argc, const char **argv)
{
	printf("PREFS_PROBE start\n");
	fflush(stdout);

	// The exact call ImplGetLocale makes.
	CFTypeRef locale = CFPreferencesCopyAppValue(CFSTR("AppleLocale"),
		kCFPreferencesCurrentApplication);
	report("AppleLocale", locale);

	// THE ACTUAL SEQUENCE, read out of ImplGetLocale's disassembly: a preference lookup, a
	// check that it is an array, element zero, and then canonicalise THAT. The AppleLocale
	// lookup above is not the one that crashes; this is.
	CFTypeRef languages = CFPreferencesCopyAppValue(CFSTR("AppleLanguages"),
		kCFPreferencesCurrentApplication);
	printf("PREFS_PROBE AppleLanguages=%p\n", (void *) languages);
	fflush(stdout);
	if (languages != NULL) {
		CFTypeID id = CFGetTypeID(languages);
		printf("PREFS_PROBE AppleLanguages typeid=%lu array_typeid=%lu match=%s\n",
			(unsigned long) id, (unsigned long) CFArrayGetTypeID(),
			id == CFArrayGetTypeID() ? "yes" : "NO");
		fflush(stdout);
		if (id == CFArrayGetTypeID()) {
			CFIndex n = CFArrayGetCount((CFArrayRef) languages);
			printf("PREFS_PROBE AppleLanguages count=%ld\n", (long) n);
			fflush(stdout);
			if (n > 0) {
				CFTypeRef first = CFArrayGetValueAtIndex((CFArrayRef) languages, 0);
				printf("PREFS_PROBE AppleLanguages[0]=%p\n", (void *) first);
				fflush(stdout);
				report("AppleLanguages[0]", first);
				// The exact crashing call, on the exact value.
				CFStringRef c = CFLocaleCreateCanonicalLocaleIdentifierFromString(
					kCFAllocatorDefault, (CFStringRef) first);
				report("canonical-from-preference", c);
			}
		}
	}

	// A key nothing could have set, so a non-NULL answer here would say the lookup itself is
	// broken rather than the stored value.
	CFTypeRef bogus = CFPreferencesCopyAppValue(CFSTR("CiderKeyThatCannotExist"),
		kCFPreferencesCurrentApplication);
	report("CiderKeyThatCannotExist", bogus);

	// And the function that actually crashed, driven from a string this file made, so a crash
	// here would move the blame off CFPreferences entirely.
	CFStringRef made = CFStringCreateWithCString(kCFAllocatorDefault, "en_US",
		kCFStringEncodingUTF8);
	printf("PREFS_PROBE made=%p\n", (void *) made);
	fflush(stdout);
	CFStringRef canonical = CFLocaleCreateCanonicalLocaleIdentifierFromString(kCFAllocatorDefault,
		made);
	report("canonical-from-literal", canonical);

	// THE BRIDGING QUESTION, which is what the crash actually turned on. LibreOffice does
	// CFGetTypeID(value) == CFArrayGetTypeID() and passes the value straight through when they
	// differ. If a Foundation NSArray does not report CFArrayGetTypeID, that check fails on a
	// perfectly good array and the array is handed to a function expecting a string.
	@autoreleasepool {
		NSArray *ns = [NSArray arrayWithObject: @"en"];
		CFTypeID nsid = CFGetTypeID((CFTypeRef) ns);
		printf("PREFS_PROBE bridged-array class=%s typeid=%lu array_typeid=%lu match=%s\n",
			class_getName([ns class]), (unsigned long) nsid,
			(unsigned long) CFArrayGetTypeID(),
			nsid == CFArrayGetTypeID() ? "yes" : "NO");
		fflush(stdout);

		// __NSCFArray is the class the crash named, and it is NOT the class a plain NSArray
		// literal produces. It is what a NATIVE CFArray looks like from the ObjC side, so make
		// one that way and ask the same question LibreOffice asks.
		CFStringRef one = CFSTR("en");
		CFArrayRef cfarr = CFArrayCreate(kCFAllocatorDefault, (const void **) &one, 1,
			&kCFTypeArrayCallBacks);
		printf("PREFS_PROBE native-cfarray class=%s typeid=%lu array_typeid=%lu match=%s\n",
			class_getName([(id) cfarr class]), (unsigned long) CFGetTypeID(cfarr),
			(unsigned long) CFArrayGetTypeID(),
			CFGetTypeID(cfarr) == CFArrayGetTypeID() ? "yes" : "NO");
		fflush(stdout);

		NSString *nsstr = [NSString stringWithUTF8String: "en_US"];
		CFTypeID sid = CFGetTypeID((CFTypeRef) nsstr);
		printf("PREFS_PROBE bridged-string class=%s typeid=%lu string_typeid=%lu match=%s\n",
			class_getName([nsstr class]), (unsigned long) sid,
			(unsigned long) CFStringGetTypeID(),
			sid == CFStringGetTypeID() ? "yes" : "NO");
		fflush(stdout);
	}

	printf("PREFS_PROBE_OK\n");
	fflush(stdout);
	return 0;
}
