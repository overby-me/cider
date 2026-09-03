#include <HIToolbox/TextInputSources.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFData.h>
#include <os/lock.h>
#import <AppKit/NSDisplay.h>
#import <Foundation/Foundation.h>

static os_unfair_lock g_keyboardLock = OS_UNFAIR_LOCK_INIT;
static int g_lastKeyboardLayoutId = -1;
static TISInputSourceRef g_lastKeyboardLayout = NULL;

const CFStringRef kTISPropertyInputSourceLanguages = CFSTR("TISPropertyInputSourceLanguages");
const CFStringRef kTISPropertyLocalizedName = CFSTR("TISPropertyLocalizedName");

static int verbose = 0;

__attribute__((constructor))
static void initme(void) {
    verbose = getenv("STUB_VERBOSE") != NULL;
}

TISInputSourceRef TISCopyCurrentKeyboardInputSource(void)
{
	return TISCopyCurrentKeyboardLayoutInputSource();
}

TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource(void)
{
	NSDisplay* display = [NSClassFromString(@"NSDisplay") currentDisplay];
	if (!display)
		return NULL;
	const int curLayoutId = [display keyboardLayoutId];

	if (g_lastKeyboardLayoutId != -1 && g_lastKeyboardLayout != NULL)
	{
		os_unfair_lock_lock(&g_keyboardLock);
		if (curLayoutId == g_lastKeyboardLayoutId)
		{
			TISInputSourceRef rv = (TISInputSourceRef) CFRetain((CFDictionaryRef) g_lastKeyboardLayout);
			os_unfair_lock_unlock(&g_keyboardLock);
			return rv;
		}
		os_unfair_lock_unlock(&g_keyboardLock);
	}

	/* A MAC ALWAYS HAS A CURRENT KEYBOARD INPUT SOURCE, whether or not a uchr resource can be
	 * produced for it. The Wayland backend has an xkb keymap and no uchr, so returning NULL here
	 * left iTerm2 passing NULL to TISGetInputSourceProperty on the FIRST key press and the process
	 * died with nothing in the log. The source is built either way; only the layout data is
	 * omitted when there is none, which is the honest answer for that one key. */
	uint32_t length = 0;
	UCKeyboardLayout* layout = [display keyboardLayout: &length];
	CFDataRef data = NULL;

	if (layout)
	{
		data = CFDataCreate(NULL, (UInt8*) layout, length);
		free(layout);
	}

	NSString *name, *fullName;
	[display keyboardLayoutName: &name fullName:&fullName];

	NSString* sourceID = [NSString stringWithFormat: @"com.apple.keylayout.%@", name];
	const void* keys[4] = { kTISPropertyInputSourceID, kTISPropertyLocalizedName, kTISPropertyInputSourceLanguages, kTISPropertyUnicodeKeyLayoutData };
	const void* values[4] = { sourceID, fullName, @[name], data };
	CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, values, data ? 4 : 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	if (data)
		CFRelease(data);

	os_unfair_lock_lock(&g_keyboardLock);

	if (g_lastKeyboardLayout)
		CFRelease(g_lastKeyboardLayout);

	g_lastKeyboardLayout = (TISInputSourceRef) CFRetain(dict);
	g_lastKeyboardLayoutId = curLayoutId;

	os_unfair_lock_unlock(&g_keyboardLock);

	return (TISInputSourceRef) dict;
}

void* TISGetInputSourceProperty(TISInputSourceRef inputSourceRef, CFStringRef key)
{
	/* CFDictionaryGetValue faults on a NULL container, and callers pass whatever the Copy
	 * functions gave them without checking. */
	if (!inputSourceRef || !key)
		return NULL;
	return (void*) CFDictionaryGetValue((CFDictionaryRef)inputSourceRef, key);
}

TISInputSourceRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void)
{
    if (verbose) {
        puts("STUB: TISCopyCurrentASCIICapableKeyboardLayoutInputSource");
    }

    return NULL;
}
