/*
 * THE SYMBOLS AN APPLICATION ACTUALLY REACHES FOR, and nothing more.
 *
 * The rest of this framework explains why an empty Combine is worth having: a hard link to a
 * framework that does not exist stops dyld before the process runs an instruction, and the Swift
 * compiler emits that link wherever a Combine type is mentioned. What it asked for next was the
 * LIST of symbols a real application needs, measured rather than guessed.
 *
 * iA Writer needs exactly these, counted across all 27 binaries in the bundle with llvm-nm: 31
 * symbols, 51 references. They are a small and very ordinary slice of Combine: Publisher with map,
 * receive(on:), removeDuplicates, sink and eraseToAnyPublisher, plus AnyPublisher, AnyCancellable,
 * CurrentValueSubject, and conformances for a dispatch queue as a Scheduler and for the two
 * Foundation publishers.
 *
 * WHAT THESE DEFINITIONS ARE. Placeholders, and deliberately nothing else. Swift type metadata,
 * metadata accessors, protocol conformance descriptors and generic methods cannot be written in C:
 * they are ABI structures the Swift runtime walks and calls. Defining the names lets the LOADER
 * finish, which is the only question this file can answer on its own: how far does the application
 * get before it needs one of them for real. Anything that actually reads or calls one will fail,
 * and where it fails is the measurement.
 */

#include <stdint.h>

/*
 * A PLACEHOLDER THAT NAMES ITSELF WHEN IT IS REACHED. Zero is invisible in a crash: a null metadata
 * pointer faults at "address - 8" and every one of these looks the same. Each carries its own id in
 * the low bits of an unmappable address instead, so the faulting address says WHICH of them the
 * application asked for first. 0xC0MB1NE0000 + id, and the -8 of a value witness load keeps the id
 * legible.
 */
#define CIDER_COMBINE_POISON_BASE ((uintptr_t) 0xC0B1E0000ull)

#define CIDER_COMBINE_SYMBOL(id, mangled)                                                          \
    __attribute__((visibility("default"))) const uintptr_t cider_combine_##id __asm__(mangled) =   \
            CIDER_COMBINE_POISON_BASE + (id) * 0x100

/* 1, 2, 4, 5, 7 and 8 are gone: the three Publishers structs have real descriptors and real metadata
 * accessors in CombineMetadata.c, nested in a real Publishers enum, because Account's initialiser
 * asks the runtime to build ReceiveOn by mangled name. The CONFORMANCES below are still
 * placeholders. */
CIDER_COMBINE_SYMBOL(3, "_$s7Combine10PublishersO16RemoveDuplicatesVy_xGAA9PublisherAAMc");
CIDER_COMBINE_SYMBOL(6, "_$s7Combine10PublishersO3MapVy_xq_GAA9PublisherAAMc");
CIDER_COMBINE_SYMBOL(9, "_$s7Combine10PublishersO9ReceiveOnVy_xq_GAA9PublisherAAMc");

/* 10 and 11 are gone on purpose: AnyPublisher's metadata accessor and its nominal type descriptor
 * are REAL now, in CombineMetadata.c and CombineMetadata.s next door, because that pair is what the
 * runtime needs to build AccountCore.Account. Everything below is still a placeholder. */
CIDER_COMBINE_SYMBOL(12, "_$s7Combine12AnyPublisherVyxq_GAA0C0AAMc");
CIDER_COMBINE_SYMBOL(13, "_$s7Combine14AnyCancellableC5store2inyShyACGz_tF");
CIDER_COMBINE_SYMBOL(14, "_$s7Combine14AnyCancellableC6cancelyyF");
CIDER_COMBINE_SYMBOL(17, "_$s7Combine14AnyCancellableCSHAAMc");
CIDER_COMBINE_SYMBOL(18, "_$s7Combine14AnyCancellableCSQAAMc");
/* 19 and 22 are gone: CurrentValueSubject's initialiser and send are real, in CombineSubject.c. */
CIDER_COMBINE_SYMBOL(23, "_$s7Combine19CurrentValueSubjectCyxq_GAA9PublisherAAMc");
CIDER_COMBINE_SYMBOL(24, "_$s7Combine9PublisherPAAE010eraseToAnyB0AA0eB0Vy6OutputQz7FailureQzGyF");
CIDER_COMBINE_SYMBOL(25, "_$s7Combine9PublisherPAAE3mapyAA10PublishersO3MapVy_xqd__Gqd__6OutputQzclF");
CIDER_COMBINE_SYMBOL(26, "_$s7Combine9PublisherPAAE7receive2on7optionsAA10PublishersO9ReceiveOnVy_xqd__Gqd___16SchedulerOptionsQyd__SgtAA0I0Rd__lF");
CIDER_COMBINE_SYMBOL(27, "_$s7Combine9PublisherPAASQ6OutputRpzrlE16removeDuplicatesAA10PublishersO06RemoveE0Vy_xGyF");
CIDER_COMBINE_SYMBOL(28, "_$s7Combine9PublisherPAAs5NeverO7FailureRtzrlE4sink12receiveValueAA14AnyCancellableCy6OutputQzc_tF");
CIDER_COMBINE_SYMBOL(29, "_$sSo17OS_dispatch_queueC7Combine9Scheduler8DispatchMc");
CIDER_COMBINE_SYMBOL(30, "_$sSo20NSNotificationCenterC10FoundationE9PublisherV7CombineAdCMc");
CIDER_COMBINE_SYMBOL(31, "_$sSo8NSObjectC10FoundationE26KeyValueObservingPublisherVy_xq_G7Combine0F0ACMc");
