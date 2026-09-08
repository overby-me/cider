/*
 * READ A VALUE THAT LIVES IN AN IVAR OF THE APPLICATION UNDER TEST.
 *
 * Every instrument in this port watches OUR code, so a question is answerable only when the
 * application happens to route it through a framework of ours. -[IALibraryViewOptions
 * visibleExcerpt] is "movsbl 0x8(%rdi), %eax": an ivar read with no message send in it, and #194
 * stopped there with "nothing on our side can see it".
 *
 * This is inserted with DYLD_INSERT_LIBRARIES and swizzles NAMED ZERO ARGUMENT METHODS to log what
 * they return. That covers accessors, which is what a question of this shape almost always is.
 *
 *   CIDER_SPY=Class.selector,Class.selector
 *
 * ZERO ARGUMENT ONLY, and deliberately. Forwarding an arbitrary signature safely means unpacking
 * every argument by type encoding, and a probe that can crash the thing it is measuring is worse
 * than no probe. A selector with a colon in it is refused out loud rather than half handled.
 *
 * THE CLASS IS NOT LOADED WHEN WE ARE. An inserted library initialises before the application's own
 * frameworks are guaranteed to be in, so objc_getClass fails at that point for anything but the
 * system. A background thread polls for each class instead, and SAYS SO WHEN IT GIVES UP, because a
 * probe whose silence means "never installed" and whose silence also means "never called" cannot
 * answer anything.
 */

/* NOT Foundation.h: the umbrella reaches NSURLCredential.h, which imports Security, which is not on
 * this target's header path. Only NSObject and NSString are needed. */
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#define CIDER_SPY_MAX 16

struct CiderSpyEntry {
	char cls[128];
	char sel[128];
	SEL selector;
	IMP original;
	char ret;
	int installed;
};

static struct CiderSpyEntry cider_spy_entries[CIDER_SPY_MAX];
static int cider_spy_count;

/*
 * CIDER_SPY_DUMP=Class1,Class2 LISTS WHAT A CLASS ANSWERS TO.
 *
 * The class you want is often in a binary with NO ObjC symbols at all: iA Writer defines
 * IAEditorViewController in a stripped Swift main executable, so llvm-nm finds nothing and there is
 * no way to learn the selector names from the file. The RUNTIME still knows them, and this is the
 * only place with a runtime inside that process.
 *
 * Zero argument methods are marked, because those are the ones CIDER_SPY can then watch.
 */
static char cider_spy_dump_names[CIDER_SPY_MAX][128];
static int cider_spy_dump_done[CIDER_SPY_MAX];
static int cider_spy_dump_count;

static int cider_spy_dump_class(int i)
{
	Class cls = objc_getClass(cider_spy_dump_names[i]);
	unsigned int count = 0;
	Method *methods;

	if (cls == Nil) {
		return 0;
	}
	methods = class_copyMethodList(cls, &count);
	fprintf(stderr, "CIDER_SPY_DUMP %s has %u instance methods\n", cider_spy_dump_names[i], count);
	for (unsigned int m = 0; m < count; m++) {
		const char *name = sel_getName(method_getName(methods[m]));
		const char *types = method_getTypeEncoding(methods[m]);

		fprintf(stderr, "CIDER_SPY_DUMP   %s %-52s %s\n",
		        strchr(name, ':') == NULL ? "watchable" : "         ", name, types ?: "?");
	}
	free(methods);
	fflush(stderr);
	cider_spy_dump_done[i] = 1;
	return 1;
}

/* THE RECEIVER IS HALF THE ANSWER. Three IAEditorViewControllers answering three different
 * documents are indistinguishable without it, and correlating which controller holds which document
 * is the whole question in #194. */
static void cider_spy_say(struct CiderSpyEntry *e, id self, const char *text)
{
	fprintf(stderr, "CIDER_SPY %p %s.%s -> %s\n", self, e->cls, e->sel, text);
	fflush(stderr);
}

/* Keyed on the SELECTOR ALONE. Two watched classes that share a selector name would collide, which
 * is a real limitation and not worth a class walk in a probe: name the pair you want. */
static struct CiderSpyEntry *cider_spy_find(SEL sel)
{
	for (int i = 0; i < cider_spy_count; i++) {
		if (cider_spy_entries[i].selector == sel) {
			return &cider_spy_entries[i];
		}
	}
	return NULL;
}

static long long cider_spy_int(id self, SEL _cmd)
{
	struct CiderSpyEntry *e = cider_spy_find(_cmd);
	long long v = ((long long (*)(id, SEL)) e->original)(self, _cmd);
	char text[64];

	snprintf(text, sizeof(text), "%lld", v);
	cider_spy_say(e, self, text);
	return v;
}

static id cider_spy_object(id self, SEL _cmd)
{
	struct CiderSpyEntry *e = cider_spy_find(_cmd);
	id v = ((id (*)(id, SEL)) e->original)(self, _cmd);
	char text[256];

	snprintf(text, sizeof(text), "%s %s", v ? object_getClassName(v) : "(nil)",
	         v ? [[v description] UTF8String] : "");
	cider_spy_say(e, self, text);
	return v;
}

/* VOID IS THE COMMON CASE FOR A LIFECYCLE CALLBACK, and leaving it out made the probe refuse
 * exactly the methods most worth watching: viewWillDisappear, viewDidAppear and the animated
 * transition pair are all v16@0:8. It said so rather than guessing, which is the design working,
 * but the answer is to forward it. */
static void cider_spy_void(id self, SEL _cmd)
{
	struct CiderSpyEntry *e = cider_spy_find(_cmd);

	cider_spy_say(e, self, "(void)");
	((void (*)(id, SEL)) e->original)(self, _cmd);
}

static double cider_spy_double(id self, SEL _cmd)
{
	struct CiderSpyEntry *e = cider_spy_find(_cmd);
	double v = ((double (*)(id, SEL)) e->original)(self, _cmd);
	char text[64];

	snprintf(text, sizeof(text), "%f", v);
	cider_spy_say(e, self, text);
	return v;
}

static int cider_spy_install(struct CiderSpyEntry *e)
{
	Class cls = objc_getClass(e->cls);
	if (cls == Nil) {
		return 0;
	}

	SEL sel = sel_registerName(e->sel);
	Method m = class_getInstanceMethod(cls, sel);
	if (m == NULL) {
		fprintf(stderr, "CIDER_SPY %s has no instance method %s\n", e->cls, e->sel);
		fflush(stderr);
		return 1;
	}

	const char *types = method_getTypeEncoding(m);
	e->ret = types ? types[0] : '?';
	e->selector = sel;
	e->original = method_getImplementation(m);

	IMP replacement;
	switch (e->ret) {
	case 'c': case 'C': case 'B': case 's': case 'S':
	case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
		replacement = (IMP) cider_spy_int;
		break;
	case '@': case '#':
		replacement = (IMP) cider_spy_object;
		break;
	case 'd': case 'f':
		replacement = (IMP) cider_spy_double;
		break;
	case 'v':
		replacement = (IMP) cider_spy_void;
		break;
	default:
		fprintf(stderr, "CIDER_SPY %s.%s returns %c, which this does not forward\n",
		        e->cls, e->sel, e->ret);
		fflush(stderr);
		return 1;
	}

	method_setImplementation(m, replacement);
	e->installed = 1;
	fprintf(stderr, "CIDER_SPY armed on %s.%s returning %c\n", e->cls, e->sel, e->ret);
	fflush(stderr);
	return 1;
}

static void *cider_spy_thread(void *unused)
{
	(void) unused;

	/* Ten seconds is longer than any application here takes to load its own frameworks and short
	 * enough that a missing class is reported inside one drive. */
	for (int tick = 0; tick < 200; tick++) {
		int pending = 0;

		for (int i = 0; i < cider_spy_count; i++) {
			if (!cider_spy_entries[i].installed && !cider_spy_install(&cider_spy_entries[i])) {
				pending = 1;
			}
		}
		for (int i = 0; i < cider_spy_dump_count; i++) {
			if (!cider_spy_dump_done[i] && !cider_spy_dump_class(i)) {
				pending = 1;
			}
		}
		if (!pending) {
			return NULL;
		}
		usleep(50 * 1000);
	}

	for (int i = 0; i < cider_spy_count; i++) {
		if (!cider_spy_entries[i].installed) {
			fprintf(stderr, "CIDER_SPY GAVE UP: class %s never appeared\n",
			        cider_spy_entries[i].cls);
		}
	}
	for (int i = 0; i < cider_spy_dump_count; i++) {
		if (!cider_spy_dump_done[i]) {
			fprintf(stderr, "CIDER_SPY GAVE UP: class %s never appeared to dump\n",
			        cider_spy_dump_names[i]);
		}
	}
	fflush(stderr);
	return NULL;
}

__attribute__((constructor))
static void cider_spy_start(void)
{
	const char *dumpspec = getenv("CIDER_SPY_DUMP");

	for (const char *p = dumpspec ?: ""; *p != '\0' && cider_spy_dump_count < CIDER_SPY_MAX; ) {
		const char *comma = strchr(p, ',');
		size_t len = comma ? (size_t) (comma - p) : strlen(p);

		if (len >= sizeof(cider_spy_dump_names[0])) {
			len = sizeof(cider_spy_dump_names[0]) - 1;
		}
		memcpy(cider_spy_dump_names[cider_spy_dump_count++], p, len);
		if (comma == NULL) break;
		p = comma + 1;
	}

	const char *spec = getenv("CIDER_SPY");
	if ((spec == NULL || *spec == '\0') && cider_spy_dump_count == 0) {
		return;
	}
	if (spec == NULL) {
		spec = "";
	}

	for (const char *p = spec; *p != '\0' && cider_spy_count < CIDER_SPY_MAX; ) {
		const char *comma = strchr(p, ',');
		size_t len = comma ? (size_t) (comma - p) : strlen(p);
		const char *dot = memchr(p, '.', len);

		if (dot == NULL) {
			fprintf(stderr, "CIDER_SPY ignoring %.*s, expected Class.selector\n", (int) len, p);
		} else if (memchr(p, ':', len) != NULL) {
			fprintf(stderr, "CIDER_SPY refusing %.*s: zero argument selectors only\n",
			        (int) len, p);
		} else {
			struct CiderSpyEntry *e = &cider_spy_entries[cider_spy_count++];
			size_t clslen = (size_t) (dot - p);
			size_t sellen = len - clslen - 1;

			if (clslen >= sizeof(e->cls)) clslen = sizeof(e->cls) - 1;
			if (sellen >= sizeof(e->sel)) sellen = sizeof(e->sel) - 1;
			memcpy(e->cls, p, clslen);
			memcpy(e->sel, dot + 1, sellen);
		}
		if (comma == NULL) break;
		p = comma + 1;
	}

	if (cider_spy_count == 0 && cider_spy_dump_count == 0) {
		return;
	}

	pthread_t t;
	if (pthread_create(&t, NULL, cider_spy_thread, NULL) == 0) {
		pthread_detach(t);
	}
}
