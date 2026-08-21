/*
 * PROTOCOL CONFORMANCES, WHICH IS WHAT THE APPLICATION ASKS FOR ONCE THE TYPES ANSWER.
 *
 * iA Writer gets through every metadata question now and then calls swift_getWitnessTable with one
 * of this framework's placeholder conformances, eight bytes of poison, and the runtime dies reading
 * the requirement count out of a protocol descriptor that is not there:
 *
 *     swift_getWitnessTable + 414
 *       movl 0x10(%rax), %eax        <- rax null, so the fault is at address sixteen
 *
 * WHY THIS IS SMALLER THAN IT LOOKS. That read is on the INSTANTIATION path, and the disassembly of
 * the entry says exactly when it is taken:
 *
 *     movl  0xc(%rdi), %ebx          conformance flags
 *     testl $0x20000, %ebx           HasGenericWitnessTable
 *     je    <fast path>              resolve the pattern at offset 8 and return it
 *
 * So a conformance that declares no generic witness table hands its table back with nothing else
 * read: not the protocol, not the type reference, not the requirement count. The application is
 * compiled against a Combine where these conformances ARE generic, but that only decides that it
 * calls swift_getWitnessTable, not what the descriptor it passes has to say.
 *
 * WHAT THE TABLES CONTAIN. A witness table is the conformance descriptor and then one word per
 * requirement, and the indices are baked into the CALLER, so the honest thing to say is that we do
 * not know the real layout of Combine.Publisher and cannot without a copy of it. Every slot is a
 * stub that names itself. If the application calls one, the trace says which index and the work is
 * then a known requirement rather than a guess; if it only passes the table to the operators, which
 * are ours and ignore it, nothing is called at all.
 *
 * These descriptors are DELIBERATELY NOT in __TEXT,__swift5_proto. That section is the index the
 * runtime builds its conformance cache from, and everything in it is parsed and validated at load.
 * Nothing needs to find these by scanning: the application references each one by symbol.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

static int cider_combine_conformance_trace(void)
{
    static int on = -1;

    if (on < 0) {
        const char *v = getenv("CIDER_TRACE_COMBINE");

        on = (v != NULL && v[0] != '\0') ? 1 : 0;
    }
    return on;
}

/*
 * A WITNESS THAT NAMES ITSELF. Returning zero is a guess as much as anything else here, but it is a
 * quiet one, and the line above it is the measurement: which slot of which protocol an application
 * actually reaches for.
 */
#define CIDER_COMBINE_WITNESS(index)                                                               \
    uintptr_t cider_combine_witness_##index(void);                                                 \
    uintptr_t cider_combine_witness_##index(void)                                                  \
    {                                                                                              \
        if (cider_combine_conformance_trace()) {                                                   \
            fprintf(stderr, "CIDER_COMBINE witness slot %d reached\n", (index));                   \
            fflush(stderr);                                                                        \
        }                                                                                          \
        return 0;                                                                                  \
    }

CIDER_COMBINE_WITNESS(0)
CIDER_COMBINE_WITNESS(1)
CIDER_COMBINE_WITNESS(2)
CIDER_COMBINE_WITNESS(3)
CIDER_COMBINE_WITNESS(4)
CIDER_COMBINE_WITNESS(5)
CIDER_COMBINE_WITNESS(6)
CIDER_COMBINE_WITNESS(7)

/*
 * ONE PROTOCOL DESCRIPTOR, for the same reason the Publishers enum exists next door: nothing on the
 * fast path reads it, and a conformance whose protocol field points at nothing is a lie that will be
 * believed exactly until something does. Four requirements is what Combine.Publisher declares in the
 * documentation: two associated types, the conformance Failure has to Error, and receive(subscriber:).
 *
 * A protocol requirement is a flags word and a relative pointer to a default implementation, and
 * none of these has one.
 */
#define CIDER_COMBINE_REQUIREMENT(kind) "	.long " #kind "\n	.long 0\n"

/*
 * AND THE CONFORMANCES. Four words each, and the flags are zero: type reference kind zero, not
 * retroactive, not synthesized, no conditional requirements, no resilient witnesses and no generic
 * witness table, which is the whole point.
 *
 * The type reference is left null on purpose. The fast path never reads it, and pointing it at the
 * nominal type descriptor would be a claim about which specialisation this table belongs to that a
 * single shared table cannot honour.
 */
#define CIDER_COMBINE_CONFORMANCE(symbol, tag)                                                     \
    "	.section __TEXT,__const\n"                                                                  \
    "	.p2align 2\n"                                                                               \
    "	.globl " symbol "\n"                                                                        \
    symbol ":\n"                                                                                   \
    "	.long _cider_combine_publisher_protocol - " symbol "\n"                                     \
    "	.long 0\n"                                                                                  \
    "	.long _cider_combine_witnesses_" tag " - (" symbol " + 8)\n"                                \
    "	.long 0\n"                                                                                  \
    "	.section __DATA,__const\n"                                                                  \
    "	.p2align 3\n"                                                                               \
    "	.private_extern _cider_combine_witnesses_" tag "\n"                                         \
    "_cider_combine_witnesses_" tag ":\n"                                                          \
    "	.quad " symbol "\n"                                                                         \
    "	.quad _cider_combine_witness_0\n"                                                           \
    "	.quad _cider_combine_witness_1\n"                                                           \
    "	.quad _cider_combine_witness_2\n"                                                           \
    "	.quad _cider_combine_witness_3\n"                                                           \
    "	.quad _cider_combine_witness_4\n"                                                           \
    "	.quad _cider_combine_witness_5\n"                                                           \
    "	.quad _cider_combine_witness_6\n"                                                           \
    "	.quad _cider_combine_witness_7\n"

__asm__(
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_name_publisher_protocol\n"
"_cider_combine_name_publisher_protocol:\n"
"	.asciz \"Publisher\"\n"
"	.private_extern _cider_combine_name_publisher_assoc\n"
"_cider_combine_name_publisher_assoc:\n"
"	.asciz \"Output Failure\"\n"
"	.private_extern _cider_combine_name_module_here\n"
"_cider_combine_name_module_here:\n"
"	.asciz \"Combine\"\n"
"\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
/* A module descriptor of this file's own, because a relative pointer is a SUBTRACTION and Mach-O
 * will only relocate one when both symbols are defined in the same object file. */
"	.private_extern _cider_combine_module_here\n"
"_cider_combine_module_here:\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_name_module_here - (_cider_combine_module_here + 8)\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_publisher_protocol\n"
"_cider_combine_publisher_protocol:\n"
"	.long 0x10043\n"
"	.long _cider_combine_module_here - (_cider_combine_publisher_protocol + 4)\n"
"	.long _cider_combine_name_publisher_protocol - (_cider_combine_publisher_protocol + 8)\n"
"	.long 0\n"
"	.long 4\n"
"	.long _cider_combine_name_publisher_assoc - (_cider_combine_publisher_protocol + 20)\n"
        CIDER_COMBINE_REQUIREMENT(8)
        CIDER_COMBINE_REQUIREMENT(7)
        CIDER_COMBINE_REQUIREMENT(7)
        CIDER_COMBINE_REQUIREMENT(1)
/*
 * AND THE FOUR REQUIREMENTS BY NAME, which is the whole reason this descriptor is real.
 *
 * libswiftFoundation carries its own conformance of NotificationCenter.Publisher to
 * Combine.Publisher, with RESILIENT WITNESSES: each witness names the requirement it implements by a
 * pointer, and the runtime turns that pointer into a table index by subtracting the protocol's
 * requirement base. Those pointers are weak imports FROM COMBINE, one exported symbol per
 * requirement, and with no Combine to bind them they are null, which is the fault at address sixteen.
 *
 * The four names below were read out of libswiftFoundation's own conformance record, so the set and
 * the count are measured rather than guessed. The ORDER is ours to choose, because the only code
 * that turns these pointers into indices uses these same symbols.
 *
 * The base is one entry BELOW the first requirement: the runtime adds that one back when it indexes,
 * which is how word zero of a witness table stays the conformance descriptor.
 */
"	.globl _$s7Combine9PublisherMp\n"
"	.set _$s7Combine9PublisherMp, _cider_combine_publisher_protocol\n"
"	.globl _$s7Combine9PublisherP7FailureAC_s5ErrorTn\n"
"	.set _$s7Combine9PublisherP7FailureAC_s5ErrorTn, _cider_combine_publisher_protocol + 24\n"
"	.globl _$s6Output7Combine9PublisherPTl\n"
"	.set _$s6Output7Combine9PublisherPTl, _cider_combine_publisher_protocol + 32\n"
"	.globl _$s7Failure7Combine9PublisherPTl\n"
"	.set _$s7Failure7Combine9PublisherPTl, _cider_combine_publisher_protocol + 40\n"
"	.globl _$s7Combine9PublisherP7receive10subscriberyqd___tAA10SubscriberRd__7FailureQyd__AGRtz5InputQyd__6OutputRtzlFTq\n"
"	.set _$s7Combine9PublisherP7receive10subscriberyqd___tAA10SubscriberRd__7FailureQyd__AGRtz5InputQyd__6OutputRtzlFTq, _cider_combine_publisher_protocol + 48\n"
        CIDER_COMBINE_CONFORMANCE("_$s7Combine19CurrentValueSubjectCyxq_GAA9PublisherAAMc", "subject")
        CIDER_COMBINE_CONFORMANCE("_$s7Combine12AnyPublisherVyxq_GAA0C0AAMc", "anypublisher")
        CIDER_COMBINE_CONFORMANCE("_$s7Combine10PublishersO3MapVy_xq_GAA9PublisherAAMc", "map")
        CIDER_COMBINE_CONFORMANCE("_$s7Combine10PublishersO9ReceiveOnVy_xq_GAA9PublisherAAMc", "receiveon")
        CIDER_COMBINE_CONFORMANCE("_$s7Combine10PublishersO16RemoveDuplicatesVy_xGAA9PublisherAAMc", "removeduplicates")
        CIDER_COMBINE_CONFORMANCE("_$sSo20NSNotificationCenterC10FoundationE9PublisherV7CombineAdCMc", "notification")
        CIDER_COMBINE_CONFORMANCE("_$sSo8NSObjectC10FoundationE26KeyValueObservingPublisherVy_xq_G7Combine0F0ACMc", "kvo")
        CIDER_COMBINE_CONFORMANCE("_$sSo17OS_dispatch_queueC7Combine9Scheduler8DispatchMc", "queue")
);

/*
 * AND THE TWO STANDARD LIBRARY CONFORMANCES, which are a different matter from Publisher.
 *
 * The application builds a Set of AnyCancellable, and building that type's metadata asks for
 * AnyCancellable: Hashable, which is why the crash did not move when every Combine conformance
 * became real. Hashable and Equatable are the STANDARD LIBRARY's protocols, so unlike Publisher
 * there is a true descriptor for each, exported by libswiftCore as $sSHMp and $sSQMp. A conformance
 * points at its protocol with a relative INDIRECTABLE pointer, so a slot holding the imported address
 * with the low bit of the offset set is how a conformance in one image names a protocol in another.
 *
 * These witnesses are real rather than stubs, because a Set that cannot compare its elements is a
 * silent corruption rather than a crash:
 *
 *   ==            identity, which is what a class conformance means
 *   hashValue     a constant, and hash(into:) leaves the hasher alone to agree with it
 *
 * A constant hash makes a Set linear. It holds a handful of cancellables that nothing ever looks up,
 * and a wrong hash with a right == is correct where a right hash with a wrong == is not.
 *
 * The base conformance slot of a Hashable table is a WITNESS TABLE, not a function: the runtime
 * loads it and calls through it. That is why the Equatable table is built first and named here.
 */
typedef struct CiderAnyCancellable CiderAnyCancellable;

__attribute__((swiftcall)) int8_t cider_combine_cancellable_equal(
        CiderAnyCancellable *const *lhs, CiderAnyCancellable *const *rhs);

__attribute__((swiftcall)) int8_t cider_combine_cancellable_equal(
        CiderAnyCancellable *const *lhs, CiderAnyCancellable *const *rhs)
{
    return (int8_t) (*lhs == *rhs);
}

__attribute__((swiftcall)) intptr_t cider_combine_cancellable_hashvalue(
        void *self __attribute__((swift_context)));

__attribute__((swiftcall)) intptr_t cider_combine_cancellable_hashvalue(
        void *self __attribute__((swift_context)))
{
    (void) self;
    return 0;
}

__attribute__((swiftcall)) void cider_combine_cancellable_hashinto(
        void *hasher, void *self __attribute__((swift_context)));

__attribute__((swiftcall)) void cider_combine_cancellable_hashinto(
        void *hasher, void *self __attribute__((swift_context)))
{
    (void) hasher;
    (void) self;
}

__attribute__((swiftcall)) intptr_t cider_combine_cancellable_rawhash(
        intptr_t seed, void *self __attribute__((swift_context)));

__attribute__((swiftcall)) intptr_t cider_combine_cancellable_rawhash(
        intptr_t seed, void *self __attribute__((swift_context)))
{
    (void) seed;
    (void) self;
    return 0;
}

/*
 * THE TWO SLOTS ARE FILLED AT LOAD RATHER THAN LINKED. This framework deliberately does not link
 * against libswiftCore: a bare link to Combine must not drag the Swift runtime into a process that
 * has no Swift in it, which is the whole reason an empty Combine is worth having. dlsym asks the same
 * question later, when the runtime is present because Swift code is what called us.
 */
extern uintptr_t cider_combine_got_hashable;
extern uintptr_t cider_combine_got_equatable;

__attribute__((constructor)) static void cider_combine_bind_protocols(void)
{
    cider_combine_got_hashable = (uintptr_t) dlsym(RTLD_DEFAULT, "$sSHMp");
    cider_combine_got_equatable = (uintptr_t) dlsym(RTLD_DEFAULT, "$sSQMp");
    if (cider_combine_conformance_trace()) {
        fprintf(stderr, "CIDER_COMBINE protocols Hashable=%p Equatable=%p\n",
                (void *) cider_combine_got_hashable, (void *) cider_combine_got_equatable);
        fflush(stderr);
    }
}

__asm__(
"	.section __DATA,__data\n"
"	.p2align 3\n"
"	.globl _cider_combine_got_hashable\n"
"_cider_combine_got_hashable:\n"
"	.quad 0\n"
"	.globl _cider_combine_got_equatable\n"
"_cider_combine_got_equatable:\n"
"	.quad 0\n"
"\n"
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.globl _$s7Combine14AnyCancellableCSQAAMc\n"
"_$s7Combine14AnyCancellableCSQAAMc:\n"
"	.long _cider_combine_got_equatable - _$s7Combine14AnyCancellableCSQAAMc + 1\n"
"	.long 0\n"
"	.long _cider_combine_witnesses_equatable - (_$s7Combine14AnyCancellableCSQAAMc + 8)\n"
"	.long 0\n"
"	.globl _$s7Combine14AnyCancellableCSHAAMc\n"
"_$s7Combine14AnyCancellableCSHAAMc:\n"
"	.long _cider_combine_got_hashable - _$s7Combine14AnyCancellableCSHAAMc + 1\n"
"	.long 0\n"
"	.long _cider_combine_witnesses_hashable - (_$s7Combine14AnyCancellableCSHAAMc + 8)\n"
"	.long 0\n"
"\n"
"	.section __DATA,__const\n"
"	.p2align 3\n"
"	.private_extern _cider_combine_witnesses_equatable\n"
"_cider_combine_witnesses_equatable:\n"
"	.quad _$s7Combine14AnyCancellableCSQAAMc\n"
"	.quad _cider_combine_cancellable_equal\n"
"	.private_extern _cider_combine_witnesses_hashable\n"
"_cider_combine_witnesses_hashable:\n"
"	.quad _$s7Combine14AnyCancellableCSHAAMc\n"
"	.quad _cider_combine_witnesses_equatable\n"
"	.quad _cider_combine_cancellable_hashvalue\n"
"	.quad _cider_combine_cancellable_hashinto\n"
"	.quad _cider_combine_cancellable_rawhash\n"
);
