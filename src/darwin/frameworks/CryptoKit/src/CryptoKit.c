/*
 * THREE SYMBOLS, WHICH IS THE WHOLE OF WHAT AN APPLICATION ASKS OF CRYPTOKIT HERE.
 *
 * iTerm2 3.6.10 will not start without this framework:
 *
 *     dyld: Library not loaded: /System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit
 *       Referenced from: /Applications/iTerm2.app/Contents/MacOS/iTerm2
 *       Reason: image not found
 *
 * and everything it binds from it, counted across --bind, --lazy-bind and --weak-bind, is
 * Curve25519.Signing.PublicKey: the metadata accessor, init(rawRepresentation:) and
 * isValidSignature(_:for:). Nothing else. So this is a real framework with a real type in it rather
 * than an empty shell, and it is far smaller than the Combine work next door because the type is NOT
 * GENERIC: a non generic struct's metadata is three words that can be emitted statically, with no
 * pattern, no instantiation function and no generic cache.
 *
 * WHAT THE FUNCTIONS DO, and why that is the honest answer rather than a stub:
 *
 *   init(rawRepresentation:)  keeps nothing and succeeds. The value is 32 bytes because that is
 *                             what a Curve25519 public key is, and it is left zeroed.
 *   isValidSignature(_:for:)  answers FALSE. A signature this port cannot verify is not a valid
 *                             one, and false sends the application down its own failure path
 *                             instead of trusting something unchecked. Answering true would be a
 *                             security claim nobody made.
 *
 * The Swift ABI details here are the ones the Combine work established and docs/wayland-port.md
 * records: relative pointers live in module level asm because a difference of addresses is not a
 * constant expression in C, swiftcall plus swift_context is how a method finds self, and a value
 * returned by a generic caller comes back through a hidden first argument.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* The two word answer a Swift metadata accessor returns. */
typedef struct {
    const void *metadata;
    size_t state;
} CiderMetadataResponse;

extern const uintptr_t cider_cryptokit_publickey_metadata[];

/*
 * A NON GENERIC ACCESSOR IS A CONSTANT. There is nothing to instantiate and nothing to cache: the
 * metadata is in this image and complete the moment it is loaded, so state zero is the truth.
 */
CiderMetadataResponse cider_cryptokit_publickey_metadata_accessor(size_t request);

CiderMetadataResponse cider_cryptokit_publickey_metadata_accessor(size_t request)
{
    CiderMetadataResponse answer;

    (void) request;
    answer.metadata = cider_cryptokit_publickey_metadata;
    answer.state = 0;
    return answer;
}

/* A Curve25519 public key is 32 bytes, so the value is 32 bytes. */
#define CIDER_CURVE25519_KEY_BYTES 32

/*
 * init<D: ContiguousBytes>(rawRepresentation: D) throws
 *
 * The result is bigger than two registers and its size is not known to a generic caller, so it comes
 * back through the hidden first argument. Everything after the representation is the machinery a
 * generic function carries: the argument type's metadata and its witness table.
 */
__attribute__((swiftcall)) void cider_cryptokit_publickey_init(
        void *result __attribute__((swift_indirect_result)), const void *rawRepresentation,
        const void *argumentMetadata, const void *contiguousBytesWitnesses)
        __asm__("_$s9CryptoKit10Curve25519O7SigningO9PublicKeyV17rawRepresentationAGx_tKc10Foundation15ContiguousBytesRzlufC");

__attribute__((swiftcall)) void cider_cryptokit_publickey_init(
        void *result __attribute__((swift_indirect_result)), const void *rawRepresentation,
        const void *argumentMetadata, const void *contiguousBytesWitnesses)
{
    (void) rawRepresentation;
    (void) argumentMetadata;
    (void) contiguousBytesWitnesses;
    memset(result, 0, CIDER_CURVE25519_KEY_BYTES);
}

/*
 * isValidSignature<S: DataProtocol, D: DataProtocol>(_ signature: S, for data: D) -> Bool
 *
 * False, and see the file comment for why that is the answer rather than a stub.
 */
__attribute__((swiftcall)) int8_t cider_cryptokit_publickey_is_valid_signature(
        const void *signature, const void *data, const void *signatureMetadata,
        const void *dataMetadata, const void *signatureWitnesses, const void *dataWitnesses,
        void *self __attribute__((swift_context)))
        __asm__("_$s9CryptoKit10Curve25519O7SigningO9PublicKeyV16isValidSignature_3forSbx_q_t10Foundation12DataProtocolRzAjKR_r0_lF");

__attribute__((swiftcall)) int8_t cider_cryptokit_publickey_is_valid_signature(
        const void *signature, const void *data, const void *signatureMetadata,
        const void *dataMetadata, const void *signatureWitnesses, const void *dataWitnesses,
        void *self __attribute__((swift_context)))
{
    (void) signature;
    (void) data;
    (void) signatureMetadata;
    (void) dataMetadata;
    (void) signatureWitnesses;
    (void) dataWitnesses;
    (void) self;
    return 0;
}

/*
 * THE PARTS C CANNOT WRITE. Every reference inside a Swift descriptor is a 32 bit distance from the
 * field holding it, and Mach-O relocates a subtraction only when both symbols are defined in the
 * same object file, so all of this lives in one module level asm block beside the functions above.
 *
 * The nesting is real: PublicKey is a struct inside enum Signing inside enum Curve25519, and the
 * parent chain is what the runtime walks to name the type. A caseless enum used as a namespace has
 * no payload cases and no empty ones.
 */
__asm__(
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_ck_name_module\n"
"_cider_ck_name_module:\n"
"	.asciz \"CryptoKit\"\n"
"	.private_extern _cider_ck_name_curve\n"
"_cider_ck_name_curve:\n"
"	.asciz \"Curve25519\"\n"
"	.private_extern _cider_ck_name_signing\n"
"_cider_ck_name_signing:\n"
"	.asciz \"Signing\"\n"
"	.private_extern _cider_ck_name_publickey\n"
"_cider_ck_name_publickey:\n"
"	.asciz \"PublicKey\"\n"
"\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
"	.private_extern _cider_ck_module\n"
"_cider_ck_module:\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_ck_name_module - (_cider_ck_module + 8)\n"
"\n"
/* enum Curve25519, a namespace: kind 0x12 with the unique bit. */
"	.private_extern _cider_ck_curve\n"
"_cider_ck_curve:\n"
"	.long 0x52\n"
"	.long _cider_ck_module - (_cider_ck_curve + 4)\n"
"	.long _cider_ck_name_curve - (_cider_ck_curve + 8)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"\n"
"	.private_extern _cider_ck_signing\n"
"_cider_ck_signing:\n"
"	.long 0x52\n"
"	.long _cider_ck_curve - (_cider_ck_signing + 4)\n"
"	.long _cider_ck_name_signing - (_cider_ck_signing + 8)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"\n"
/* struct PublicKey: kind 0x11 with the unique bit, and NOT generic, so no cache and no pattern. */
"	.globl _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn\n"
"_$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn:\n"
"	.long 0x51\n"
"	.long _cider_ck_signing - (_$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn + 4)\n"
"	.long _cider_ck_name_publickey - (_$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn + 8)\n"
"	.long _cider_cryptokit_publickey_metadata_accessor - (_$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn + 12)\n"
"	.long 0\n"
"	.long 0\n"
"	.long 0\n"
"\n"
"	.section __TEXT,__swift5_types\n"
"	.p2align 2\n"
"	.private_extern _cider_ck_typerecord\n"
"_cider_ck_typerecord:\n"
"	.long _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn - _cider_ck_typerecord\n"
"\n"
/*
 * The value witness table, and then the metadata itself. A struct metadata is the kind word and the
 * descriptor, with the witness table one word BELOW the address point, which is why the pointer is
 * emitted first and the exported symbol names the word after it.
 */
"	.section __DATA,__const\n"
"	.p2align 3\n"
"	.private_extern _cider_ck_vwt\n"
"_cider_ck_vwt:\n"
"	.quad _cider_ck_vw_initializeBufferWithCopyOfBuffer\n"
"	.quad _cider_ck_vw_destroy\n"
"	.quad _cider_ck_vw_initializeWithCopy\n"
"	.quad _cider_ck_vw_assignWithCopy\n"
"	.quad _cider_ck_vw_initializeWithCopy\n"
"	.quad _cider_ck_vw_assignWithCopy\n"
"	.quad _cider_ck_vw_getEnumTagSinglePayload\n"
"	.quad _cider_ck_vw_storeEnumTagSinglePayload\n"
"	.quad 32\n"
"	.quad 32\n"
"	.long 7\n"
"	.long 0\n"
"\n"
"	.p2align 3\n"
"	.quad _cider_ck_vwt\n"
"	.globl _cider_cryptokit_publickey_metadata\n"
"_cider_cryptokit_publickey_metadata:\n"
"	.quad 0x200\n"
"	.quad _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMn\n"
"\n"
"	.globl _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMa\n"
"	.set _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVMa, _cider_cryptokit_publickey_metadata_accessor\n"
"	.globl _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVN\n"
"	.set _$s9CryptoKit10Curve25519O7SigningO9PublicKeyVN, _cider_cryptokit_publickey_metadata\n"
);

/* The witnesses. Thirty two POD bytes, so every one of them is a memcpy or nothing at all. */
void *cider_ck_vw_initializeWithCopy(void *dest, void *src, const void *self);
void *cider_ck_vw_assignWithCopy(void *dest, void *src, const void *self);
void cider_ck_vw_destroy(void *object, const void *self);
void *cider_ck_vw_initializeBufferWithCopyOfBuffer(void *dest, void *src, const void *self);
unsigned cider_ck_vw_getEnumTagSinglePayload(const void *object, unsigned emptyCases,
                                             const void *self);
void cider_ck_vw_storeEnumTagSinglePayload(void *object, unsigned whichCase, unsigned emptyCases,
                                           const void *self);

void *cider_ck_vw_initializeWithCopy(void *dest, void *src, const void *self)
{
    (void) self;
    memcpy(dest, src, CIDER_CURVE25519_KEY_BYTES);
    return dest;
}

void *cider_ck_vw_assignWithCopy(void *dest, void *src, const void *self)
{
    return cider_ck_vw_initializeWithCopy(dest, src, self);
}

void cider_ck_vw_destroy(void *object, const void *self)
{
    (void) object;
    (void) self;
}

void *cider_ck_vw_initializeBufferWithCopyOfBuffer(void *dest, void *src, const void *self)
{
    return cider_ck_vw_initializeWithCopy(dest, src, self);
}

/*
 * NO EXTRA INHABITANTS, so an Optional of this type needs a tag byte of its own and the answers are
 * the simple ones: case zero is the payload, and anything else is stored past the value.
 */
unsigned cider_ck_vw_getEnumTagSinglePayload(const void *object, unsigned emptyCases,
                                             const void *self)
{
    (void) self;
    if (emptyCases == 0) {
        return 0;
    }
    return ((const unsigned char *) object)[CIDER_CURVE25519_KEY_BYTES];
}

void cider_ck_vw_storeEnumTagSinglePayload(void *object, unsigned whichCase, unsigned emptyCases,
                                           const void *self)
{
    (void) self;
    if (emptyCases == 0) {
        return;
    }
    ((unsigned char *) object)[CIDER_CURVE25519_KEY_BYTES] = (unsigned char) whichCase;
}
