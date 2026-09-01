/*
 * A FRAMEWORK THAT EXISTS SO DYLD CAN FINISH, and nothing more than iTerm2 asks of it.
 *
 * dyld refuses to start a process whose LIBRARY is missing, whatever it does or does not use from
 * it, so an application that merely links Charts cannot run without one. What iTerm2 actually
 * binds from this framework was counted with llvm-objdump across --bind, --lazy-bind and
 * --weak-bind: 62 symbols, and every one bound EAGERLY is weak_import, which resolves to zero
 * without failing the load. So the framework needs to exist and needs to define nothing at all.
 */

/* An empty translation unit is not a valid dylib on every toolchain, so give it one symbol that
 * says what this is when something goes looking. */
const char cider_charts_placeholder[] = "cider stub Charts";
