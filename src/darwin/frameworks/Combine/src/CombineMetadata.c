/*
 * REAL SWIFT TYPE METADATA FOR ONE COMBINE TYPE, hand built.
 *
 * WHY THIS EXISTS. iA Writer stops at the very first thing it does with its own model: the metadata
 * accessor for AccountCore.Account. Account has a property typed Combine.AnyPublisher, so building
 * its metadata needs AnyPublisher's, the runtime cannot find a descriptor for it, answers NULL, and
 * the caller loads the value witness table from metadata minus eight. That is the fault at
 * 0xfffffffffffffff8.
 *
 * I WROTE IN THE PLAN THAT THIS CANNOT BE WRITTEN IN C, AND THAT WAS TOO STRONG. Swift metadata is
 * ABI structure, not language magic: relative pointers, a generic pattern, a value witness table and
 * a record in __swift5_types. The parts C cannot express are the RELATIVE POINTERS, because the
 * difference of two addresses is not a constant expression; those live in the module level asm at the
 * end of this file, where an assembler writes them as naturally as the Swift compiler does.
 *
 * WHAT IT IS AND IS NOT. AnyPublisher really is one class reference wide, so a fixed layout of eight
 * bytes with pointer alignment is the right shape, and that is all metadata construction needs: the
 * size and alignment of the field. The witnesses here are TRIVIAL, which is deliberately not what
 * the real type does. Copying an AnyPublisher will not retain its box and destroying one will not
 * release it, so this leaks rather than crashes, and anything that actually SUBSCRIBES still has
 * nothing to call. The measurement this makes possible is how much further the application gets.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

/* The two-word answer a Swift metadata accessor returns: the metadata and how complete it is. */
typedef struct {
    const void *metadata;
    size_t state;
} CiderMetadataResponse;

/*
 * THE TWO RUNTIME ENTRY POINTS, LOOKED UP RATHER THAN LINKED.
 *
 * libswiftCore exports both, and the compiler calls exactly these from the code it emits for a
 * generic type. Linking this framework against libswiftCore would make every client of Combine drag
 * in the Swift runtime whether it uses Swift or not, and this framework exists precisely so that a
 * bare link to Combine does not stop dyld. Nothing here runs before the Swift runtime is loaded: the
 * only callers are the runtime itself and Swift code that has already resolved its metadata
 * accessor.
 */
typedef CiderMetadataResponse (*CiderGetGenericMetadata)(size_t, const void *const *, const void *);
typedef void *(*CiderAllocateGenericValueMetadata)(const void *, const void *const *, const void *,
                                                  size_t);

static CiderGetGenericMetadata cider_get_generic_metadata(void)
{
    static CiderGetGenericMetadata fn;

    if (fn == NULL) {
        fn = (CiderGetGenericMetadata) dlsym(RTLD_DEFAULT, "swift_getGenericMetadata");
    }
    return fn;
}

static CiderAllocateGenericValueMetadata cider_allocate_generic_value_metadata(void)
{
    static CiderAllocateGenericValueMetadata fn;

    if (fn == NULL) {
        fn = (CiderAllocateGenericValueMetadata) dlsym(RTLD_DEFAULT,
                                                       "swift_allocateGenericValueMetadata");
    }
    return fn;
}

/* Defined in the module level asm at the end of this file. */
extern const uint32_t cider_combine_anypublisher_descriptor[];
extern const uint32_t cider_combine_receiveon_descriptor[];
extern const uint32_t cider_combine_map_descriptor[];
extern const uint32_t cider_combine_removeduplicates_descriptor[];

/*
 * THE INSTANTIATION FUNCTION the generic pattern names. The runtime hands it the descriptor, the
 * generic arguments and the pattern, and it has to produce metadata. There is nothing to compute
 * here beyond what the allocator already does, because the layout does not depend on the arguments:
 * an AnyPublisher is one reference wide whatever it publishes.
 */
/* CIDER_TRACE_COMBINE: the two calls the runtime makes into this file, and what they answer. A
 * process that dies inside metadata construction says nothing on its own. */
static int cider_combine_trace(void)
{
    static int on = -1;

    if (on < 0) {
        const char *v = getenv("CIDER_TRACE_COMBINE");

        on = (v != NULL && v[0] != '\0') ? 1 : 0;
    }
    return on;
}

/* A LINE AT LOAD TIME, so an absent trace can be told from an absent framework. Two runs were spent
 * on that question already: the accessor printing nothing means either the runtime never asked or
 * the switch never arrived, and those are opposite bugs. */
__attribute__((constructor)) static void cider_combine_loaded(void)
{
    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE loaded, AnyPublisher descriptor at %p\n",
                (const void *) cider_combine_anypublisher_descriptor);
        fflush(stderr);
    }
}

void *cider_combine_anypublisher_instantiate(const void *descriptor, const void *const *arguments,
                                             const void *pattern)
{
    CiderAllocateGenericValueMetadata allocate = cider_allocate_generic_value_metadata();
    void *metadata = NULL;

    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE instantiate desc=%p args=%p pattern=%p allocate=%p\n",
                descriptor, (const void *) arguments, pattern, (void *) allocate);
        fflush(stderr);
    }
    if (allocate != NULL) {
        metadata = allocate(descriptor, arguments, pattern, 0);
    }
    if (metadata != NULL) {
        /*
         * AND THE HEADER THE ALLOCATOR DOES NOT WRITE. A generic pattern normally carries an EXTRA
         * DATA PATTERN, which is the prefix the runtime memcpys over the fresh metadata: the kind
         * word and the pointer back to the descriptor. This pattern has none, so those two words
         * are whatever the allocator left, and a kind of zero reads as a CLASS, after which the
         * runtime walks a class it does not have. Two stores are cheaper than an extra data
         * pattern and say the same thing.
         *
         * 0x200 is MetadataKind::Struct. The layout from the address point is: kind, descriptor,
         * then one word per generic argument, and the value witness table sits at minus eight.
         */
        uintptr_t *words = (uintptr_t *) metadata;

        words[0] = 0x200;
        words[1] = (uintptr_t) descriptor;
    }
    if (cider_combine_trace()) {
        const uintptr_t *w = (const uintptr_t *) metadata;

        fprintf(stderr, "CIDER_COMBINE instantiate -> %p  vwt=%p kind=0x%lx desc=%p args=%p,%p\n",
                metadata,
                metadata ? (void *) w[-1] : NULL,
                metadata ? (unsigned long) w[0] : 0ul,
                metadata ? (void *) w[1] : NULL,
                metadata ? (void *) w[2] : NULL,
                metadata ? (void *) w[3] : NULL);
        fflush(stderr);
    }
    return metadata;
}

/*
 * THE METADATA ACCESSOR, which is the symbol the application binds to: $s7Combine12AnyPublisherVMa.
 * Two generic arguments, and the runtime does the caching.
 */
CiderMetadataResponse cider_combine_anypublisher_metadata_accessor(size_t request, const void *output,
                                                                   const void *failure)
{
    const void *arguments[2] = { output, failure };

    CiderGetGenericMetadata get = cider_get_generic_metadata();
    CiderMetadataResponse none = { NULL, 0 };
    CiderMetadataResponse answer;

    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE accessor request=%zu output=%p failure=%p get=%p\n",
                request, output, failure, (void *) get);
        fflush(stderr);
    }
    if (get == NULL) {
        return none;
    }
    answer = get(request, arguments, cider_combine_anypublisher_descriptor);
    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE accessor -> metadata=%p state=%zu\n",
                answer.metadata, answer.state);
        fflush(stderr);
    }
    return answer;
}

/*
 * THE THREE OPERATOR STRUCTS, which is where the application went next.
 *
 * With AnyPublisher answering, AccountCore got as far as Account's initialiser and died there on
 * another null: at AccountCore+0x1ecc, immediately after
 *
 *     callq ___swift_instantiateConcreteTypeFromMangledNameV2
 *     movq  -0x8(%rax), %rcx          <- rax is zero, so this reads address minus eight
 *
 * and the mangled name it passes resolves, through two symbolic references in __swift5_typeref, to
 * Publishers.ReceiveOn<NotificationCenter.Publisher, DispatchQueue>. Map and RemoveDuplicates are
 * bound by the same binaries and are the same shape, so all three are here.
 *
 * THEY ARE NESTED IN AN ENUM AND THE NESTING IS NOT DECORATION. Publishers is a caseless enum used as
 * a namespace, and a bound generic type mangles ONE ARGUMENT LIST PER LEVEL of its context: the
 * conformance names read Vy_xq_G, an empty list for Publishers and then the type's own arguments. The
 * runtime counts the parameters level by level down the parent chain, so a descriptor whose parent is
 * the module rather than the enum has the wrong shape for the name being resolved. Hence the enum
 * descriptor below, with no cases and no generic parameters of its own.
 *
 * The requirements are DELIBERATELY not declared. Real Combine constrains Upstream to Publisher and
 * Context to Scheduler, and each such constraint adds a witness table to the key arguments. Declaring
 * none means the runtime builds these from types alone, which is all the metadata needs and all this
 * framework can honour: there are no conformances here to hand it.
 */
static CiderMetadataResponse cider_combine_generic_metadata(const void *descriptor, size_t request,
                                                            const void *const *arguments,
                                                            const char *name)
{
    CiderGetGenericMetadata get = cider_get_generic_metadata();
    CiderMetadataResponse none = { NULL, 0 };
    CiderMetadataResponse answer;

    if (get == NULL) {
        return none;
    }
    answer = get(request, arguments, descriptor);
    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE %s accessor request=%zu -> metadata=%p state=%zu\n",
                name, request, answer.metadata, answer.state);
        fflush(stderr);
    }
    return answer;
}

/*
 * The application calls these with the real Combine argument count, which is larger than ours: a
 * witness table per constraint follows the types. Reading only the leading types is safe, and the
 * trailing arguments are simply not part of the key.
 */
CiderMetadataResponse cider_combine_receiveon_metadata_accessor(size_t request, const void *upstream,
                                                                const void *context)
{
    const void *arguments[2] = { upstream, context };

    return cider_combine_generic_metadata(cider_combine_receiveon_descriptor, request, arguments,
                                          "ReceiveOn");
}

CiderMetadataResponse cider_combine_map_metadata_accessor(size_t request, const void *upstream,
                                                          const void *output)
{
    const void *arguments[2] = { upstream, output };

    return cider_combine_generic_metadata(cider_combine_map_descriptor, request, arguments, "Map");
}

CiderMetadataResponse cider_combine_removeduplicates_metadata_accessor(size_t request,
                                                                       const void *upstream)
{
    const void *arguments[1] = { upstream };

    return cider_combine_generic_metadata(cider_combine_removeduplicates_descriptor, request,
                                          arguments, "RemoveDuplicates");
}


/*
 * AND ONE CLASS, BUILT AT RUNTIME RATHER THAN EMITTED.
 *
 * Account stores a Set of AnyCancellable and two CurrentValueSubjects, so a struct is not enough:
 * the next types the application needs are CLASSES. A class metadata record on Darwin is an
 * Objective-C class object with the Swift fields laid out after it, and emitting one statically
 * means emitting a metaclass and an Objective-C class_ro_t beside it. Building it in the accessor
 * costs one malloc and no object file surgery, and the shape came from a real one:
 * AccountCore.Account, read with scratchpad/swiftclassmeta.py.
 *
 *     -24  zero            (the address point is 24 bytes in: classAddressPoint)
 *     -16  destroy         the heap object destructor
 *      -8  value witness table
 *      +0  isa             the metaclass
 *      +8  superclass      zero for a Swift root class
 *     +16  objc cache, two words
 *     +32  objc data, with the low bit set to say Swift
 *     +40  flags, instance address point
 *     +48  instance size, alignment mask, reserved
 *     +56  class size, class address point
 *     +64  nominal type descriptor
 *     +72  ivar destroyer
 *
 * The witnesses are the runtime's own for a native reference, $sBoWV, so copying and destroying a
 * reference to one of these behaves exactly as Swift expects even though the class itself is empty.
 */
extern const uintptr_t cider_combine_anycancellable_descriptor[];

static void cider_combine_class_destroy(void *object)
{
    (void) object;
}

/*
 * WHERE A GENERIC CLASS KEEPS ITS ARGUMENTS. The runtime reads them back out of the metadata to
 * confirm that the answer matches the question, and it computes the offset from the descriptor:
 * the immediate members start at (positive size in words - number of immediate members), and the
 * generic arguments are the first of them. So a class declaring twelve positive words and two
 * immediate members keeps them at words ten and eleven, and the block has to be big enough to hold
 * them. That is what CurrentValueSubject's descriptor says next door.
 */
static void *cider_combine_build_class(const void *descriptor, size_t instanceSize,
                                       const void *arg0, const void *arg1)
{
    static const size_t addressPoint = 24;
    static const size_t positiveSize = 96;
    char *block = calloc(1, addressPoint + positiveSize);
    uintptr_t *words;
    const void *nativeWitnesses = dlsym(RTLD_DEFAULT, "$sBoWV");

    if (block == NULL) {
        return NULL;
    }
    words = (uintptr_t *) (block + addressPoint);
    words[-2] = (uintptr_t) cider_combine_class_destroy;
    words[-1] = (uintptr_t) nativeWitnesses;
    /* The isa has to be a class, and this class is never handed to Objective-C, so it points at
     * itself: a metaclass of last resort that keeps every "is this a class" test true. */
    words[0] = (uintptr_t) words;
    words[1] = 0;
    words[4] = 2;                       /* objc data: the low bit says this is a Swift class */
    words[5] = 2;                       /* flags */
    ((uint32_t *) &words[6])[0] = (uint32_t) instanceSize;
    ((uint16_t *) &words[6])[2] = 7;    /* alignment mask, eight byte alignment */
    ((uint32_t *) &words[7])[0] = (uint32_t) (addressPoint + positiveSize);
    ((uint32_t *) &words[7])[1] = (uint32_t) addressPoint;
    words[8] = (uintptr_t) descriptor;
    if (arg0 != NULL || arg1 != NULL) {
        words[10] = (uintptr_t) arg0;
        words[11] = (uintptr_t) arg1;
    }
    return words;
}

CiderMetadataResponse cider_combine_anycancellable_metadata_accessor(size_t request)
{
    static void *metadata;
    CiderMetadataResponse answer;

    if (metadata == NULL) {
        metadata = cider_combine_build_class(cider_combine_anycancellable_descriptor, 16, NULL, NULL);
    }
    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE anycancellable accessor request=%zu -> %p\n", request, metadata);
        fflush(stderr);
    }
    answer.metadata = metadata;
    answer.state = 0;
    return answer;
}


/* CombineSubject.c allocates one of these to hand back from sink, and swift_allocObject wants the
 * metadata rather than the accessor's two word answer. */
void *cider_combine_anycancellable_metadata(void)
{
    return (void *) cider_combine_anycancellable_metadata_accessor(0).metadata;
}

/*
 * AND A GENERIC CLASS, WHICH HAS TO GO THROUGH THE RUNTIME EVEN THOUGH THE METADATA IS OURS.
 *
 * CurrentValueSubject is where Account actually keeps its state, twice over, and it is a generic
 * class. The first attempt built one class metadata per specialisation in this accessor and returned
 * it directly, which is what an access function is allowed to do for a NON generic type. It died, and
 * this is where:
 *
 *     swift_checkMetadataState + 892
 *       callq  resolveExistingEntry<GenericCacheEntry>
 *       movb   0x9(%rax), %al          <- rax is null, so this faults at address nine
 *
 * The runtime asks the type's own GENERIC CACHE for the entry belonging to these arguments and reads
 * the entry's state byte without checking. Metadata that the runtime did not create has no entry, so
 * ANY later question about its state is a null dereference. The answer to "what does the runtime read
 * back after the access function returns", which the previous attempt left as the open question.
 *
 * So the metadata is still ours, and the runtime still makes the entry: the descriptor now carries a
 * generic pattern whose instantiation function is the builder below, and the accessor asks
 * swift_getGenericMetadata exactly as the struct accessors do. The runtime creates the cache entry,
 * calls us to fill it, and every state check afterwards finds what it looks for. It also means the
 * specialisation table is gone: the runtime keys the cache on the arguments already.
 */
extern const uintptr_t cider_combine_currentvaluesubject_descriptor[];

/* CombineSubject.c owns the instance layout, so it owns the size the class has to declare. */
extern size_t cider_combine_subject_instance_size(const void *output);

void *cider_combine_class_instantiate(const void *descriptor, const void *const *arguments,
                                      const void *pattern)
{
    void *metadata = cider_combine_build_class(descriptor,
                                               cider_combine_subject_instance_size(arguments[0]),
                                               arguments[0], arguments[1]);

    if (cider_combine_trace()) {
        fprintf(stderr, "CIDER_COMBINE class instantiate desc=%p pattern=%p args=%p,%p -> %p\n",
                descriptor, pattern, arguments[0], arguments[1], metadata);
        fflush(stderr);
    }
    return metadata;
}

CiderMetadataResponse cider_combine_currentvaluesubject_metadata_accessor(size_t request,
                                                                          const void *output,
                                                                          const void *failure)
{
    const void *arguments[2] = { output, failure };

    return cider_combine_generic_metadata(cider_combine_currentvaluesubject_descriptor, request,
                                          arguments, "CurrentValueSubject");
}

/*
 * THE VALUE WITNESSES. Eight functions, then size, stride, flags and the extra inhabitant count, in
 * that order: the layout was read out of a real table in one of the application's own frameworks
 * rather than from memory.
 *
 * A BUFFER IS THREE WORDS and a value of eight bytes lives inline in it, so the buffer witnesses are
 * the same copy as the direct ones.
 */
static void *cider_vw_initializeBufferWithCopyOfBuffer(void *dest, void *src, const void *self)
{
    (void) self;
    memcpy(dest, src, 8);
    return dest;
}

static void cider_vw_destroy(void *object, const void *self)
{
    (void) object;
    (void) self;
}

static void *cider_vw_initializeWithCopy(void *dest, void *src, const void *self)
{
    (void) self;
    memcpy(dest, src, 8);
    return dest;
}

static void *cider_vw_assignWithCopy(void *dest, void *src, const void *self)
{
    (void) self;
    memcpy(dest, src, 8);
    return dest;
}

static void *cider_vw_initializeWithTake(void *dest, void *src, const void *self)
{
    (void) self;
    memcpy(dest, src, 8);
    return dest;
}

static void *cider_vw_assignWithTake(void *dest, void *src, const void *self)
{
    (void) self;
    memcpy(dest, src, 8);
    return dest;
}

/*
 * ENUM TAGS FOR A SINGLE PAYLOAD, which is how Optional<AnyPublisher> is stored. With no extra
 * inhabitants declared, the only case that fits inline is the payload itself, so this answers zero
 * for every value and stores nothing.
 */
static unsigned cider_vw_getEnumTagSinglePayload(const void *object, unsigned emptyCases,
                                                 const void *self)
{
    (void) object;
    (void) emptyCases;
    (void) self;
    return 0;
}

static void cider_vw_storeEnumTagSinglePayload(void *object, unsigned whichCase, unsigned emptyCases,
                                               const void *self)
{
    (void) object;
    (void) whichCase;
    (void) emptyCases;
    (void) self;
}

struct CiderValueWitnessTable {
    void *(*initializeBufferWithCopyOfBuffer)(void *, void *, const void *);
    void (*destroy)(void *, const void *);
    void *(*initializeWithCopy)(void *, void *, const void *);
    void *(*assignWithCopy)(void *, void *, const void *);
    void *(*initializeWithTake)(void *, void *, const void *);
    void *(*assignWithTake)(void *, void *, const void *);
    unsigned (*getEnumTagSinglePayload)(const void *, unsigned, const void *);
    void (*storeEnumTagSinglePayload)(void *, unsigned, unsigned, const void *);
    size_t size;
    size_t stride;
    uint32_t flags;
    uint32_t extraInhabitantCount;
};

/*
 * flags = 7 is the alignment mask for eight byte alignment with every other bit clear, which says
 * plain old data: trivially copyable, trivially destroyable, stored inline. That is a lie about
 * AnyPublisher and a deliberate one, see the file comment.
 */
__attribute__((visibility("default")))
const struct CiderValueWitnessTable cider_combine_anypublisher_vwt = {
    .initializeBufferWithCopyOfBuffer = cider_vw_initializeBufferWithCopyOfBuffer,
    .destroy = cider_vw_destroy,
    .initializeWithCopy = cider_vw_initializeWithCopy,
    .assignWithCopy = cider_vw_assignWithCopy,
    .initializeWithTake = cider_vw_initializeWithTake,
    .assignWithTake = cider_vw_assignWithTake,
    .getEnumTagSinglePayload = cider_vw_getEnumTagSinglePayload,
    .storeEnumTagSinglePayload = cider_vw_storeEnumTagSinglePayload,
    .size = 8,
    .stride = 8,
    .flags = 7,
    .extraInhabitantCount = 0,
};

/*
 * AND THE PARTS C CANNOT WRITE, IN THE SAME TRANSLATION UNIT ON PURPOSE.
 *
 * Every reference inside a Swift descriptor is a 32 bit distance from the field holding it, which is
 * not a constant expression in C. An assembler writes those as "target - ." without effort, but
 * Mach-O will only relocate a subtraction when BOTH symbols are defined in the same object file, so
 * a separate .s file cannot reach the functions above: "symbol can not be undefined in a subtraction
 * expression". Module level asm keeps them together.
 *
 * The shapes below were read field by field out of descriptors the Swift compiler itself emitted, in
 * iA Writer's own frameworks, with scratchpad/swiftdesc.py and scratchpad/swiftdump.py:
 *
 *     +0  flags 0xd1        struct (0x11) | unique (0x40) | generic (0x80)
 *     +4  parent            relative, the module descriptor
 *     +8  name              relative
 *     +12 access function   relative, the Ma accessor
 *     +16 field descriptor  relative
 *     +20 number of fields
 *     +24 field offset vector offset
 *     +28 generic instantiation cache   relative, writable, SIXTEEN WORDS
 *     +32 generic pattern               relative
 *     +36 parameters | requirements
 *     +40 key arguments | extra arguments
 *     +44 one byte per generic parameter, 0x80 for a key type parameter, padded to four
 *
 * and a generic value metadata pattern is four words: instantiation function, completion function,
 * pattern flags, value witnesses. A NULL completion function is how the runtime is told the metadata
 * is complete as soon as it is allocated, which is true here because the layout does not depend on
 * the arguments.
 */
__asm__(
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_name_module\n"
"_cider_combine_name_module:\n"
"	.asciz \"Combine\"\n"
"	.private_extern _cider_combine_name_anypublisher\n"
"_cider_combine_name_anypublisher:\n"
"	.asciz \"AnyPublisher\"\n"
"\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_module_descriptor\n"
"_cider_combine_module_descriptor:\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_name_module - (_cider_combine_module_descriptor + 8)\n"
"\n"
"	.globl _$s7Combine12AnyPublisherVMn\n"
"	.p2align 2\n"
"_$s7Combine12AnyPublisherVMn:\n"
"	.long 0xd1\n"
"	.long _cider_combine_module_descriptor - (_$s7Combine12AnyPublisherVMn + 4)\n"
"	.long _cider_combine_name_anypublisher - (_$s7Combine12AnyPublisherVMn + 8)\n"
"	.long _cider_combine_anypublisher_metadata_accessor - (_$s7Combine12AnyPublisherVMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_anypublisher_cache - (_$s7Combine12AnyPublisherVMn + 28)\n"
"	.long _cider_combine_anypublisher_pattern - (_$s7Combine12AnyPublisherVMn + 32)\n"
"	.short 2, 0\n"
"	.short 2, 0\n"
"	.byte 0x80, 0x80, 0, 0\n"
"\n"
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_anypublisher_pattern\n"
"_cider_combine_anypublisher_pattern:\n"
"	.long _cider_combine_anypublisher_instantiate - _cider_combine_anypublisher_pattern\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_anypublisher_vwt - (_cider_combine_anypublisher_pattern + 12)\n"
"\n"
"	.section __TEXT,__swift5_types\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_anypublisher_typerecord\n"
"_cider_combine_anypublisher_typerecord:\n"
"	.long _$s7Combine12AnyPublisherVMn - _cider_combine_anypublisher_typerecord\n"
"\n"
"	.section __DATA,__data\n"
"	.p2align 3\n"
"	.private_extern _cider_combine_anypublisher_cache\n"
"_cider_combine_anypublisher_cache:\n"
"	.space 128, 0\n"
"\n"
"	.globl _$s7Combine12AnyPublisherVMa\n"
"	.set _$s7Combine12AnyPublisherVMa, _cider_combine_anypublisher_metadata_accessor\n"
"	.globl _cider_combine_anypublisher_descriptor\n"
"	.set _cider_combine_anypublisher_descriptor, _$s7Combine12AnyPublisherVMn\n"
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_name_anycancellable\n"
"_cider_combine_name_anycancellable:\n"
"	.asciz \"AnyCancellable\"\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
"	.globl _$s7Combine14AnyCancellableCMn\n"
"_$s7Combine14AnyCancellableCMn:\n"
"	.long 0x50\n"
"	.long _cider_combine_module_descriptor - (_$s7Combine14AnyCancellableCMn + 4)\n"
"	.long _cider_combine_name_anycancellable - (_$s7Combine14AnyCancellableCMn + 8)\n"
"	.long _cider_combine_anycancellable_metadata_accessor - (_$s7Combine14AnyCancellableCMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 3\n"
"	.long 10\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.section __TEXT,__swift5_types\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_anycancellable_typerecord\n"
"_cider_combine_anycancellable_typerecord:\n"
"	.long _$s7Combine14AnyCancellableCMn - _cider_combine_anycancellable_typerecord\n"
"	.globl _$s7Combine14AnyCancellableCMa\n"
"	.set _$s7Combine14AnyCancellableCMa, _cider_combine_anycancellable_metadata_accessor\n"
"	.globl _cider_combine_anycancellable_descriptor\n"
"	.set _cider_combine_anycancellable_descriptor, _$s7Combine14AnyCancellableCMn\n"
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_name_currentvaluesubject\n"
"_cider_combine_name_currentvaluesubject:\n"
"	.asciz \"CurrentValueSubject\"\n"
"	.section __DATA,__data\n"
"	.p2align 3\n"
"	.private_extern _cider_combine_currentvaluesubject_cache\n"
"_cider_combine_currentvaluesubject_cache:\n"
"	.space 128, 0\n"
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_currentvaluesubject_pattern\n"
"_cider_combine_currentvaluesubject_pattern:\n"
"	.long _cider_combine_class_instantiate - _cider_combine_currentvaluesubject_pattern\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
"	.globl _$s7Combine19CurrentValueSubjectCMn\n"
"_$s7Combine19CurrentValueSubjectCMn:\n"
"	.long 0xd0\n"
"	.long _cider_combine_module_descriptor - (_$s7Combine19CurrentValueSubjectCMn + 4)\n"
"	.long _cider_combine_name_currentvaluesubject - (_$s7Combine19CurrentValueSubjectCMn + 8)\n"
"	.long _cider_combine_currentvaluesubject_metadata_accessor - (_$s7Combine19CurrentValueSubjectCMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 3\n"
"	.long 12\n"
"	.long 2\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_currentvaluesubject_cache - (_$s7Combine19CurrentValueSubjectCMn + 44)\n"
"	.long _cider_combine_currentvaluesubject_pattern - (_$s7Combine19CurrentValueSubjectCMn + 48)\n"
"	.short 2, 0\n"
"	.short 2, 0\n"
"	.byte 0x80, 0x80, 0, 0\n"
"	.section __TEXT,__swift5_types\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_currentvaluesubject_typerecord\n"
"_cider_combine_currentvaluesubject_typerecord:\n"
"	.long _$s7Combine19CurrentValueSubjectCMn - _cider_combine_currentvaluesubject_typerecord\n"
"	.globl _$s7Combine19CurrentValueSubjectCMa\n"
"	.set _$s7Combine19CurrentValueSubjectCMa, _cider_combine_currentvaluesubject_metadata_accessor\n"
"	.globl _cider_combine_currentvaluesubject_descriptor\n"
"	.set _cider_combine_currentvaluesubject_descriptor, _$s7Combine19CurrentValueSubjectCMn\n"
);

/*
 * THE NAMESPACE AND THE THREE STRUCTS INSIDE IT.
 *
 * The enum carries no cases and no generic parameters; it exists so the three descriptors have the
 * parent chain their mangled names describe. An enum descriptor is a nominal descriptor with two
 * extra words, the payload case count and the empty case count, and both are zero for a namespace.
 *
 * Each struct is the AnyPublisher shape with a different parameter count, and they share the
 * instantiation function and the value witness table, because for all of them the answer is the same:
 * the layout does not depend on the arguments, and one pointer wide is a consistent lie. See the file
 * comment for what that costs.
 */
__asm__(
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_name_publishers\n"
"_cider_combine_name_publishers:\n"
"	.asciz \"Publishers\"\n"
"	.private_extern _cider_combine_name_receiveon\n"
"_cider_combine_name_receiveon:\n"
"	.asciz \"ReceiveOn\"\n"
"	.private_extern _cider_combine_name_map\n"
"_cider_combine_name_map:\n"
"	.asciz \"Map\"\n"
"	.private_extern _cider_combine_name_removeduplicates\n"
"_cider_combine_name_removeduplicates:\n"
"	.asciz \"RemoveDuplicates\"\n"
"\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
"	.globl _$s7Combine10PublishersOMn\n"
"_$s7Combine10PublishersOMn:\n"
"	.long 0x52\n"
"	.long _cider_combine_module_descriptor - (_$s7Combine10PublishersOMn + 4)\n"
"	.long _cider_combine_name_publishers - (_$s7Combine10PublishersOMn + 8)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"\n"
"	.globl _$s7Combine10PublishersO9ReceiveOnVMn\n"
"	.p2align 2\n"
"_$s7Combine10PublishersO9ReceiveOnVMn:\n"
"	.long 0xd1\n"
"	.long _$s7Combine10PublishersOMn - (_$s7Combine10PublishersO9ReceiveOnVMn + 4)\n"
"	.long _cider_combine_name_receiveon - (_$s7Combine10PublishersO9ReceiveOnVMn + 8)\n"
"	.long _cider_combine_receiveon_metadata_accessor - (_$s7Combine10PublishersO9ReceiveOnVMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_receiveon_cache - (_$s7Combine10PublishersO9ReceiveOnVMn + 28)\n"
"	.long _cider_combine_receiveon_pattern - (_$s7Combine10PublishersO9ReceiveOnVMn + 32)\n"
"	.short 2, 0\n"
"	.short 2, 0\n"
"	.byte 0x80, 0x80, 0, 0\n"
"\n"
"	.globl _$s7Combine10PublishersO3MapVMn\n"
"	.p2align 2\n"
"_$s7Combine10PublishersO3MapVMn:\n"
"	.long 0xd1\n"
"	.long _$s7Combine10PublishersOMn - (_$s7Combine10PublishersO3MapVMn + 4)\n"
"	.long _cider_combine_name_map - (_$s7Combine10PublishersO3MapVMn + 8)\n"
"	.long _cider_combine_map_metadata_accessor - (_$s7Combine10PublishersO3MapVMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_map_cache - (_$s7Combine10PublishersO3MapVMn + 28)\n"
"	.long _cider_combine_map_pattern - (_$s7Combine10PublishersO3MapVMn + 32)\n"
"	.short 2, 0\n"
"	.short 2, 0\n"
"	.byte 0x80, 0x80, 0, 0\n"
"\n"
"	.globl _$s7Combine10PublishersO16RemoveDuplicatesVMn\n"
"	.p2align 2\n"
"_$s7Combine10PublishersO16RemoveDuplicatesVMn:\n"
"	.long 0xd1\n"
"	.long _$s7Combine10PublishersOMn - (_$s7Combine10PublishersO16RemoveDuplicatesVMn + 4)\n"
"	.long _cider_combine_name_removeduplicates - (_$s7Combine10PublishersO16RemoveDuplicatesVMn + 8)\n"
"	.long _cider_combine_removeduplicates_metadata_accessor - (_$s7Combine10PublishersO16RemoveDuplicatesVMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_removeduplicates_cache - (_$s7Combine10PublishersO16RemoveDuplicatesVMn + 28)\n"
"	.long _cider_combine_removeduplicates_pattern - (_$s7Combine10PublishersO16RemoveDuplicatesVMn + 32)\n"
"	.short 1, 0\n"
"	.short 1, 0\n"
"	.byte 0x80, 0, 0, 0\n"
"\n"
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_receiveon_pattern\n"
"_cider_combine_receiveon_pattern:\n"
"	.long _cider_combine_anypublisher_instantiate - _cider_combine_receiveon_pattern\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_anypublisher_vwt - (_cider_combine_receiveon_pattern + 12)\n"
"	.private_extern _cider_combine_map_pattern\n"
"_cider_combine_map_pattern:\n"
"	.long _cider_combine_anypublisher_instantiate - _cider_combine_map_pattern\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_anypublisher_vwt - (_cider_combine_map_pattern + 12)\n"
"	.private_extern _cider_combine_removeduplicates_pattern\n"
"_cider_combine_removeduplicates_pattern:\n"
"	.long _cider_combine_anypublisher_instantiate - _cider_combine_removeduplicates_pattern\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_combine_anypublisher_vwt - (_cider_combine_removeduplicates_pattern + 12)\n"
"\n"
"	.section __TEXT,__swift5_types\n"
"	.p2align 2\n"
"	.private_extern _cider_combine_receiveon_typerecord\n"
"_cider_combine_receiveon_typerecord:\n"
"	.long _$s7Combine10PublishersO9ReceiveOnVMn - _cider_combine_receiveon_typerecord\n"
"	.private_extern _cider_combine_map_typerecord\n"
"_cider_combine_map_typerecord:\n"
"	.long _$s7Combine10PublishersO3MapVMn - _cider_combine_map_typerecord\n"
"	.private_extern _cider_combine_removeduplicates_typerecord\n"
"_cider_combine_removeduplicates_typerecord:\n"
"	.long _$s7Combine10PublishersO16RemoveDuplicatesVMn - _cider_combine_removeduplicates_typerecord\n"
"	.private_extern _cider_combine_publishers_typerecord\n"
"_cider_combine_publishers_typerecord:\n"
"	.long _$s7Combine10PublishersOMn - _cider_combine_publishers_typerecord\n"
"\n"
"	.section __DATA,__data\n"
"	.p2align 3\n"
"	.private_extern _cider_combine_receiveon_cache\n"
"_cider_combine_receiveon_cache:\n"
"	.space 128, 0\n"
"	.private_extern _cider_combine_map_cache\n"
"_cider_combine_map_cache:\n"
"	.space 128, 0\n"
"	.private_extern _cider_combine_removeduplicates_cache\n"
"_cider_combine_removeduplicates_cache:\n"
"	.space 128, 0\n"
"\n"
"	.globl _$s7Combine10PublishersO9ReceiveOnVMa\n"
"	.set _$s7Combine10PublishersO9ReceiveOnVMa, _cider_combine_receiveon_metadata_accessor\n"
"	.globl _$s7Combine10PublishersO3MapVMa\n"
"	.set _$s7Combine10PublishersO3MapVMa, _cider_combine_map_metadata_accessor\n"
"	.globl _$s7Combine10PublishersO16RemoveDuplicatesVMa\n"
"	.set _$s7Combine10PublishersO16RemoveDuplicatesVMa, _cider_combine_removeduplicates_metadata_accessor\n"
"	.globl _cider_combine_receiveon_descriptor\n"
"	.set _cider_combine_receiveon_descriptor, _$s7Combine10PublishersO9ReceiveOnVMn\n"
"	.globl _cider_combine_map_descriptor\n"
"	.set _cider_combine_map_descriptor, _$s7Combine10PublishersO3MapVMn\n"
"	.globl _cider_combine_removeduplicates_descriptor\n"
"	.set _cider_combine_removeduplicates_descriptor, _$s7Combine10PublishersO16RemoveDuplicatesVMn\n"
);
