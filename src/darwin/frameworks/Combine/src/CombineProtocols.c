/*
 * COMBINE'S PROTOCOLS, BECAUSE THE SWIFT RUNTIME DYLIBS CONFORM TO THEM.
 *
 * This is not about the application. libswiftFoundation and libswiftDispatch ship conformances of
 * their own types to Combine's protocols: NotificationCenter.Publisher is a Publisher, DispatchQueue
 * is a Scheduler. Those conformances use RESILIENT WITNESSES, where each witness names the
 * requirement it implements by a pointer and the runtime turns that pointer into a witness table
 * index by subtracting the protocol's requirement base. The pointers are weak imports from Combine,
 * one exported symbol per requirement, and with no Combine to bind them every one is null:
 *
 *     swift_getWitnessTable + 414
 *       movl 0x10(%rax), %eax        <- the protocol descriptor, null, so the fault is at sixteen
 *
 * WHAT IS MEASURED AND WHAT IS CHOSEN. The SET of requirements and their COUNT are measured, with
 * scratchpad/swiftconf.py, out of the conformance records that name them: four for Publisher, nine
 * for Scheduler, and so on. The ORDER within a protocol is CHOSEN, because the only code that turns
 * these pointers into indices is the same code that reads these symbols, so any consistent order
 * agrees with itself. Where a conformance record exists the order here follows it anyway.
 *
 * The requirement kinds are Swift's own: 0 base protocol, 1 method, 3 getter, 7 associated type,
 * 8 associated conformance. A getter is written as a method here, which the runtime does not read on
 * any path this framework reaches; associated types are the ones it does read.
 *
 * WHAT THIS DOES NOT DO. A descriptor makes the table BUILDABLE, not useful. The witnesses come from
 * the conforming framework, so a DispatchQueue really does schedule; what is missing is everything
 * Combine itself would have implemented, which is next door in CombineSubject.c.
 */

#include <stdint.h>

#define CIDER_PROTO_HEAD(label, cname, nreq, assoc)                                                \
    "	.section __TEXT,__const\n"                                                                  \
    "	.p2align 2\n"                                                                               \
    "	.private_extern _cider_proto_name_" label "\n"                                              \
    "_cider_proto_name_" label ":\n"                                                               \
    "	.asciz \"" cname "\"\n"                                                                     \
    "	.private_extern _cider_proto_assoc_" label "\n"                                             \
    "_cider_proto_assoc_" label ":\n"                                                              \
    "	.asciz \"" assoc "\"\n"                                                                     \
    "	.section __TEXT,__constg_swiftt\n"                                                          \
    "	.p2align 2\n"                                                                               \
    "	.private_extern _cider_proto_" label "\n"                                                   \
    "_cider_proto_" label ":\n"                                                                    \
    "	.long 0x10043\n"                                                                            \
    "	.long _cider_proto_module - (_cider_proto_" label " + 4)\n"                                 \
    "	.long _cider_proto_name_" label " - (_cider_proto_" label " + 8)\n"                         \
    "	.long 0\n"                                                                                  \
    "	.long " #nreq "\n"                                                                          \
    "	.long _cider_proto_assoc_" label " - (_cider_proto_" label " + 20)\n"

#define CIDER_PROTO_REQ(kind) "	.long " #kind "\n	.long 0\n"

#define CIDER_PROTO_NAME(label, sym)                                                               \
    "	.globl " sym "\n"                                                                           \
    "	.set " sym ", _cider_proto_" label "\n"

/* The base is one entry BELOW the first requirement, which the runtime adds back when it indexes:
 * that is how word zero of a witness table stays the conformance descriptor. */
#define CIDER_PROTO_SYM(label, index, sym)                                                         \
    "	.globl " sym "\n"                                                                           \
    "	.set " sym ", _cider_proto_" label " + 24 + 8 * " #index "\n"

__asm__(
"	.section __TEXT,__const\n"
"	.p2align 2\n"
"	.private_extern _cider_proto_name_module\n"
"_cider_proto_name_module:\n"
"	.asciz \"Combine\"\n"
"	.section __TEXT,__constg_swiftt\n"
"	.p2align 2\n"
"	.private_extern _cider_proto_module\n"
"_cider_proto_module:\n"
"	.long 0\n"
"	.long 0\n"
"	.long _cider_proto_name_module - (_cider_proto_module + 8)\n"

/* Scheduler, nine requirements, in the order DispatchQueue's own conformance names them. */
        CIDER_PROTO_HEAD("scheduler", "Scheduler", 9, "SchedulerTimeType SchedulerOptions")
        CIDER_PROTO_REQ(8) CIDER_PROTO_REQ(8) CIDER_PROTO_REQ(7) CIDER_PROTO_REQ(7)
        CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1)
        CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("scheduler", "_$s7Combine9SchedulerMp")
        CIDER_PROTO_SYM("scheduler", 0, "_$s7Combine9SchedulerP0B8TimeTypeAC_SxTn")
        CIDER_PROTO_SYM("scheduler", 1,
                "_$s7Combine9SchedulerP0B8TimeTypeAC_6StrideSxAA0bC19IntervalConvertibleTn")
        CIDER_PROTO_SYM("scheduler", 2, "_$s17SchedulerTimeType7Combine0A0PTl")
        CIDER_PROTO_SYM("scheduler", 3, "_$s16SchedulerOptions7Combine0A0PTl")
        CIDER_PROTO_SYM("scheduler", 4, "_$s7Combine9SchedulerP3now0B8TimeTypeQzvgTq")
        CIDER_PROTO_SYM("scheduler", 5,
                "_$s7Combine9SchedulerP16minimumTolerance0B8TimeType_6StrideQZvgTq")
        CIDER_PROTO_SYM("scheduler", 6, "_$s7Combine9SchedulerP8schedule7options_y0B7OptionsQzSg_yyctFTq")
        CIDER_PROTO_SYM("scheduler", 7,
                "_$s7Combine9SchedulerP8schedule5after9tolerance7options_y0B8TimeTypeQz_AH_6StrideQZ0B7OptionsQzSgyyctFTq")
        CIDER_PROTO_SYM("scheduler", 8,
                "_$s7Combine9SchedulerP8schedule5after8interval9tolerance7options_AA11Cancellable_p0B8TimeTypeQz_AJ_6StrideQZAM0B7OptionsQzSgyyctFTq")

/* SchedulerTimeIntervalConvertible, five ways to say how long. */
        CIDER_PROTO_HEAD("interval", "SchedulerTimeIntervalConvertible", 5, "")
        CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1)
        CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("interval", "_$s7Combine32SchedulerTimeIntervalConvertibleMp")
        CIDER_PROTO_SYM("interval", 0,
                "_$s7Combine32SchedulerTimeIntervalConvertibleP7secondsyxSiFZTq")
        CIDER_PROTO_SYM("interval", 1,
                "_$s7Combine32SchedulerTimeIntervalConvertibleP7secondsyxSdFZTq")
        CIDER_PROTO_SYM("interval", 2,
                "_$s7Combine32SchedulerTimeIntervalConvertibleP12millisecondsyxSiFZTq")
        CIDER_PROTO_SYM("interval", 3,
                "_$s7Combine32SchedulerTimeIntervalConvertibleP12microsecondsyxSiFZTq")
        CIDER_PROTO_SYM("interval", 4,
                "_$s7Combine32SchedulerTimeIntervalConvertibleP11nanosecondsyxSiFZTq")

/* Cancellable and the identifier protocol every subscriber carries. */
        CIDER_PROTO_HEAD("cancellable", "Cancellable", 1, "")
        CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("cancellable", "_$s7Combine11CancellableMp")
        CIDER_PROTO_SYM("cancellable", 0, "_$s7Combine11CancellableP6cancelyyFTq")

        CIDER_PROTO_HEAD("identifier", "CustomCombineIdentifierConvertible", 1, "")
        CIDER_PROTO_REQ(3)
        CIDER_PROTO_NAME("identifier", "_$s7Combine06CustomA21IdentifierConvertibleMp")
        CIDER_PROTO_SYM("identifier", 0,
                "_$s7Combine06CustomA21IdentifierConvertibleP07combineC0AA0aC0VvgTq")

/* Subscription inherits both of those and adds one method. */
        CIDER_PROTO_HEAD("subscription", "Subscription", 3, "")
        CIDER_PROTO_REQ(0) CIDER_PROTO_REQ(0) CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("subscription", "_$s7Combine12SubscriptionMp")
        CIDER_PROTO_SYM("subscription", 0,
                "_$s7Combine12SubscriptionPAA06CustomA21IdentifierConvertibleTb")
        CIDER_PROTO_SYM("subscription", 1, "_$s7Combine12SubscriptionPAA11CancellableTb")
        CIDER_PROTO_SYM("subscription", 2,
                "_$s7Combine12SubscriptionP7requestyyAA11SubscribersO6DemandVFTq")

/* Subscriber: one base protocol, one associated conformance, two associated types, three methods. */
        CIDER_PROTO_HEAD("subscriber", "Subscriber", 7, "Input Failure")
        CIDER_PROTO_REQ(0) CIDER_PROTO_REQ(8) CIDER_PROTO_REQ(7) CIDER_PROTO_REQ(7)
        CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1) CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("subscriber", "_$s7Combine10SubscriberMp")
        CIDER_PROTO_SYM("subscriber", 0,
                "_$s7Combine10SubscriberPAA06CustomA21IdentifierConvertibleTb")
        CIDER_PROTO_SYM("subscriber", 1, "_$s7Combine10SubscriberP7FailureAC_s5ErrorTn")
        CIDER_PROTO_SYM("subscriber", 2, "_$s5Input7Combine10SubscriberPTl")
        CIDER_PROTO_SYM("subscriber", 3, "_$s7Failure7Combine10SubscriberPTl")
        CIDER_PROTO_SYM("subscriber", 4,
                "_$s7Combine10SubscriberP7receive12subscriptionyAA12Subscription_p_tFTq")
        CIDER_PROTO_SYM("subscriber", 5,
                "_$s7Combine10SubscriberP7receiveyAA11SubscribersO6DemandV5InputQzFTq")
        CIDER_PROTO_SYM("subscriber", 6,
                "_$s7Combine10SubscriberP7receive10completionyAA11SubscribersO10CompletionOy_7FailureQzG_tFTq")

/* ConnectablePublisher and the two coder protocols, which libswiftFoundation also conforms to. */
        CIDER_PROTO_HEAD("connectable", "ConnectablePublisher", 2, "")
        CIDER_PROTO_REQ(0) CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("connectable", "_$s7Combine20ConnectablePublisherMp")
        CIDER_PROTO_SYM("connectable", 0, "_$s7Combine20ConnectablePublisherPAA0C0Tb")
        CIDER_PROTO_SYM("connectable", 1,
                "_$s7Combine20ConnectablePublisherP7connectAA11Cancellable_pyFTq")

        CIDER_PROTO_HEAD("decoder", "TopLevelDecoder", 2, "Input")
        CIDER_PROTO_REQ(7) CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("decoder", "_$s7Combine15TopLevelDecoderMp")
        CIDER_PROTO_SYM("decoder", 0, "_$s5Input7Combine15TopLevelDecoderPTl")
        CIDER_PROTO_SYM("decoder", 1,
                "_$s7Combine15TopLevelDecoderP6decode_4fromqd__qd__m_5InputQztKSeRd__lFTq")

        CIDER_PROTO_HEAD("encoder", "TopLevelEncoder", 2, "Output")
        CIDER_PROTO_REQ(7) CIDER_PROTO_REQ(1)
        CIDER_PROTO_NAME("encoder", "_$s7Combine15TopLevelEncoderMp")
        CIDER_PROTO_SYM("encoder", 0, "_$s6Output7Combine15TopLevelEncoderPTl")
        CIDER_PROTO_SYM("encoder", 1,
                "_$s7Combine15TopLevelEncoderP6encodey6OutputQzqd__KSERd__lFTq")
);
