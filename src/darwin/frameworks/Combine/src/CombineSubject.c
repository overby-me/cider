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
 * WHAT SEND DOES NOW. It delivers. sink(receiveValue:) records its closure against the subject at
 * the root of the operator chain, and send(_:) calls every closure recorded against that subject.
 * Before this, iA Writer subscribed five times and sent three values into nothing, and its library
 * kept the state it had at subscribe time forever (#194).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <dispatch/dispatch.h>

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
    const struct CiderWitnesses *witnesses;

    if (output == NULL) {
        return CIDER_COMBINE_SUBJECT_PAYLOAD;
    }
    /* Same hazard as the box: the table before the metadata may not be there. */
    witnesses = cider_combine_witnesses(output);
    return CIDER_COMBINE_SUBJECT_PAYLOAD + (witnesses != NULL ? witnesses->stride : 0);
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

extern const uintptr_t cider_combine_currentvaluesubject_descriptor[];
extern void *cider_combine_anycancellable_metadata(void);

typedef void *(*CiderAllocObject)(const void *metadata, size_t size, size_t alignMask);

/* A closure is a function and a context, and the context arrives the way self does, in r13. */
typedef __attribute__((swiftcall)) void (*CiderReceiveValue)(
        const void *value, void *context __attribute__((swift_context)));

/*
 * EVERY OPERATOR RETURNS ONE OF THESE, and the chain is what a subscription has to walk back.
 *
 * map, receive(on:), removeDuplicates and eraseToAnyPublisher each return a different Combine type,
 * and in this framework every one of those types is EIGHT BYTES holding a pointer to a box we own.
 * A box keeps a COPY of its upstream, taken through the upstream's own value witness table, because
 * the operator's self is borrowed and the chain outlives the call.
 */
#define CIDER_COMBINE_BOX_MAGIC ((uintptr_t) 0xC0B1E0B0C0B1E0B0ull)

struct CiderCombineBox {
    uintptr_t magic;
    const void *upstreamMetadata;
    void *upstream;
    int transforms;
    const char *what;
    /*
     * RESOLVED WHEN THE BOX IS MADE, never by walking metadata afterwards. An operator is handed
     * Self's metadata by Swift and it is live for that call; the same pointer read back at
     * subscribe time was NOT. Following one faulted on the metadata's own first word, with CR2
     * equal to it exactly, so the chain is collapsed here instead and a box only ever copies the
     * answer its upstream already has.
     */
    void *rootSubject;
    int onMain;
};

/*
 * THE SUBSCRIBER LIST, which is what makes send(_:) mean anything.
 *
 * A subject is a heap object whose size this framework chose, so there is no room in it for a list
 * and no ivar to add one to. The list lives here instead, keyed by the subject pointer, and it is
 * never large: iA Writer subscribes five times in a whole run.
 *
 * The lock is not held while a closure runs. A subscriber may subscribe or cancel from inside its
 * own callback, and calling application code under our lock is a deadlock waiting for a schedule.
 */
struct CiderCombineSubscriber {
    void *subject;
    void *receiveValue;
    void *context;
    void *cancellable;
    int onMain;
    struct CiderCombineSubscriber *next;
};

static struct CiderCombineSubscriber *cider_combine_subscribers;
static pthread_mutex_t cider_combine_lock = PTHREAD_MUTEX_INITIALIZER;

/*
 * ASK THE KIND BEFORE READING WORD EIGHT. Word 0 of a class metadata is its isa, a pointer, while a
 * struct is 0x200 and an enum 0x201, and those are a few words long: the descriptor lives at word 8
 * of a CLASS only. Reading it off an erased publisher's struct metadata faulted at exactly
 * metadata plus 0x40, which the fault registers in ciderd.log named outright.
 */
static int cider_combine_metadata_is_subject(const uintptr_t *metadata)
{
    if (metadata == NULL || metadata[0] < 0x1000) {
        return 0;
    }
    return metadata[8] == (uintptr_t) cider_combine_currentvaluesubject_descriptor;
}

/*
 * WHICH SUBJECT IS AT THE ROOT OF A CHAIN, and whether anything in it asked for another queue.
 *
 * self points AT the value, because a generic parameter is address only from the callee's side, so
 * one load gives the value: either a subject instance or a box. Only the metadata the caller has
 * just been handed is read; a box already knows its own root and is asked rather than followed.
 */
static void *cider_combine_root_subject(const void *selfMetadata, const void *selfValue, int *onMain)
{
    const uintptr_t *metadata = (const uintptr_t *) selfMetadata;
    void *value = (selfValue != NULL) ? *(void *const *) selfValue : NULL;
    struct CiderCombineBox *box;

    if (cider_combine_metadata_is_subject(metadata)) {
        return value;
    }
    if (value == NULL) {
        return NULL;
    }
    box = (struct CiderCombineBox *) value;
    if (box->magic != CIDER_COMBINE_BOX_MAGIC) {
        return NULL;
    }
    if (onMain != NULL && box->onMain) {
        *onMain = 1;
    }
    return box->rootSubject;
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
 * and the caller keeps its own, and then every subscriber recorded against this subject is called.
 *
 * A SUBSCRIBER ON ANOTHER QUEUE READS THE PAYLOAD AGAIN rather than being handed a copy of this
 * value. receive(on:) means the closure runs later, and copying an address only value to keep until
 * then needs the witness table and a free nobody would ever do. Reading the payload at delivery
 * time coalesces two sends that arrive before the queue drains, which is what an interface wants
 * anyway and is what a scheduler with a mailbox of one would do.
 */
static void cider_combine_deliver(void *subject)
{
    struct CiderCombineSubscriber *entry;
    struct CiderCombineSubscriber *matched = NULL;
    struct CiderCombineSubscriber *walk;

    /* Snapshot under the lock; call the closures outside it. */
    pthread_mutex_lock(&cider_combine_lock);
    for (entry = cider_combine_subscribers; entry != NULL; entry = entry->next) {
        if (entry->subject == subject && entry->receiveValue != NULL) {
            struct CiderCombineSubscriber *copy = malloc(sizeof *copy);

            if (copy == NULL) {
                break;
            }
            *copy = *entry;
            copy->next = matched;
            matched = copy;
        }
    }
    pthread_mutex_unlock(&cider_combine_lock);

    walk = matched;
    while (walk != NULL) {
        struct CiderCombineSubscriber *next = walk->next;
        CiderReceiveValue fn = (CiderReceiveValue) walk->receiveValue;
        void *context = walk->context;

        if (walk->onMain) {
            dispatch_async(dispatch_get_main_queue(), ^{
                fn((char *) subject + CIDER_COMBINE_SUBJECT_PAYLOAD, context);
            });
        } else {
            fn((char *) subject + CIDER_COMBINE_SUBJECT_PAYLOAD, context);
        }
        free(walk);
        walk = next;
    }
}

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
    cider_combine_deliver(self);
}

/*
 * AND THE ONE THE APPLICATION ASKS FOR NEXT: Publisher.sink(receiveValue:).
 *
 * It is a protocol extension method, so it takes more than it looks: the escaping closure as two
 * words (a function and its context), then self, then Self's metadata and the Publisher witness
 * table, because the body of a generic extension needs both. self is the swift_context parameter and
 * the rest arrive in order.
 *
 * It delivers the current value at once, which a real CurrentValueSubject also does, and then
 * RECORDS the closure so send(_:) can reach it. The closure context is retained and never released:
 * this framework leaks a subscription deliberately, and a dangling context would be a fault a long
 * way from here.
 *
 * It only subscribes when it recognises the publisher, and it recognises it by the descriptor in
 * the metadata rather than by trusting the caller: Self can be any publisher, and reading a payload
 * out of a type whose layout we did not choose would be a fault, not a value.
 */

__attribute__((swiftcall)) void *cider_combine_publisher_sink(
        void *receiveValue, void *receiveValueContext, const void *selfMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
        __asm__("_$s7Combine9PublisherPAAs5NeverO7FailureRtzrlE4sink12receiveValueAA14AnyCancellableCy6OutputQzc_tF");

__attribute__((swiftcall)) void *cider_combine_publisher_sink(
        void *receiveValue, void *receiveValueContext, const void *selfMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
{
    static CiderAllocObject allocObject;
    void *cancellable = NULL;
    void *subject;
    int onMain = 0;

    if (allocObject == NULL) {
        allocObject = (CiderAllocObject) dlsym(RTLD_DEFAULT, "swift_allocObject");
    }
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE sink self=%p metadata=%p witnesses=%p fn=%p ctx=%p\n",
                self, selfMetadata, publisherWitnesses, receiveValue, receiveValueContext);
        fflush(stderr);
    }
    subject = cider_combine_root_subject(selfMetadata, self, &onMain);
    if (subject != NULL && receiveValue != NULL) {
        ((CiderReceiveValue) receiveValue)((char *) subject + CIDER_COMBINE_SUBJECT_PAYLOAD,
                                           receiveValueContext);
    }
    if (allocObject != NULL) {
        static void (*retain)(void *);

        cancellable = allocObject(cider_combine_anycancellable_metadata(), 16, 7);
        /*
         * ONE EXTRA RETAIN, SO IT IS NEVER DESTROYED.
         *
         * The word at metadata minus eight is the DESTROY function for a heap object, not the value
         * witness table a value type keeps there. Our class metadata is built on an objc class
         * object, and there is nothing of ours in front of it to put a destructor in, so that word
         * reads as zero. swift_release calls it the moment the refcount reaches zero, and iA Writer
         * did exactly that one line after store(in:): SEGV at address 0.
         *
         * The caller owns the +1 it is handed and releases it in the ordinary way; this second
         * reference is the one that keeps the count off zero. It leaks the object, which this
         * framework already does deliberately for the subscription itself.
         */
        if (retain == NULL) {
            retain = (void (*)(void *)) dlsym(RTLD_DEFAULT, "swift_retain");
        }
        if (retain != NULL && cancellable != NULL) {
            retain(cancellable);
        }
    }
    if (subject != NULL && receiveValue != NULL) {
        struct CiderCombineSubscriber *entry = calloc(1, sizeof *entry);
        static void (*retain)(void *);

        if (retain == NULL) {
            retain = (void (*)(void *)) dlsym(RTLD_DEFAULT, "swift_retain");
        }
        if (entry != NULL) {
            /* The closure outlives this call, so its context must too. */
            if (retain != NULL && receiveValueContext != NULL) {
                retain(receiveValueContext);
            }
            entry->subject = subject;
            entry->receiveValue = receiveValue;
            entry->context = receiveValueContext;
            entry->cancellable = cancellable;
            entry->onMain = onMain;
            pthread_mutex_lock(&cider_combine_lock);
            entry->next = cider_combine_subscribers;
            cider_combine_subscribers = entry;
            pthread_mutex_unlock(&cider_combine_lock);
        }
    }
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE sink -> cancellable=%p subject=%p onMain=%d\n",
                cancellable, subject, onMain);
        fflush(stderr);
    }
    return cancellable;
}

/*
 * AND THE TWO THINGS AN APPLICATION DOES WITH A CANCELLABLE.
 *
 * store(in:) puts the cancellable in a Set to keep it alive, and it is still empty: keeping it
 * alive is what this framework does anyway, because the class destructor is a no-op and nothing is
 * ever freed. Writing into the Set would need Set itself and a real Hashable conformance for the
 * class, which is another ABI structure and buys nothing.
 *
 * cancel() is REAL now, because a subscription list that never shrinks would keep calling a closure
 * whose owner has gone. It removes every subscriber recorded against this cancellable.
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
    struct CiderCombineSubscriber **link;
    int removed = 0;

    pthread_mutex_lock(&cider_combine_lock);
    link = &cider_combine_subscribers;
    while (*link != NULL) {
        struct CiderCombineSubscriber *entry = *link;

        if (entry->cancellable == self) {
            *link = entry->next;
            free(entry);
            removed++;
            continue;
        }
        link = &entry->next;
    }
    pthread_mutex_unlock(&cider_combine_lock);
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE cancellable cancel self=%p removed=%d\n", self, removed);
        fflush(stderr);
    }
}

/*
 * THE FOUR OPERATORS, AND THE ONE WORD THEY ALL RETURN.
 *
 * That is the same lie the value witness table next door tells, kept consistent: nothing outside
 * this framework ever looks inside one of these values, because no real Combine code exists here to
 * look. The box itself and what a subscription does with it are described where it is declared.
 *
 * The result is passed as a hidden first argument. A generic return type has no size at the call
 * site, so Swift returns it indirectly, and clang spells that swift_indirect_result. The metadata
 * and witness tables the caller appends after the explicit parameters are what make the copy
 * possible: Self's metadata is how the box learns the upstream's stride.
 */
static void *cider_combine_box(const char *what, const void *selfMetadata, const void *selfValue,
                               int transforms)
{
    struct CiderCombineBox *box = calloc(1, sizeof *box);
    const struct CiderWitnesses *witnesses;
    size_t stride;

    if (box == NULL || selfMetadata == NULL) {
        return box;
    }
    /*
     * A METADATA NEED NOT CARRY A VALUE WITNESS TABLE HERE. The table sits in the word BEFORE the
     * metadata, and every metadata this framework builds by hand has one, but iA Writer hands in
     * one that does not: the load faulted at cider_combine_box+92 and killed the process. Without a
     * table there is no way to copy the upstream, so the box keeps its own empty storage. The chain
     * still exists and still delivers; what is lost is the copy of a value nothing here reads.
     */
    witnesses = cider_combine_witnesses(selfMetadata);
    stride = (witnesses != NULL && witnesses->stride != 0) ? witnesses->stride : 8;
    box->magic = CIDER_COMBINE_BOX_MAGIC;
    box->upstreamMetadata = selfMetadata;
    box->upstream = calloc(1, stride);
    box->transforms = transforms;
    box->what = what;
    box->onMain = (strcmp(what, "receiveOn") == 0);
    /* Resolve now, while Swift's metadata for Self is still the live one it just handed us. */
    box->rootSubject = cider_combine_root_subject(selfMetadata, selfValue, &box->onMain);
    if (witnesses != NULL && box->upstream != NULL && selfValue != NULL) {
        ((CiderCopyWitness) witnesses->initializeWithCopy)(box->upstream, (void *) selfValue,
                                                           selfMetadata);
    }
    if (cider_combine_subject_trace()) {
        fprintf(stderr, "CIDER_COMBINE %s box=%p upstream=%p meta=%p stride=%zu witnesses=%p "
                        "root=%p onMain=%d\n",
                what, (void *) box, box->upstream, selfMetadata, stride, (const void *) witnesses,
                box->rootSubject, box->onMain);
        fflush(stderr);
    }
    return box;
}

__attribute__((swiftcall)) void cider_combine_publisher_receive_on(
        void **result __attribute__((swift_indirect_result)), const void *scheduler,
        const void *options, const void *selfMetadata, const void *schedulerMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
        __asm__("_$s7Combine9PublisherPAAE7receive2on7optionsAA10PublishersO9ReceiveOnVy_xqd__Gqd___16SchedulerOptionsQyd__SgtAA0I0Rd__lF");

__attribute__((swiftcall)) void cider_combine_publisher_receive_on(
        void **result __attribute__((swift_indirect_result)), const void *scheduler,
        const void *options, const void *selfMetadata, const void *schedulerMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
{
    (void) scheduler;
    (void) options;
    (void) schedulerMetadata;
    (void) publisherWitnesses;
    *result = cider_combine_box("receiveOn", selfMetadata, self, 0);
}

__attribute__((swiftcall)) void cider_combine_publisher_map(
        void **result __attribute__((swift_indirect_result)), void *transform, void *context,
        const void *selfMetadata, const void *outputMetadata, const void *publisherWitnesses,
        void *self __attribute__((swift_context)))
        __asm__("_$s7Combine9PublisherPAAE3mapyAA10PublishersO3MapVy_xqd__Gqd__6OutputQzclF");

__attribute__((swiftcall)) void cider_combine_publisher_map(
        void **result __attribute__((swift_indirect_result)), void *transform, void *context,
        const void *selfMetadata, const void *outputMetadata, const void *publisherWitnesses,
        void *self __attribute__((swift_context)))
{
    (void) transform;
    (void) context;
    (void) outputMetadata;
    (void) publisherWitnesses;
    *result = cider_combine_box("map", selfMetadata, self, 1);
}

__attribute__((swiftcall)) void cider_combine_publisher_remove_duplicates(
        void **result __attribute__((swift_indirect_result)), const void *selfMetadata,
        const void *publisherWitnesses, const void *equatableWitnesses,
        void *self __attribute__((swift_context)))
        __asm__("_$s7Combine9PublisherPAASQ6OutputRpzrlE16removeDuplicatesAA10PublishersO06RemoveE0Vy_xGyF");

__attribute__((swiftcall)) void cider_combine_publisher_remove_duplicates(
        void **result __attribute__((swift_indirect_result)), const void *selfMetadata,
        const void *publisherWitnesses, const void *equatableWitnesses,
        void *self __attribute__((swift_context)))
{
    (void) publisherWitnesses;
    (void) equatableWitnesses;
    *result = cider_combine_box("removeDuplicates", selfMetadata, self, 0);
}

__attribute__((swiftcall)) void cider_combine_publisher_erase(
        void **result __attribute__((swift_indirect_result)), const void *selfMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
        __asm__("_$s7Combine9PublisherPAAE010eraseToAnyB0AA0eB0Vy6OutputQz7FailureQzGyF");

__attribute__((swiftcall)) void cider_combine_publisher_erase(
        void **result __attribute__((swift_indirect_result)), const void *selfMetadata,
        const void *publisherWitnesses, void *self __attribute__((swift_context)))
{
    (void) publisherWitnesses;
    *result = cider_combine_box("erase", selfMetadata, self, 0);
}
