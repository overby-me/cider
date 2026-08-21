/*
 * swift_metadata_probe.m: can this runtime build metadata for a type by NAME.
 *
 * iA Writer dies with a value-witness load from a NULL metadata pointer while building
 * AccountCore.AccountEnvironment, a struct whose fields are two Swift.String, one of the app's own
 * types, and three Foundation.URL. Everything that could be missing has been ruled out by
 * measurement: the descriptors are present, the GOT slots that reference them are bound at the
 * moment of the fault, and the Combine placeholders are not involved. What has NOT been asked is the
 * simplest question of all, so this asks it: hand the runtime a mangled name and see what comes back.
 *
 * The answers separate three worlds. If the Swift stdlib types resolve and the Foundation ones do
 * not, the wall is Foundation's type registration in this runtime. If nothing resolves, the entry
 * point or the image registration is broken for everything. If they all resolve, the null is
 * specific to what the application asks for and none of these three explanations is it.
 *
 * Built with buck2 like every other guest binary here (there is no guest C compiler): see
 * tests/foundation/BUCK. Run inside a container from a directory launchd does not clear:
 *   cider shell /private/var/tmp/swift_metadata_probe
 *
 * Exit code 0 always: this is a measurement, not a pass or fail. It prints what it found.
 */

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <stdio.h>

/*
 * The runtime takes the mangled name WITHOUT the "$s" symbol prefix, its length, a context to
 * resolve generic parameters against (none here) and the generic arguments (none here).
 */
typedef const void *(*GetTypeByMangledNameInContext)(const char *name, size_t length,
                                                    const void *context,
                                                    const void *const *genericArgs);

static void ask(GetTypeByMangledNameInContext fn, const char *what, const char *mangled)
{
    /* ANNOUNCED BEFORE IT IS ASKED. A question that kills the process leaves no line of its own, and
     * then the output stops with no clue which one it was. */
    printf("%-28s %-22s asking...\n", what, mangled);

    const void *metadata = fn(mangled, strlen(mangled), NULL, NULL);

    /* The value witness table sits 8 bytes BEFORE the metadata, which is the load that faults in the
     * application, so print it too: metadata without a witness table would fault the same way. */
    const void *witness = NULL;

    if (metadata != NULL) {
        witness = *(((const void *const *) metadata) - 1);
    }
    printf("%-28s %-22s metadata=%p witness=%p\n", what, mangled, metadata, witness);
}

int main(void)
{
    @autoreleasepool {
        /* UNBUFFERED, because a probe that dies takes its buffered output with it: stdout to a pipe
         * is block buffered, and a crash in the last question then erases the answers to all the
         * earlier ones. That looked exactly like a probe that printed nothing at all. */
        setvbuf(stdout, NULL, _IONBF, 0);
        /* NOTHING PULLS SWIFT INTO AN OBJC PROCESS, so the first attempt asked a runtime that was
         * not there: RTLD_NOLOAD answered NULL and dlsym then failed on RTLD_DEFAULT. Load both
         * libraries here, in the order the runtime expects, and say what each attempt gave. */
        void *core = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY | RTLD_GLOBAL);

        printf("libswiftCore handle:       %p  %s\n", core, core ? "" : dlerror());

        void *fnd = dlopen("/usr/lib/swift/libswiftFoundation.dylib", RTLD_LAZY | RTLD_GLOBAL);

        printf("libswiftFoundation handle: %p  %s\n", fnd, fnd ? "" : dlerror());

        GetTypeByMangledNameInContext fn =
                (GetTypeByMangledNameInContext) dlsym(core != NULL ? core : RTLD_DEFAULT,
                                                      "swift_getTypeByMangledNameInContext");

        if (fn == NULL) {
            printf("swift_getTypeByMangledNameInContext NOT FOUND: %s\n", dlerror());
            return 0;
        }
        printf("swift_getTypeByMangledNameInContext at %p\n\n", (void *) fn);

        /* The stdlib first, because if these fail nothing else means anything. */
        ask(fn, "Swift.Int", "Si");
        ask(fn, "Swift.String", "SS");
        ask(fn, "Swift.Bool", "Sb");
        ask(fn, "[Swift.String]", "SaySSG");

        /* Then the three Foundation types the application's struct is made of. */
        ask(fn, "Foundation.URL", "10Foundation3URLV");
        ask(fn, "Foundation.Data", "10Foundation4DataV");
        ask(fn, "Foundation.Date", "10Foundation4DateV");
        ask(fn, "Foundation.URLRequest", "10Foundation10URLRequestV");

        /* And an ObjC-backed one, which travels a different path inside the runtime. */
        ask(fn, "Foundation.NSString", "So8NSStringC");

        /*
         * THE ONES THIS PORT ONLY PRETENDS TO HAVE. src/darwin/frameworks/Combine/src/CombineSymbols.c
         * defines these names as data with no content behind them, so the loader finishes and the
         * first real use fails. iA Writer reaches one through AccountCore.Account, whose
         * statePublisher property is typed Combine.AnyPublisher<AccountState, Never>.
         */
        ask(fn, "Combine.AnyCancellable", "7Combine14AnyCancellableC");
        ask(fn, "Combine.AnyPublisher", "7Combine12AnyPublisherV");
        ask(fn, "Combine.CurrentValueSubject", "7Combine19CurrentValueSubjectC");

        /*
         * AND THE SAME AFTER LOADING OUR OWN COMBINE, which is where the hand built descriptor for
         * AnyPublisher lives. The runtime finds a type by scanning the __swift5_types records of
         * LOADED images, so a descriptor in a framework nobody opened is a descriptor nobody finds.
         *
         * A generic type is asked for BOUND: AnyPublisher on its own has no metadata, only
         * AnyPublisher<Int, Never> does, and that is what an application's field type mangles to.
         */
        void *combine = dlopen("/System/Library/Frameworks/Combine.framework/Combine",
                               RTLD_LAZY | RTLD_GLOBAL);

        printf("\nCombine handle:            %p  %s\n", combine, combine ? "" : dlerror());
        ask(fn, "AnyPublisher<Int,Never>", "7Combine12AnyPublisherVySis5NeverOG");
        ask(fn, "AnyPublisher<String,Never>", "7Combine12AnyPublisherVySSs5NeverOG");

        /*
         * AND THE TYPE THE APPLICATION ACTUALLY DIES ON, asked directly rather than through a
         * three minute GUI run. AccountCore.Account is a class whose statePublisher property is an
         * AnyPublisher, so building its metadata is what needs Combine. If this answers, the wall
         * that has held iA Writer since the beginning is down; if it does not, the trace from our
         * own accessor says whether the runtime even asked us.
         */
        const char *accountcore = "/Applications/iA Writer.app/Contents/Frameworks/"
                                  "AccountCore.framework/AccountCore";
        void *account = dlopen(accountcore, RTLD_LAZY | RTLD_GLOBAL);

        printf("\nAccountCore handle:        %p  %s\n", account, account ? "" : dlerror());
        if (account != NULL) {
            ask(fn, "AccountCore.Account", "11AccountCore0A0C");
            ask(fn, "AccountCore.AccountState", "11AccountCore0A5StateO");
            ask(fn, "AccountCore.AccountEnvironment", "11AccountCore0A11EnvironmentV");
        }
    }
    return 0;
}
