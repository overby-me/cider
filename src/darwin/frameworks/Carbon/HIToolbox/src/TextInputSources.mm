#include <HIToolbox/TextInputSources.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFData.h>
#include <CoreFoundation/CFArray.h>
#include <os/lock.h>
#include <stdlib.h>
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
	/* WHAT EVERY CONSUMER ASKS BEFORE IT USES A SOURCE. A source carrying only a name and layout
	 * data answers NULL for its category and type, and callers compare that answer without
	 * checking: iTerm2 built its Preferences, asked this source for its type, and took
	 * CFStringCompare into a NULL dereference. Answering is cheap and there is exactly one honest
	 * answer here, a keyboard layout that is selected, enabled and from the system.
	 * See docs/iterm2-preferences-gap.md. */
	const void* keys[8] = { kTISPropertyInputSourceID, kTISPropertyLocalizedName,
	                        kTISPropertyInputSourceCategory, kTISPropertyInputSourceType,
	                        kTISPropertyInputSourceIsASCIICapable, kTISPropertyInputSourceIsFromSystem,
	                        kTISPropertyInputSourceLanguages, kTISPropertyUnicodeKeyLayoutData };
	const void* values[8] = { sourceID, fullName,
	                          kTISCategoryKeyboardInputSource, kTISTypeKeyboardLayout,
	                          kCFBooleanTrue, kCFBooleanTrue,
	                          @[name], data };
	CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, values, data ? 8 : 7, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	if (data)
		CFRelease(data);

	/* DO NOT CACHE A SOURCE WITH NO LAYOUT DATA. The display has no keymap until the compositor
	 * sends one, which is after the first application asks, and a cached layout-less source is then
	 * the answer for the life of the process however honest the layout id becomes. Task #239. */
	if (data)
	{
		os_unfair_lock_lock(&g_keyboardLock);

		if (g_lastKeyboardLayout)
			CFRelease(g_lastKeyboardLayout);

		g_lastKeyboardLayout = (TISInputSourceRef) CFRetain(dict);
		g_lastKeyboardLayoutId = curLayoutId;

		os_unfair_lock_unlock(&g_keyboardLock);
	}

	return (TISInputSourceRef) dict;
}

/* THE LIST A MAC ALWAYS HAS AT LEAST ONE ENTRY IN.
 *
 * This was the ONLY TIS entry point with no implementation, so it fell through to the placeholder
 * in libswiftCompatSymbols.c, which is a const uintptr_t holding a poison value. iTerm2 calls it as
 * a FUNCTION while building its Preferences, so control landed on the DATA symbol and the process
 * executed the poison as instructions: SIGSEGV with RIP exactly at libswiftCompat+0xf10. See
 * docs/iterm2-preferences-gap.md.
 *
 * There is one input source here, the current keyboard layout, so the list is that or nothing.
 * AN EMPTY ARRAY, NEVER NULL, because callers iterate the result and the whole family of defects
 * around this file is a caller handed NULL by a Copy function it did not check.
 */
CFArrayRef TISCreateInputSourceList(CFDictionaryRef properties, Boolean includeAllInstalled)
{
	(void) includeAllInstalled;

	TISInputSourceRef current = TISCopyCurrentKeyboardLayoutInputSource();

	if (!current)
		return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);

	/* properties is a FILTER: every pair in it must match the source, and a source missing the key
	 * does not match. A NULL or empty filter asks for everything. */
	bool matches = true;

	if (properties && CFDictionaryGetCount(properties) > 0)
	{
		CFIndex n = CFDictionaryGetCount(properties);
		const void** keys = (const void**) calloc(n, sizeof(void*));
		const void** wanted = (const void**) calloc(n, sizeof(void*));

		if (keys && wanted)
		{
			CFDictionaryGetKeysAndValues(properties, keys, wanted);
			for (CFIndex i = 0; i < n; i++)
			{
				const void* have = CFDictionaryGetValue((CFDictionaryRef) current, keys[i]);

				if (!have || !CFEqual(have, wanted[i]))
				{
					matches = false;
					break;
				}
			}
		}
		free(keys);
		free(wanted);
	}

	CFArrayRef list;

	if (matches)
	{
		const void* values[1] = { current };

		list = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
	}
	else
	{
		list = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
	}

	CFRelease(current);
	return list;
}

void* TISGetInputSourceProperty(TISInputSourceRef inputSourceRef, CFStringRef key)
{
	/* CFDictionaryGetValue faults on a NULL container, and callers pass whatever the Copy
	 * functions gave them without checking. */
	if (!inputSourceRef || !key)
		return NULL;
	return (void*) CFDictionaryGetValue((CFDictionaryRef)inputSourceRef, key);
}

/* NULL is the ANSWER, not an absence: it means the current input method overrides no keyboard
 * layout, which is true here since there are no input methods at all. Qt checks for it and falls
 * back to the current layout source. The symbol MISSING was fatal in a different way: it bound
 * lazily and aborted at the first key press CMake.app ever received. Task #227. */
TISInputSourceRef TISCopyInputMethodKeyboardLayoutOverride(void)
{
	return NULL;
}

TISInputSourceRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void)
{
    if (verbose) {
        puts("STUB: TISCopyCurrentASCIICapableKeyboardLayoutInputSource");
    }

    return NULL;
}
