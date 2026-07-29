// A stand-in for what libSystem provides to every Mach-O link: dyld_stub_binder,
// the helper ld64 references from lazy-binding stubs. Without it in the link,
// ld64 fails with "symbol dyld_stub_binder not found (normally in
// libSystem.dylib)" for any cross-dylib call.
//
// The real build has this for free: the -dylib_file map in cmake/use_ld64.cmake
// points /usr/lib/libSystem.B.dylib at the built umbrella, and dyld supplies the
// symbol from src/dyld_stub_binder.S. This fixture is self-contained, so it
// supplies its own.
//
// The asm label is required: dyld declares the symbol as `.globl
// dyld_stub_binder` with NO leading underscore, whereas a plain C function would
// be `_dyld_stub_binder` and ld64 would not find it.
void dyld_stub_binder(void) __asm__("dyld_stub_binder");

void dyld_stub_binder(void) {
}
