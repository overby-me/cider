/*
 * A FRAMEWORK THAT EXISTS SO DYLD CAN FINISH, and nothing more than iTerm2 asks of it.
 *
 * dyld refuses to start a process whose LIBRARY is missing, whatever it does or does not use from
 * it, so an application that merely links FoundationModels cannot run without one. What iTerm2 actually
 * binds from this framework was counted with llvm-objdump across --bind, --lazy-bind and
 * --weak-bind: 18 symbols, all of the eager ones weak_import. Nothing has to be defined.
 */

/* An empty translation unit is not a valid dylib on every toolchain, so give it one symbol that
 * says what this is when something goes looking. */
const char cider_foundationmodels_placeholder[] = "cider stub FoundationModels";
