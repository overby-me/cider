# Swift 5.5.3 standard library and concurrency runtime

Two files lifted from the official Swift 5.5.3 macOS toolchain. `scripts/fetch-swift-5.5.3.sh`
reproduces them byte for byte; the hashes below are the check.

    source  https://download.swift.org/swift-5.5.3-release/xcode/swift-5.5.3-RELEASE/swift-5.5.3-RELEASE-osx.pkg
    sha256  609df4e77bea489028f26e1cd6efbf84a04b66c2c8fa47778fd98b96cd94ad3d
    within  ./usr/lib/swift/macosx/, thinned to x86_64 with llvm-lipo

    6df9e2a9e3b93517e711f1faeb2acd52c577a72480daec005c53e8b8263dc989  libswiftCore.dylib
    6c1958fdcf4f993c213278012f8b48a8bcc04892e497d946e8531f2adc7fd889  libswift_Concurrency.dylib

Licence: Apache 2.0 with the Runtime Library Exception, per swift.org.

## Why these two and not the whole set

`vendor/pins/swift` carries Swift **5.2.2**, which is the last toolchain that shipped the macOS
overlays (libswiftAppKit, libswiftFoundation and 42 more) as dylibs; later ones expect them from the
SDK. Those 44 overlays stay on 5.2.2 and are not touched here. Only the standard library is
replaced, and only the concurrency runtime is added.

That works because the seam is one symbol wide, measured rather than assumed:

- Swift 5.5.3 `libswiftCore.dylib` has 233 undefined symbols and this prefix provides all 233.
- The 5.2.2 overlays import 3024 symbols from the standard library. 5.5.3 provides 3023. The
  missing one is `__swift_classIsSwiftMask`, which 5.2 exported and later runtimes keep private;
  `src/darwin/swiftshim/libswiftCompat.c` supplies it, and the loader reaches it only after a two
  level lookup has already failed.

## Why it is needed at all

Swift concurrency arrived in 5.5. Under 5.2.2 there is no `_Concurrency` module and the demangler
has no `ScP` entry, so `__swift_instantiateConcreteTypeFromMangledNameV2` returns NULL for
`Optional<TaskPriority>` and the caller reads the value witness table at `metadata - 8`. iTerm2 hits
that the moment a session starts. Dropping in a back-deployment `libswift_Concurrency.dylib` alone
does NOT help: the lookup is the standard library's, so the standard library is what has to move.
