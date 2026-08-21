/*
 * THE FIRST COMBINE FUNCTION WITH A BODY, rather than a name for the loader.
 *
 * Everything next door is SHAPE: descriptors, patterns, metadata. With all of it answered, iA Writer
 * finally asked for BEHAVIOUR and landed in data, because a placeholder symbol is an address in
 * __const and calling it executes a constant:
 *
 *     rip inside Combine, at _$s7Combine19CurrentValueSubjectCyACyxq_Gxcfc
 *
 * which is CurrentValueSubject.init(_:). This file implements that initialiser and send(_:).
 *
 * HOW A SWIFT METHOD IS WRITTEN IN C. clang has the calling convention: swiftcall passes arguments
 * as Swift does, and a parameter marked swift_context arrives in the context register, r13 on
 * x86_64, which is the register a method's self uses. A generic parameter is ADDRESS ONLY from the
 * callee's side, so Output is passed as a pointer and copied through its value witness table, which
 * hangs one word below its metadata. Nothing here needs the Swift compiler.
 *
 * WHERE THE VALUE LIVES. A class instance starts with a sixteen byte heap object header, and this
 * class has exactly one stored property, so the value goes straight after it. The instance size is
 * not a constant: it depends on Output, which is known when the metadata is instantiated, so the
 * builder next door asks this file for the size and writes it into the class.
 *
 * WHAT IT DOES NOT DO. There are no subscribers yet, so send(_:) updates the value and delivers it
 * nowhere. The next functions, sink and the operators, are what make delivery mean anything.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

/*
 * A value witness table: eight functions, then the layout. The order is the runtime's own and the
 * offsets were confirmed against the application, which reads size at 0x40 to size a stack buffer.
 */
struct CiderWitnesses {
    void *initializeBufferWithCopyOfBuffer;
    void *destroy;
    void *initializeWithCopy;
    void *assignWithCopy;
    void *initializeWithTake;
    void *assignWithTake;
    void *getEnumTagSinglePayload;
    void *storeEnumTagSinglePayload;
    size_t size;
    size_t stride;
    uint32_t flags;
    uint32_t extraInhabitantCount;
};

typedef void *(*CiderCopyWitness)(void *destination, void *source, const void *self);

/* The heap object header: an isa and a refcount, and the stored property follows it. */
#define CIDER_COMBINE_SUBJECT_PAYLOAD 16

static const struct CiderWitnesses *cider_combine_witnesses(const void *metadata)
{
    const uintptr_t *words = (const uintptr_t *) metadata;

    return (const struct CiderWitnesses *) words[-1];
}

/*
 * WHERE THE GENERIC ARGUMENTS SIT IN A CLASS METADATA. A non resilient class keeps its immediate
 * members at (positive size in words - number of immediate members), and the generic arguments are
 * the first of them. CurrentValueSubject's descriptor declares twelve positive words and two
 * immediate members, so Output is word ten and Failure word eleven.
 */
static const void *cider_combine_subject_output(const void *self)
{
    const uintptr_t *metadata = *(const uintptr_t *const *) self;

    return (const void *) metadata[10];
}

size_t cider_combine_subject_instance_size(const void *output)
{
    if (output == NULL) {
        return CIDER_COMBINE_SUBJECT_PAYLOAD;
    }
    return CIDER_COMBINE_SUBJECT_PAYLOAD + cider_combine_witnesses(output)->stride;
}

static int cider_combine_subject_trace(void)
{
    static int on = -1;

    if (on < 0) {
        const char *v = getenv("CIDER_TRACE_COMBINE");

        on = (v != NULL && v[0] != '\0') ? 1 : 0;
    }
    return on;
}

/*
 * init(_ value: Output). The caller has already allocated the instance, which is what the lower case
 * fc in the mangled name means, and the value is owned by us: take it rather than copy it.
 */
__attribute__((swiftcall)) void *cider_combine_subject_init(void *value,
                                                            void *self __attribute__((swift_context)))
        __asm__("_$s7Combine19CurrentValueSubjectCyACyxq_Gxcfc");

__attribute__((swiftcall)) void *cider_combine_subject_init(void *value,
                                                            void *self __attribute__((swift_context)))
{
    const void *output = cider_combine_subject_output(self);
    const struct CiderWitnesses *witnesses = cider_combine_witnesses(output);
    char *payload = (char *) self + CIDER_COMBINE_SUBJECT_PAYLOAD;

    ((CiderCopyWitness) witnesses->initializeWithTake)(payload, value, output);
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE subject init self=%p output=%p stride=%zu\n",
                self, output, witnesses->stride);
        fflush(stderr);
    }
    return self;
}

/*
 * send(_ value: Output). The parameter is borrowed, so the stored value is overwritten with a copy
 * and the caller keeps its own.
 */
__attribute__((swiftcall)) void cider_combine_subject_send(void *value,
                                                           void *self __attribute__((swift_context)))
        __asm__("_$s7Combine19CurrentValueSubjectC4sendyyxF");

__attribute__((swiftcall)) void cider_combine_subject_send(void *value,
                                                           void *self __attribute__((swift_context)))
{
    const void *output = cider_combine_subject_output(self);
    const struct CiderWitnesses *witnesses = cider_combine_witnesses(output);
    char *payload = (char *) self + CIDER_COMBINE_SUBJECT_PAYLOAD;

    ((CiderCopyWitness) witnesses->assignWithCopy)(payload, value, output);
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE subject send self=%p output=%p\n", self, output);
        fflush(stderr);
    }
}

/*
 * AND THE ONE THE APPLICATION ASKS FOR NEXT: Publisher.sink(receiveValue:).
 *
 * It is a protocol extension method, so it takes more than it looks: the escaping closure as two
 * words (a function and its context), then self, then Self's metadata and the Publisher witness
 * table, because the body of a generic extension needs both. self is the swift_context parameter and
 * the rest arrive in order.
 *
 * WHAT IT HONESTLY DOES. There is no subscription machinery here, so this delivers the CURRENT value
 * once and returns a cancellable that cancels nothing. For a CurrentValueSubject that is not a
 * fiction: a real one sends its current value to every new subscriber immediately. What is missing is
 * everything AFTER that, so a later send(_:) reaches nobody.
 *
 * It only delivers when it recognises the publisher, and it recognises it by the descriptor in the
 * metadata rather than by trusting the caller: Self can be any publisher, and reading a payload out
 * of a type whose layout we did not choose would be a fault, not a value.
 */
extern const uintptr_t cider_combine_currentvaluesubject_descriptor[];
extern void *cider_combine_anycancellable_metadata(void);

typedef void *(*CiderAllocObject)(const void *metadata, size_t size, size_t alignMask);

/* A closure is a function and a context, and the context arrives the way self does, in r13. */
typedef __attribute__((swiftcall)) void (*CiderReceiveValue)(
        const void *value, void *context __attribute__((swift_context)));

__attribute__((swiftcall)) void *cider_combine_publisher_sink(
        void *receiveValue, void *receiveValueContext, const void *selfMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
        __asm__("_$s7Combine9PublisherPAAs5NeverO7FailureRtzrlE4sink12receiveValueAA14AnyCancellableCy6OutputQzc_tF");

__attribute__((swiftcall)) void *cider_combine_publisher_sink(
        void *receiveValue, void *receiveValueContext, const void *selfMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
{
    static CiderAllocObject allocObject;
    const uintptr_t *metadata = (const uintptr_t *) selfMetadata;
    void *cancellable = NULL;

    if (allocObject == NULL) {
        allocObject = (CiderAllocObject) dlsym(RTLD_DEFAULT, "swift_allocObject");
    }
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE sink self=%p metadata=%p witnesses=%p fn=%p ctx=%p\n",
                self, selfMetadata, publisherWitnesses, receiveValue, receiveValueContext);
        fflush(stderr);
    }
    if (metadata != NULL && metadata[8] == (uintptr_t) cider_combine_currentvaluesubject_descriptor) {
        void *subject = *(void *const *) self;
        const void *output = (const void *) metadata[10];

        if (subject != NULL && output != NULL && receiveValue != NULL) {
            ((CiderReceiveValue) receiveValue)((char *) subject + CIDER_COMBINE_SUBJECT_PAYLOAD,
                                               receiveValueContext);
        }
    }
    if (allocObject != NULL) {
        cancellable = allocObject(cider_combine_anycancellable_metadata(), 16, 7);
    }
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE sink -> cancellable=%p\n", cancellable);
        fflush(stderr);
    }
    return cancellable;
}

/*
 * AND THE TWO THINGS AN APPLICATION DOES WITH A CANCELLABLE, both honestly empty.
 *
 * store(in:) puts the cancellable in a Set to keep it alive, and cancel() tears the subscription
 * down. There are no subscriptions here to tear down, and keeping it alive is what this framework
 * does by accident anyway: the class destructor is a no-op, so nothing is ever freed. Writing into
 * the Set would need Set itself and a real Hashable conformance for the class, which is another ABI
 * structure and buys nothing while cancel does nothing.
 *
 * The cost is a leak per subscription, which is the right price for an application that has not
 * opened yet.
 */
__attribute__((swiftcall)) void cider_combine_cancellable_store(
        void *set, void *self __attribute__((swift_context)))
        __asm__("_$s7Combine14AnyCancellableC5store2inyShyACGz_tF");

__attribute__((swiftcall)) void cider_combine_cancellable_store(
        void *set, void *self __attribute__((swift_context)))
{
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE cancellable store self=%p set=%p (kept by leaking)\n",
                self, set);
        fflush(stderr);
    }
}

__attribute__((swiftcall)) void cider_combine_cancellable_cancel(
        void *self __attribute__((swift_context)))
        __asm__("_$s7Combine14AnyCancellableC6cancelyyF");

__attribute__((swiftcall)) void cider_combine_cancellable_cancel(
        void *self __attribute__((swift_context)))
{
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE cancellable cancel self=%p (nothing to cancel)\n", self);
        fflush(stderr);
    }
}
