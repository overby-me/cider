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
);
