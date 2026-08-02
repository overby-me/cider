# darling-nix

darling-nix is a Nix-packaged fork of [Darling](https://github.com/darlinghq/darling)
(a userspace macOS/Darwin compatibility layer for Linux, "Wine for macOS"). Its host and
guest runtime have been rewritten in Rust.

**End goal:** build `aarch64-darwin` nixpkgs derivations on non-Apple ARM Linux, using
Darling as the Darwin layer, verified bit-for-bit against cache.nixos.org.

**Current campaign:** make `x86_64-darwin` builds work end-to-end against **nixpkgs 26.05**
(the last release supporting x86_64-darwin: a frozen target and a permanent cache oracle).
x86_64 is the native-speed test rig; most work (libSystem surface, harness, oracle, daemon)
is architecture-independent and transfers to ARM.

Tag work: **[ARCH-FREE]** (transfers as-is), **[ARCH-PARAM]** (transfers if parameterized
now), **[X86-ONLY]** (throwaway, minimize investment).

> This file supersedes the old sprawling `plan/` docs (Campaign 1 + Campaign 2), which
> were consolidated into it. Campaign 1's detailed history lives in git and the removed
> `plan/*.md` (recoverable from history).

---

### #9: the 159 cert links, and cmake's PROGRAM install type

The 159 OpenSSL hash links were the single biggest block of unmapped install entries, and
they were unmappable by design: `execute_process(create_symlink)` in openssl_certificates'
CMakeLists makes them at CONFIGURE time, so no ninja edge builds them and nothing in the
graph names them. They are recorded in install-symlinks.tsv (as ./certs/3c9a4d3b.0 ->
ACCVRAIZ1.crt), but the generator resolved a link value against the LINK's directory, which
puts the target in the build tree -- while the cert it points at is installed from the
SOURCE tree. Same basename, same destination directory, two different absolute paths, so the
lookup missed all 159 times.

A relative symlink means "resolve next to me", so the value now also resolves against the
DESTINATION the link lands in. That is what the link actually means once installed.

cmake's `file(INSTALL ... TYPE PROGRAM ...)` was also unhandled -- it is just a FILE that
lands executable (zipgrep, unxip, clt_install.py). It is now routed through the FILE branch
with exec permissions.

UNMAPPED 182 -> 18. Then the MIG cluster: reboot and shutdown were held back for want of a MIG-generated
kextmanager.h, and three xtrace stub dylibs for want of their MIG targets. Adding mig_gen
targets for kextmanager.defs (system_cmds/reboot.tproj) and self.defs (security/securityd)
landed four more: both binaries and both stub dylibs. tokend.defs also generates, once
security/darling/include/macOS is on mig's include path for its
<securityd_client/ss_types.defs>, but its dylib block wants a SecurityTokend/mig include
subdir that does not exist (every header there is generated), so it is held back again --
one entry, and its framework is held back anyway.

Then the Certificates.bundle and the two z-links, which took UNMAPPED to 15.

The bundle is the only install(DIRECTORY) whose source is a BUILD output:
generate-ca-bundle.py reads the 159 certs and evroot.config and writes a tree of DER tables
and plists. `prefix_dir` cannot express that, because it globs and a glob cannot see
something no action has written yet, so `prefix_gen_dir` (buck/rules/install.bzl) runs the
generator into a `declare_output(dir = True)` and `project()`s the ten files it writes into
a PrefixDirInfo. The contents are DECLARED rather than discovered -- a prefix_tree needs its
path -> artifact mapping at analysis time -- which also makes the rule assert what the
script produces instead of quietly shipping a bundle with a hole in it. EXTRA_DIRS in the
generator points the destination at the hand-written target, the same way EXTRA already does
for the three Rust binaries no manifest mentions.

zcmp and zmore are OUT_OF_SCOPE, not missing: the REFERENCE leaves both links dangling.
file_cmds/CMakeLists.txt:96 links usr/bin/zcmp to `zdiff`, but zdiff installs to
libexec/darling/**bin**, and a value with no `../..` resolves next to the link; line 97 links
usr/bin/zmore to `zless`, which no install() in the tree provides. Two lines above them,
`InstallSymlink(../sbin/chown libexec/darling/usr/bin/chgrp)` shows the spelling that does
cross directories, so it is a slip, and fixing it belongs upstream.

zprint and ioclasscount then went in through buck-port.py --binaries, taking UNMAPPED to 13.
Both needed <Kernel/IOKit/IOKitDebug.h>, which is the SDK spelling the same header twice:
Kernel.framework/Versions/A/Headers/IOKit is a symlink to IOKit.framework/Headers, so
<Kernel/IOKit/X.h> and <IOKit/X.h> are one file. gen-sdk-header-roots.py already had an
ALIASES table for exactly this (Kernel/sys/decmpfs.h was there for copyfile); the IOKit
entry joins it.

buck-port.py was LYING about both of them first, and the bug is worth knowing about because
it makes the tool's verdict untrustworthy in the most common case. Inside resolve(), the
loop that adds framework roots was written `for label in fwmap[fw]`, rebinding the
function's own `label` parameter. From the second round on it therefore built the framework
HEADER ROOT it had just added rather than the target being ported. A header root always
builds, so the run reported "ok zprint [CoreFoundation]" while zprint was still failing on
the very header that round was meant to fix. Any target that needed exactly one framework
added was reported ok. Fixed by renaming the loop variable.

zlog was in the same batch and did NOT link, for a reason worth writing down because it is
not a zlog problem: it wants _mach_zone_get_zlog_zones and _mach_zone_get_btlog_records,
which are `#ifdef PRIVATE` routines in xnu/osfmk/mach/mach_host.defs, and this port's
libsyscall ksmig targets run mig WITHOUT -DPRIVATE or -DLIBSYSCALL_INTERFACE while the
reference passes both. The generated stub is the proof: it carries every UNGUARDED routine
(mach_zone_info, mach_zone_info_for_zone, mach_memory_info) and none of the guarded ones
(mach_zone_force_gc, mach_zone_info_for_largest_zone, host_get_atm_diagnostic_flag,
host_get_multiuser_config_flags, host_check_multiuser_mode). So libsystem_kernel was missing
a slice of its exported surface relative to the reference, and zlog was simply the first
target to notice.

That is now fixed, and the fix is worth reading as a general lesson: MIG RUNS THE C
PREPROCESSOR OVER THE .defs, so a -D the reference passes is not decoration, it decides
which routines exist. scripts/gen-mig-from-ninja.py emitted the suffixes and the outputs
from each build-mig edge but silently dropped that edge's DEFINES, so all 56 libsyscall
mig targets ran without the five its directory adds (PRIVATE=1, LIBSYSCALL_INTERFACE=1 on
one of the three passes only, IOKIT=1, IOKIT_ALL_IPC=1, __DARWIN_C_LEVEL=20150101). The
generator now extracts them per edge and emits the DIFFERENCE against what //darwin:sdk_env
already exports, reading that list out of darwin/BUCK rather than restating it. The failure
mode this closes is the nastiest kind: nothing errors, a symbol simply is not there, and the
first program to want it fails to link a long way from the cause.

Two details found on the way. The flags had to be SPLICED into the committed blocks rather
than regenerated, because buck-split-pins.py has since rewritten their defs to labels and
changed out_base -- a generator you can no longer run end to end is only half a generator,
and that is worth fixing before the reference graph goes away. And the extraction needs
shlex, not split(): the emulation directory passes
-DEMULATED_VERSION="Darwin Kernel Version 23.4.0", which a whitespace split turns into five
broken flags. Any define whose value carries whitespace or a quote is now WARNED about
rather than trusted, because how many levels of quoting survive cmake to ninja to the shell
is not something to guess at.

libsystem_kernel went from exporting two mach_zone routines to six; buck-test.sh asserts all
six by name so the flags cannot quietly fall off again.

darling-coredump then took UNMAPPED to 12, and it is the interesting one because it is a
HOST tool: a Linux program that reads Mach-O structures. The reference gives it
-I src/startup/mldr/include, which turns out to be a hand-curated SHIM rather than an
include path. Fourteen of its entries are symlinks into the SDK; the other four are REAL
files, and they are real precisely so they can be EMPTY -- stubs for sys/_types.h,
i386/_types.h, mach/i386/vm_param.h and mach/machine/thread_status.h, plus a single
__darwin_natural_t typedef. Without them, including <mach-o/loader.h> from a host compile
drags Darwin's type headers in on top of glibc's. So a host tool does not get "the SDK
minus some of it"; it gets a deliberately tiny Darwin surface with the collisions stubbed
out.

That is now two roots: //src/startup:mldr_shim_headers (the four real files, named rather
than globbed because a glob would also pick up the farm's symlinks, which dangle in a
working copy) and //buck-src:mldr_include, whose header_map is built by INDEXING SDK_ROOT
with the paths the farm exposes rather than by writing 47 values out again. A path that
vanishes from the SDK then fails there with a missing key instead of silently resolving
somewhere else. cc_binary already had link_cxx, which this target needs: main.cpp uses
std::filesystem and the reference links it with CXX_EXECUTABLE_LINKER.

The other four host tools (bsdln, elfdep, getuuid, wrapgen) are unblocked by the same
understanding but are NOT install entries -- nothing in the prefix needs them, and the port
does not run them -- so they stay low priority. elfdep and getuuid want
src/buildtools/include plus cctools-port/cctools/include, bsdln links bsd, wrapgen links dl.

The dtrace cone then took UNMAPPED from 11 to 6 in one go: three static libraries (ctf, elf,
dwarf), libdtrace.dylib, and dtrace, lockstat, plockstat and usdtheadergen. They only ever
build together, so they landed together. libdtrace's lex and yacc output is COMMITTED in the
pin (gen/libdtrace/lex.yy.c and y.tab.c) rather than generated, so no bison or flex target
was needed.

The thing that blocked it was not dtrace at all. Every dtrace include root stages the pin
ROOT, because the reference puts ${CMAKE_CURRENT_SOURCE_DIR} first on the include path, and
the generator writes that as a catch-all `dtrace/**/*` glob. The pin ships two DANGLING
symlinks upstream, DTTk/Bin/dvmstat and DTTk/Bin/intbycpu.d, both pointing at siblings it
does not carry, and buck2 refuses to glob a link that resolves to nothing: it fails the
whole package with "File not found: root//buck-src/dtrace/DTTk/dvmstat. Included in
buck-src/BUCK but does not exist". It had been latent for as long as those blocks existed,
because nothing had ever built a dtrace target. gen-buck-from-ninja.py now carries a
GLOB_EXCLUDE table (DTTk is .d scripts, docs and man pages, with zero headers) and emits the
exclusion itself, so a regenerated block cannot reintroduce it. Worth remembering the
shape: a whole-tree glob over a vendored pin is one bad symlink away from failing a package
that has nothing to do with it.

SecurityTokend and its xtrace stub then took UNMAPPED to 4, and they exposed two bugs one
level down.

The first: `has_headers()` in gen-buck-from-ninja.py decided whether an include dir gets
listed in a merged root's `include_subdirs`, and it counted `.defs` as a header while the
glob it guards matches only `*.h`, `**/*.h` and `*.c`. SecurityTokend/mig holds exactly
tokend.defs and a makefile, because its every real header is MIG output, so the dir was
listed, staged EMPTY, and the build failed with "The path `mig` does not exist in the
artifact" -- an error that says nothing about why. The predicate now asks what it should
have asked all along: would the emitted glob match anything. Keep the two in step.

The second: a MIG protocol's two ends are usually two different targets, and mig_gen could
only export one set of sources. SecurityTokend implements tokend and links tokendServer.cpp
while libsecurity_tokend_client is the caller and must link only tokendClient.cpp; putting
both in compile_srcs gives each end the other's stub. mig_gen grew a `[server]` subtarget
alongside the existing `[xtrace]` one, which was already there for the same reason a level
out.

securityd then landed, taking UNMAPPED to 3. It needed three things, each a different shape
of the same problem, that a MIG protocol's generated output has to reach the right consumer:
its own `<self.h>` (gen_srcs from securitydmig_self), the `securityd_client/` include
directory (which the ucsp and ucspNotify mig targets already synthesize through
`alias_links`, so they just had to be named as deps), and selfServer.cpp as well as
selfUser.cpp, because securityd is both ends of self.defs.

Underneath it, libsecurityd_server.a was EMPTY -- 8 bytes -- because its only two sources,
ucspServer.cpp and ucspNotifyReceiver.cpp, are MIG output that nothing had wired. Nothing
complained: ar writes a valid empty archive and buck2 called the target built. The failure
came out at securityd's link as `ld: file too small (length=8)`, naming an archive that
looked unrelated. libsecurityd_ucspc.a still has the same hole; see the queue.

secd closed the Security cone, taking UNMAPPED to 2, and it took two more steps. Its
undefined symbols (_SASSessionStateForUser, _kSA_SessionStateChangedNotification) were not a
Security problem at all: they live in the `login` PRIVATE FRAMEWORK, which had a login_obj
but no dylib block, so nothing built the library secd links. And libsecurityd_ucspc.a was
the second EMPTY archive: its single source is mig/ucspClientC.c, which cmake makes with
create_symlink from ucspClient.cpp -- one translation unit compiled as C++ for
libsecurityd_client and as C for libsecurityd_ucspc, so neither consumer can take the
other's spelling. mig_gen already had `alias_links` to create such a name; it grew an
`[alias]` subtarget to export them as sources, the third of the same shape after `[xtrace]`
and `[server]`.

Porting the `login` framework also broke every runtime check, and the way it broke is worth
knowing. binary_index() in gen-install-from-manifests.py merged executables and dylibs into
ONE name-to-label map, and `login` is both: system_cmds' login program, which installs to
usr/bin/login, and a private framework whose dylib_name is also "login". Whichever os.walk()
reached first won. Porting the framework therefore repointed usr/bin/login at a DYLIB, the
prefix shipped a shared library where a program belonged, and all three runtime checks failed
with nothing saying why. The index is split by kind now, and an install entry asks for the
kind it wants -- it always knew, since cmake records TYPE EXECUTABLE.

cc_static_lib now FAILS on a zero-member archive rather than writing one. That is the real
lesson here: an empty archive is silent, ar writes a valid 8-byte file, buck2 calls the
target built, and the mistake surfaces at a distant link naming a library nobody was working
on. Both cases had the same cause, an archive whose every source is generated and whose
generated sources were never wired. A survey of the 126 archives found no legitimate empty
one, so the guard costs nothing.

launchservicesd took UNMAPPED to 1, and what blocked it was not launchservicesd. Its
undefined symbols were FSEventStreamCreate and the kUTType* constants, which live in
CoreServices SUB-FRAMEWORKS, and the reference links only the CoreServices umbrella because
that umbrella reexports all nine of them (FSEvents, LaunchServices, AE, CarbonCore,
DictionaryServices, Metadata, SearchKit, SharedFileList, OSServices) alongside CFNetwork and
CoreFoundation. This port's CoreServices reexported TWO. reexports_of() resolves each
-Wl,-reexport_library path through the final registry and drops what it cannot find, so the
nine were silently lost when CoreServices was generated BEFORE the sub-framework dylibs were
ported, and nothing has regenerated it since. Regenerating restored all eleven.

That is a general hazard, not a one-off: a generated block is a SNAPSHOT of what the
registry knew at the time, so a target generated early can be permanently poorer than the
reference without anything noticing. Anything that resolves through a registry (reexports,
siblings, upward links) has the same exposure.

hdiutil closed it. **UNMAPPED is 0: every install entry of the cli component maps to a
target that builds.** It needed the wrap_elf mechanism, which is now two rules: elf_wrapper
runs wrapgen over the HOST libfuse to generate forwarding stubs, and the existing generated
fuse_obj/fuse_dylib blocks compile them into /usr/lib/native/libfuse.dylib with 176 exports.
Worth noting the generated cone was already there waiting for its source, so the work was
wiring rather than writing; check for an existing block before adding one.

elf_wrapper is the ONE rule in this port whose output depends on a file outside the build
graph, because the stub must mirror whatever the host actually provides. The host lib dir
comes from [darling] elf_lib_dirs in .buckconfig.local, written by buck-setup.sh from
pkg-config, alongside ld64_dir and clang_resource_dir.

### Where stage 1 landed

The cli PREFIX is complete. Every artifact the reference installs, the port builds.

The link graph is a different measure and needs care, because buck-coverage.py reports 88
percent (770/871) and that number is misleading. It matches a link edge to a target of the
same NAME, and of the 106 it calls missing, 92 are not: curl is ported as `curlexe`, and
clang, git, bison, Rez and the rest of the Carbon resource tools are deliberately replaced
by xcselect SHIMS, which is what the reference INSTALLS for them. Nine genuinely unported
in-scope edges remain (bsdln, elfdep, getuuid, csparser.bundle, lzfse, ping, vifs,
libbind9_isccc.a, libopendirectory_internal.a) and none is installed by cli, which is why
UNMAPPED reaches 0 without them. Five more are documented out of scope. buck-coverage.py
now resolves exe_name aliases, so it reports the honest number: **862 of 871, 98 percent**,
with those 9 gaps visible instead of buried among 106.

### Stage 2: the src/native ELF wrappers (done)

Sixteen host libraries the gui component reaches through libelfloader, one wrap_elf() each:
FreeType, jpeg, png, tiff, gif, EGL, fontconfig, X11, Xext, XRandR, Xcursor, xkbfile, cairo,
dbus, GL and GLU. They are the natural first stock increment because they share one
mechanism, the one hdiutil already proved, and nothing else depends on them.

Written as a TABLE in src/native/BUCK rather than sixteen generated blocks. They differ only
in name, SONAME and (for GL and GLU) install directory, and the generator cannot be driven
by name here anyway because of the X11 collision above.

The one thing that needed real care is where the host libraries come from. buck-setup.sh
resolves each SONAME against the dev shell's OWN -L directories (NIX_LDFLAGS) and falls back
to pkg-config. Not the other way round, and not by globbing /nix/store: giflib ships no .pc
file at all, and several of these libraries have more than one version in the store, where a
stub generated against the wrong one would export the wrong symbols silently.

Verified by export count, not just by linking: an elf_wrapper whose dlopen failed still
produces a valid EMPTY dylib, so the suite asserts each stub forwards a plausible number of
symbols (GL 3470, X11 1230, cairo 473, gif 61).

### Stage 2: the GUI frameworks (138 of 144)

buck-port.py handled them almost uniformly: 133 of 144 in one batch, then 4 more once a
cross-package include root was registered. Stock coverage went 63 percent to 73 percent,
dylibs 243 to 383. cli is untouched at 862/871.

Three things the batch taught.

The generator needed ONE new cross-package root: cocotron's QuartzCore headers, which
IconServices, ImageKit, QuartzComposer and SceneKit reach from //darwin/frameworks while
cocotron is an unsplit pin in //buck-src. The refusal was correct and loud ("include dir
belongs to package //buck-src, but this block goes ..."), which is the behaviour to want --
a glob written into the consuming package would have staged nothing and failed much later.

SIX are held back, and not for an ordering reason. AVKit, CoreVideo, HIServices, ImageIO,
OpenGL and Quartz compile but do not link: they want CGDisplayCopyDisplayMode and friends
from COCOTRON's CoreGraphics, which the reference links as
src/external/cocotron/CoreGraphics/CoreGraphics. That whole cone (cocotron CoreGraphics,
CoreText, Onyx2D, QuartzCore) is unported and belongs to the src/external group, so those
six unblock when it lands and not before. Their blocks are REMOVED rather than left broken.

And `lp` is not a dylib at all -- buck-port reported "Unknown target lp_dylib" because the
coverage missing-list entry is an executable that happens to sit under src/frameworks.
A name in the missing list is not a promise about what kind of thing it is.

### Stage 2: the cocotron cone (SOLVED: a dropped -include)

Onyx2D, CoreGraphics, CoreText, QuartzCore, CoreData, AppKit and both cocotron X11 backends
are in, and with them the six frameworks that waited on the cone (AVKit, CoreVideo,
HIServices, ImageIO, OpenGL, Quartz) and cupsd. One line of gen-buck-from-ninja.py.

**The cause.** The reference force-includes four headers into every cocotron compile:

    -include math.h -include stdlib.h
    -include CoreFoundation/CoreFoundation.h -include Foundation/Foundation.h

`own_flags_of()` keeps a `-include` whose argument is a bare NAME (it resolves through the
include path) and turns an absolute one into a prefix_headers FILE. Anything else it
recorded as unresolved and DROPPED, and the test for "bare name" was `"/" not in arg`. A
framework-style spelling has a slash, so `Foundation/Foundation.h` was dropped -- and that
umbrella is where those headers get NSMutableArray and every other Foundation type they use
without importing anything that declares them. Hence CoreData's lone
"unknown type name 'NSMutableArray'" with no missing header to point at. The test is now
"is it absolute", which is the property that actually decides whether the compiler resolves
it through the include path.

**Two earlier diagnoses here were wrong and are corrected.** The first was an error cascade
(disproved with -ferror-limit=0). The second was the claim, written in this file, that "the
flags are identical apart from -B, which is link-time" -- the four -include flags were right
there in FLAGS. Reading the reference's compile line ALL THE WAY THROUGH is what closed a
cone that had been parked for several iterations; comparing a summary of it is what kept it
parked. Seeding framework roots by hand never converged because no framework root was
missing.

**Scope, measured rather than assumed.** Exactly 10 cmake targets in the stock graph
force-include a relative header with a slash: the 7 cocotron ones, plus vim, libvterm and
xxd, which use `-include ../gen/vim_dynamic_config.h`. That one needs different handling:
`../` resolves against the include dir's PARENT, and a staged root has no parent, so as a
flag it fails outright ("file not found") where before it was silently absent. It is now
resolved the way the compiler would -- against the unit's own include dirs in order -- and
emitted as a prefix_headers FILE, since prefix_headers passes the artifact path straight to
-include and the staged layout stops mattering. vim needs it: without it every dll_* macro
for dynamic ruby is undefined. xxd, which builds and installs, was verified unchanged
before and after.

**Then a snapshot sweep.** A generated block records what the registry knew when it was
written, so 13 blocks still carried "not ported yet" TODOs naming cone members --
ApplicationServices listed five. cupsd reaches CGBitmapContextCreate through
ApplicationServices' reexports, so it stayed broken until that block was regenerated, not
because anything was wrong with cupsd. After a fix that unblocks a cone, grep the tree for
TODOs naming what just landed; it is a cheap, bounded sweep.

Also worth keeping: cocotron's Cocoa exports NOTHING, and that is faithful. Its single
source is an umbrella that only imports headers, and the reference emits no
reexport_library flags for it either. A zero-export dylib is usually the empty-artifact
trap; this one is not.

**Five blocks were REMOVED rather than left broken**: DBusKit, iokitd, bsdln, getuuid and
elfdep all generated, none linked. Coverage counts a block that exists, so leaving them
would have reported 1341/1359 when the truth is 1336. getuuid and elfdep are the
interesting pair: they are HOST tools that read Mach-O out of the build tree, and the
generator resolves their <mach/...> includes to a framework root, which a host compile has
no way to consume. src/bsdln/BUCK and src/buildtools/BUCK are now comment-only, kept so
those directories keep their own package boundary instead of folding into a parent's globs.

### Stage 2: cups (57 of 58)

Two dylibs, four archives, 51 executables. The whole of cups except cupsd, which wants
CGBitmapContextCreate from the parked cocotron CoreGraphics, exactly like the six held-back
frameworks.

Two things worth carrying forward.

A real generator bug: cmake HEX-ESCAPES THE DOT in ninja rule names, and ninja_rule_name()
did not. admin.cgi links through `C_EXECUTABLE_LINKER__admin.2ecgi_`, crt1.10.6 through
`crt1.2e10.2e6`; the dot was in the function's safe set, so every dotted target failed to
match its own rule and the generator reported "no executable link edge" for an edge sitting
right there in the graph. All five cups CGI programs died on that. No legitimate rule name
carries a raw dot, so escaping it is strictly more correct.

And a mistake of mine worth not repeating: I split cups into dylibs and executables by
testing for SHARED_LIBRARY_LINKER and treating everything else as an executable, which put
four STATIC_LIBRARY_LINKER edges (libcups_cgi.a and friends) into the binary batch. They
failed as "Unknown target", and so did the twelve binaries that link them -- twelve
undefined-symbol failures with one cause, which looked far worse than it was. Classify by
the rule name properly: dylib, archive, executable, module.

### Stage 2: ruby (92 of 92), and what splitting a pin costs

The whole ruby group: the Ruby framework dylib, 90 `.bundle` loadable modules and the ruby
executable. Stock coverage 77% -> 85%.

**Loadable modules are `--dylibs`.** A `.bundle` or a `.so` extension module is a plain
SHARED_LIBRARY_LINKER edge that happens to carry `-Wl,-bundle`, and the generator copies
that off the link edge like any other flag; zsh's 35 modules have been declared that way
since they landed (`zmod_zutil_dylib` in buck-src/zsh/BUCK). There is no separate rule and
no separate mode to look for.

**`#include __FILE__` needs `-iquote.`** ruby's debug_counter.h is an X-macro file that
re-includes ITSELF that way, and the trick only works if `__FILE__` is a path the compiler
can reopen. cmake compiles from a store path, so `__FILE__` is absolute and resolves; buck2
compiles project-relative with cwd at the project root, so `__FILE__` is
`buck-src/ruby/ruby/debug_counter.h` and the quoted-include search (which starts at the
INCLUDER's directory, never the cwd) cannot find it. `cflag:-iquote.` in extra-deps.json
fixes all 18 affected files and is strictly narrower than what the reference does, since
`-iquote` is consulted only for `#include "..."`. Patching the pin would have worked too,
but it would have rebuilt darling-src and both ninja graphs, moving the baseline the port
is measured against.

**Splitting a pin is a four-step sequence**, and buck-src/BUCK is at 56k lines -- already
well past the 33k that the split doc calls more memory than the machine has on the
Nix-lowered path -- so a group of this size has no business going in there:

1. add the pin to `buck/generated/split-pins.txt`;
2. `gen-sdk-header-roots.py --framework-roots . mach i386 machine libkern sys security_libDER`
   (the plain form writes `sdk_headers.bzl`; ruby changed nothing there because it exports
   no `usr/include` namespace, only a framework);
3. `buck-exports.py` then `buck-fix-loads.py`;
4. a `CROSS_PACKAGE_ROOTS` entry for any include path another package still reaches into.

Step 4 is the one that bites, because **buck2 does not error on a glob that reaches into a
subpackage -- it silently matches nothing.** vim's xxd globbed
`ruby/darling/include/ruby/**` from //buck-src; the moment buck-src/ruby/BUCK existed that
root staged ZERO files, and nothing failed, because xxd compiles `-DDYNAMIC_RUBY` and
resolves ruby through dlopen at runtime without ever opening one of those headers. It built,
installed and passed the suite with a dead include path. The root now lives in the ruby
package and xxd names it by label (46 files staged). Assume every glob that mentions a
newly split pin is silently empty and check each one; a passing build proves nothing here.

### Stage 2: perl and python, and four ways a name can be wrong

perl is 117 targets (two interpreters, 109 modules, an archive, three executables) and
python 56. Almost none of the work was in the sources; it was in four distinct
name-resolution faults, each of which produced a large pile of failures with one cause.

**The registry was keyed by artifact BASENAME, and basenames collide.** perl 5.18 and 5.28
each build a `libperl.dylib`, so `final_registry()` held whichever it scanned last and all
54 of 5.18's modules linked against 5.28's interpreter, failing on
`_Perl_xs_apiversion_bootcheck`. The dylib and binary generators now emit
`# buck-registry: <ninja output path> = <target>` and `siblings_of()` resolves by full path
before falling back to the basename, so blocks written before the pragma existed are
unaffected. 57 dylib basenames in the stock graph are built by more than one edge; besides
the 55 perl ones they are `CoreAudio` (two), `X11` (a THIRD one, in cocotron AppKit,
distinct from the src/native wrap_elf stub and CoreGraphics' backend) and `datetime.so`
(zsh's is ported, python's is not).

**A linker flag can name something the build PRODUCES.** python's extension modules link
none of the libraries that define the Py* symbols; they resolve them through
`-Wl,-bundle_loader,<the python2.7 executable>`. `link_flag_files()` classified that as
"file is not a source of this package" and dropped it, so all 53 failed on `_PyErr_Format`
and several hundred others. It now resolves a build-output path through the registry to a
LABEL. And once the loader was wired they still failed, on
`/System/Library/Frameworks/Python.framework/Versions/2.7/Python`: ld64 also opens what the
LOADER links, and the block had no dep from which to derive that `-dylib_file` mapping.
`bundle_loader_dylibs()` adds it to `deps` rather than `siblings` -- deps contribute the
mapping without putting the library on the link line, which matches the reference, where
Python is not an input of the zlib.so edge. Restricted to edges carrying `-bundle_loader`
on purpose: every ordinary dylib derives its mappings from its own deps.

**A cmake target and an object library can want the same buck name.** cmake gives
python27exe a `dummy.c` ("this file is a dummy source to avoid having only object library
sources for a target") and puts the real python.c in an object library called
`python27exe_obj`. The port appends `_obj` to a target name unless it already ends in one,
so both collapsed to `:python27exe_obj`, the binary listed it twice, python.c was never
compiled and the link failed on `_main` -- with nothing in the block to suggest a source
had gone missing. `obj_base()` now disambiguates to `<lib>_own_obj`, and `inc_prefix()`
applies the same rule to include-root names, which otherwise collide as "Attempted to
register target ... twice". Both are identity transforms for every non-colliding target.

**And one that was mine.** A ninja rule is `<KIND>__<cmake target>_`, and I read the target
with `rule.split("__")[1]`. Every python module whose name starts with an underscore is
`py27__ctypes`, `py27__io`, `py27__socket` and so on, so that split returned `py27` for 23
of them. They were never attempted; the batch reported 23 identical "Unknown target
`py27_dylib`" lines, which reads like one broken target rather than 23 missing ones.
Partition on the FIRST `__` and strip one trailing underscore.

Splitting a pin also needs BOTH SDK maps regenerated, not just the framework one: ruby
contributes no `usr/include` namespace so `sdk_headers.bzl` was unchanged, but python
contributes `python2.7/` and until that map named the headers by label `//buck-src` failed
to parse with "does not exist as a member of package". Unlike the silent empty glob, this
one is a hard error.

**The cross-package guard covered one of its two loops.** gen-buck-from-ninja.py refuses to
write a header root for a directory another package owns -- that is the "add it to
CROSS_PACKAGE_ROOTS" error -- but only in the loop that emits a SINGLE root. The loop that
emits a sibling GROUP had no such check, and a group is the shape that hides it best: all
24 pyobjc modules got a root over `python/2.7/Python-2.7.16` written into
`//buck-src/pyobjc`, the generator reported success, and the failure surfaced much later as
"The path `Include` does not exist in the artifact", naming the staged tree rather than the
boundary that emptied it. Both loops check now. Two entries map python's tree, `.` and
`Include`, to the SAME root, because that root stages them as sibling include_subdirs of
one tree and two roots would be two trees with an -I order the reference does not have.

**A shared SOURCE crosses packages too.** cmake/versioner.cmake builds every project's
version-dispatch wrapper from one file, `perl/versioner/versioner.c`, so python's `python`
wrapper compiles perl's source. `CROSS_PACKAGE_SRCS` is the file-level analogue of
CROSS_PACKAGE_ROOTS; perl exports the source and the template, and python's own
`configure_file` supplies its versions.h (`versioner(python "2.7" "2.7")` -> NVERSIONS 1).
Both wrappers need that configure_file at all because cmake writes versions.h at CONFIGURE
time, so no ninja edge produces it -- the same shape as the 159 cert links.

**Two dangling SDK links, left from the darwin/ + linux/ reorg.** python's dbm module gets
`-I<sdk>/usr/include/BerkeleyDB`, whose db.h and db_cxx.h still point at
`src/external/BerkeleyDB` from before the pins moved, exactly like the dnsinfo.h case
already noted in that package's BUCK. The real headers are in the pin and berkeley_db
already stages them, so the include path maps to that existing root.

**Do not edit a BUCK file while a batch is running.** Adding python's configure_file
mid-run made six pyobjc modules fail with "Variable `configure_file` not found" -- the load
had not been fixed yet -- which looks like a rule problem and is only a race.

**And stale wait-loops from earlier iterations are not inert.** buck-test.sh reported "the
kernel's final pass is not two-level" once; llvm-objdump showed TWOLEVEL plainly on the
same artifact, and the suite passed 138/138 as soon as three leftover
`until ! pgrep -f buck-port.py; do sleep; done` shells -- each of which then ran its own
buck2 build -- were killed. Add that to the list of causes to check when a check fails once
and cannot be reproduced.

### Stage 2: CoreAudio, Metal, and the last two archives

Every remaining link edge except five. Stock 1336 -> 1354 of 1359 (99%), archives and
loadable modules both 100%, cli 866 -> 868. Three things were worth the time.

**Five more wrap_elf stubs.** src/CoreAudio wraps ffmpeg's four libraries and pulseaudio
exactly as src/native wraps X11 and cairo, so src/CoreAudio/BUCK gets the same table +
three comprehensions + `buck-registry:` pragmas, their SONAMEs join elf_sonames in
buck-setup.sh, and buck-test.sh checks them by EXPORT COUNT (23 to 628 each) because a
failed dlopen still yields a valid empty dylib. The drift check that keeps a pragma list
honest against its table is now a function, `check_wrap_table`, used for both.

**A framework can include ITSELF.** src/CoreAudio's CMakeLists calls
`remove_sdk_framework()` on AudioToolbox, AudioUnit and CoreAudio and supplies its own
headers, so `//src/CoreAudio` is the only package where those roots exist. buck-port.py's
FRAMEWORK_PACKAGES did not list it, and all three failed with "no framework root for
CoreAudio" -- a shape the SDK packages never have to express.

**buck2's glob() does not traverse a symlinked DIRECTORY.** CoreAudioComponent and
AFAVFormatComponent reach AUPublic, AFPublic and PublicUtility through links into
CoreAudioUtilityClasses; the roots staged empty and the failure read "The path `Utility`
does not exist in the artifact", naming the staged tree rather than the link. Include dirs
are now resolved with realpath before a root is written (`real_include_dir`). Measured
first: of 595 distinct include dirs in the stock graph exactly 6 are reached through a
directory symlink, all of them these, so the change is churn-free everywhere else. Note
this is the SECOND way a glob silently stages nothing -- the first was crossing a package
boundary. Both now fail loudly instead.

**The five that remain, and why.** DBusKit (no framework root for itself), iokitd (wants a
MIG-generated powermanagementServer.h), bsdln (link failure), and the pair getuuid/elfdep.
That pair is the interesting one and the earlier note about it was incomplete: their blocks
are correct -- native_cc toolchain, cctools include root, the right sources -- and the
compile dies inside cctools' own mach/machine.h on `<mach/machine/vm_types.h>`. That header
exists in the pins ONLY as
cctools-port/cctools/include/foreign/mach/machine/vm_types.h, and NOTHING in the reference
build adds `-Iforeign` to any compile. So the reference resolves it by some route not
visible in INCLUDES, and finding that route is the next step rather than adding an include
dir on a guess. Their blocks are removed, so coverage counts them as the gaps they are.

### The STOCK SWITCH (done)

`result-graph-ref` points at `.#darling-graph-stock` and everything is measured against it.
The symlink is gitignored, so what actually makes the switch reproducible is committed:
every script that tells you how to build the graph now says `.#darling-graph-stock`
(gen-buck-from-ninja.py, buck-port.py, gen-install-from-manifests.py, buck/README.md),
buck/prefix/BUCK is regenerated from the stock manifests, and buck-test.sh's two thresholds
move to stock numbers -- coverage floor 1354 of 1359 (it read 868 of 871 on cli) and the
UNMAPPED ceiling 0 -> 2.

**UNMAPPED is 2, not the 523 this file predicted when stock was first sized.** The porting
work closed the rest, and the two that remain are exactly the removed blocks that stock
INSTALLS: `usr/sbin/iokitd` and DBusKit.framework. bsdln, getuuid and elfdep are build
tools, so their absence costs nothing in the prefix. The ceiling goes back to 0 when those
two link.

The prefix went from 2275 to 4194 lines: 1308 targets, 2039 source files, 176 symlinks,
33986 files and 596 links staged.

One step is easy to miss. `gen-install-from-manifests.py --write` writes export_file
targets for source files into the packages it knows about, but the ones that belong to the
PINS come from `buck-exports.py`, which is a separate script. Without it the prefix names
labels nothing defines and the build stops at the first one (`cups_cups_man_lpmove.8`).
Run buck-exports.py and buck-fix-loads.py after any prefix regeneration.

Also worth knowing when spot-checking a staged prefix by hand: the tree is rooted at
`libexec/darling/`, AppKit installs under `Versions/C` rather than `Versions/A` (the Cocoa
convention), and 598 of the symlinks are ABSOLUTE guest paths like
`/System/Library/Frameworks/Ruby.framework/...` which resolve only inside the container. A
plain `test -e` on the host follows those and reports a file that is present as missing.

**Verified on the stock prefix, not inferred:** buck-test.sh 142/142; the container boots
and runs bash (buck-bash-check.sh); tests/darling-smoke.nix stages 2-7 pass 31/31
(buck-smoke-check.sh); and guest nix built AND ran bash inside the buck2-built Darling
(buck-nix-bash-check.sh), which is the campaign's keystone milestone and it survives the
switch.

### Stage 3: the `all` component (the nine real targets are DONE)

`.#darling-graph-all` now exists in flake.nix. See the sizing table below for the numbers;
the short version is that `all` is only 18 raw link edges bigger than stock, the `webkit`
component contributes NOTHING to the graph at all, and nine of the eighteen are dev-stub
frameworks the coverage metric cannot see (the basename-collision caveat, also below).

ALL NINE of the real new targets are in: bmalloc, libWTF.a, libgnutar.a, libmbmalloc.dylib,
ash, gnutar, JavaScriptCore, jsc and libMachExceptions_xtrace_mig.dylib. The JavaScriptCore
dylib is 43.7MB, NOUNDEFS and TWOLEVEL, with 10526 exported symbols. With the last five
edges closed as well (below), `all` measures 1368 of 1368.

WTF needed a MIG target first. Its MachExceptions.defs generates MachExceptionsServer.h,
which both libWTF.a and the xtrace stub compile against, and
`gen-mig-from-ninja.py "WTF/wtf/mac"` emits it exactly. Note the two extra-deps forms are
NOT interchangeable: `//buck-src:mig_MachExceptions` puts the generated headers on the
include path, and `gen://buck-src:mig_MachExceptions` makes the target COMPILE the
generated sources. WTF needs both.

**And `gen://` is necessary but NOT sufficient: a mig_gen exports only what its
`compile_srcs` names.** With that attribute unset the target exports zero sources, so the
`gen://` entry is wired, the block looks right, WTF builds, libWTF.a is produced -- and
`MachExceptionsServer.c.o` is simply not in it. It surfaces one link later as
`_mach_exc_server` undefined, referenced from `libWTF.a(Signals.cpp.o)`, when
JavaScriptCore links. gen-mig-from-ninja.py fills compile_srcs in automatically only for
MULTIARCH subsystems (the per-arch User.c); everything else goes in its
EXTRA_COMPILE_SRCS map, which now carries this subsystem's two halves. To check a mig
wiring without a full link: `llvm-ar t <the archive> | grep -i <subsystem>`.

That map also had a latent bug worth knowing about, since Starlark will not warn you: it
emitted one `compile_srcs = [...]` block PER entry, and a repeated keyword argument keeps
only the last, so a two-entry map would have exported one source and looked fine. It emits
a single merged list now.

**JavaScriptCore hung buck2, and the cause was a CYCLIC SYMLINK.**
`JavaScriptCore/DerivedSources/JavaScriptCore/JavaScriptCore` is a link to `../..`, which
resolves to `JavaScriptCore` itself -- its own ancestor -- so the tree descends forever.
It is now in GLOB_EXCLUDE and JavaScriptCore builds.

The symptom looked nothing like a bad symlink, which is why it is worth writing down. buck2
PARSED the package fine and ANALYSED the target fine (`buck2 audit providers` succeeded);
what wedged was EXECUTING the symlinked_dir action that stages the header root. In that
state the daemon sits at 0% CPU with all 32 threads in futex_do_wait, the forkserver
sleeping, no clang processes, nothing written under buck-out, and the client repeating
"Waiting on buck2 daemon ... CPU: 0% IO: none" while RSS climbs to 2.4GiB.

The bisect that found it, in order, each step cheap and each one killing a hypothesis:

1. A trivial target still built, so the daemon was healthy and the problem was JSC-specific.
2. A probe with 200 of the 1088 sources hung too -- so NOT size. (607-source Automator_obj
   builds fine, which was the first hint.)
3. A probe with ONE source hung -- so not the sources at all, it is in the deps.
4. Its two header roots built separately: libcxxabi fine, JavaScriptCore's own hung. One
   target, isolated.
5. `buck2 audit providers` on that root succeeded -- so analysis is fine and it is the
   ACTION.
6. An action that stages files and blocks at 0% CPU is waiting on the filesystem, so look
   at what is in the tree: `find -type l` showed the cycle immediately.

Two things generalise. Any glob-and-stage of a third-party tree can hit this, so
`find <tree> -type l` and check for a link to an ancestor is worth doing BEFORE debugging
buck2. And glob_excludes() now emits both `<bad>/**` and `<bad>`: the first covers a
directory's contents, the second the entry itself, which is what matters when the bad
thing is a file or a symlink -- buck2's glob does not traverse a symlinked directory, so a
cyclic link is matched as ONE entry that `/**` never touches.

**The hang then came back, and the reason is worth more than the symlink itself: a
GENERATOR fix only reaches the blocks you REGENERATE.** Three blocks glob the
JavaScriptCore tree -- `JavaScriptCore`, `low_level_interpreter_i386` and
`low_level_interpreter_x86_64` -- and only the first had been rewritten since
GLOB_EXCLUDE was added. The other two still carried the cyclic path in their glob, so the
dylib, which links all three, wedged in exactly the same way under a different target
name. `grep -rn '"<tree>/\*\*/\*"' --include=BUCK .` lists every block that stages a tree;
after changing what the generator emits for one, check that list rather than the target
you were debugging.

A scan of the WHOLE of buck-src for links resolving to their own ancestor finds exactly
this one, so no other pin carries the same trap:

```
python3 -c 'import os
for r,ds,fs in os.walk("buck-src"):
  for n in ds+fs:
    p=os.path.join(r,n)
    if os.path.islink(p):
      d,t=os.path.realpath(os.path.dirname(p)),os.path.realpath(p)
      if d==t or d.startswith(t.rstrip("/")+"/"): print(p,"->",os.readlink(p))'
```

How to tell a hang from a slow build, since this cost most of an iteration: watch
`find buck-out -name '*.o' -newermt '-2 minutes' | wc -l` and the daemon's CURRENT cpu with
`top -b -n 2`. `ps -o %cpu` on the daemon reports its LIFETIME average, which for an
11-hour-old daemon looks like healthy 8% activity no matter what it is doing now.

**Past the hang, JavaScriptCore needed its own framework header namespace, and that
namespace is made of TEXT FILES, not symlinks.** Its cmake defines
`setup_forwarded_headers()`, which at CONFIGURE time writes
`build/private/JavaScriptCore/JSContextPrivate.h` containing the single line
`#include <API/JSContextPrivate.h>`, and puts `build/public` and `build/private` on the
include path. That is how a source inside JavaScriptCore gets to say
`<JavaScriptCore/JSContextPrivate.h>` for a header that lives in `API/` while no
JavaScriptCore framework exists yet. It is the only target in the graph that does this:
`-I/build/build/.../public` appears for JavaScriptCore and nothing else.

Configure time has no counterpart here, so it became a rule: `forwarded_headers` in
buck/rules/codegen.bzl, with `jsc_forwarded_public` and `jsc_forwarded_private` in
buck-src/BUCK wired in through extra-deps.json. The rule READS THE CMAKE LISTS rather than
transcribing them -- 15 public and 609 private entries is too many to keep in sync by
hand -- and 17 of the private ones name a path that does not exist (`DerivedSources/X.h`
without its `JavaScriptCore/` level). The reference writes those broken shims too; a shim
only has to resolve if something includes it.

The wrong answer here, and the one buck-port.py's resolver kept proposing, is
`//buck-src:fw_JavaScriptCore`. That target EXISTS -- the SDK framework farm has a
JavaScriptCore namespace -- so the guess looks plausible and fails anyway, because the SDK
farm carries only the public headers and the missing one is private. Same shape as
CoreAudio: a framework including ITSELF, which the SDK packages never have to express.

MachExceptions_xtrace_mig's block is REMOVED (it failed to link, and its extra-deps entry
is dropped rather than left as a guess that did not work). The mig_MachExceptions target
stays, because WTF compiles its output.

### Stage 2, sized

Measured by pointing result-graph-ref at the stock graph and re-running both tools:

| | cli | stock | all |
|---|---|---|---|
| link edges (counted) | 871 | 1434 | 1452 |
| link edges (raw) | 892 | 1439 | 1457 |
| ported | 868 (99%) | 1434 (100%) | 1452 (100%) |
| install entries | 1160 | 1872 | 1888 |
| UNMAPPED | 0 | 0 | 0 |
| build.ninja lines | 201k | 347k | 363k |

The cli column was measured before the metric keyed by path, so its 871 is a basename
count and is not comparable with the other two. It is kept because the cli graph is the
milestone the port passed through, not a target anyone measures against now.

`.#darling-graph-all` was added to flake.nix to measure this; `all` is
stock + jsc + webkit + cli_extra + cli_dev_gui_stubs.

**`all` is far smaller than the name suggests: 18 raw link edges more than stock.** The
whole of the `webkit` component contributes NOTHING to the graph. Half of the rest is one
cone -- JavaScriptCore with WTF, bmalloc and mbmalloc -- and the remainder is gnutar, ash
and one xtrace MIG dylib.

| group | targets |
|---|---|
| JavaScriptCore, jsc, libWTF.a, libbmalloc.a, libmbmalloc.dylib | 5 |
| libMachExceptions_xtrace_mig.dylib (WTF's xtrace MIG stub) | 1 |
| gnutar, libgnutar.a | 2 |
| ash | 1 |
| dev-stub frameworks (see the caveat below) | 9 |

**The other nine edges were `src/frameworks/dev-stubs/{AppKit,AudioToolbox,Cocoa,CoreData,
CoreGraphics,CoreText,ImageIO,OpenGL,QuartzCore}`** -- link-time stubs the
`cli_dev_gui_stubs` component installs so a program can build against a framework without
the implementation. They are ported now (their cmake targets are `<Name>_stub`, which is
why addressing them by framework name found nothing).

They also exposed the metric bug that had been hiding them, and the fix turned out to be
one line rather than the hard problem it was written up as. See "the metric keys by PATH
now" below.

The stock "ported" figure went 862 (63%) when first sized -> 1060 -> 1168 -> 1311 -> 1336
-> 1354 -> 1359 -> **1434 of 1434, 100%**, the last jump being the denominator growing when
the metric stopped collapsing distinct artifacts onto one name. Every category is complete,
install UNMAPPED is 0, and the `all` graph is likewise **1452 of 1452**. 16 of the earlier
gain was a MEASUREMENT bug, below, not new work.

The shape of the remaining work is unambiguous: **dylibs go from 244 to 605**, so 362 of the
497 missing link edges are frameworks, and the 53 missing modules and 74 missing executables
mostly sit downstream of them. That matches what the COMPONENTS hierarchy says stock adds
over cli: the GUI framework and stub trees, plus python, ruby and perl.

### The last five edges, and why four of them were the SAME bug

DBusKit, iokitd, bsdln, getuuid and elfdep were the five that stayed unported through both
stage 2 and stage 3. Each had its own recorded cause. Four of those causes were wrong, and
all four were wrong in the same direction: the RECORDED SYMPTOM was real and the diagnosis
behind it was a guess that never got tested.

**iokitd** genuinely needed what was written down: two mig subsystems generated in its own
directory. It is the SERVER side of both, so it runs mig over powermanagement.defs a second
time, with IOKIT_SERVER_VERSION set, and cannot share IOKitUser's IOKit_mig_powermanagement.
`gen-mig-from-ninja.py "iokitd" --prefix iokitd_mig` emits both.

**DBusKit** was "no framework root for itself", which was true but not the cause. The pin
DOES ship the namespace: `include/DBusKit` is a symlink to the sibling `Headers` directory.
buck2's glob does not traverse a symlinked directory, so globbing `include/**` stages
NOTHING under DBusKit/ and says nothing about it -- the second of the two silent-empty-glob
traps, and the same shape as the cyclic symlink above. A header_map spells the namespace
out. Underneath that was a second, unrelated need: DBusKit is the one target that compiles
against a HOST library's real headers rather than a wrapgen stub, and the dev shell's own
-isystem does not reach dbus, which puts its headers in a versioned subdirectory
(include/dbus-1.0) and splits dbus-arch-deps.h into another output. Both dirs come from
pkg-config, into `darling.host_include_dirs` in .buckconfig.local and out through
`//src/native:host_headers` -- the same not-a-declared-input compromise as elf_lib_dirs
beside it.

**getuuid and elfdep** were recorded as dying on `mach/machine/vm_types.h`, which exists
only under `cctools-port/cctools/include/foreign` "which nothing in the reference puts on
an include path". Both halves are true and the conclusion does not follow. The real cause
is that CROSS_PACKAGE_ROOTS pointed `cctools-port/cctools/include` at
`//buck-src:libstuff_inc_cctools_include`, which stages the OTHER pin. Both pins ship
`mach-o/loader.h`; cctools' is the Darwin copy and includes `<mach/machine.h>`
unconditionally, cctools-port's guards it with `#ifdef __APPLE__`. On a HOST tool the guard
is false and the whole vm_types chain is never entered. A root over the right directory
makes the missing header stop being missing.

The tell was there the whole time: `clang -H` on the same source with the reference's own
-I list showed no `mach/machine.h` in the include trace AT ALL. Staging the one header by
hand "worked" in a scratch compile for that reason and would have been committed as a fix
for a problem that did not exist.

**bsdln, getuuid and elfdep** then all failed to LINK, with `cannot find entry symbol
_start` and every libc call undefined. The generator emitted `darwin_binary` for them.
`toolchain_of()` already got the toolchain right -- HOST_TARGETS is derived from the
absence of `-target` and is correct -- but the RULE did not follow the toolchain, and
darwin_binary drives the Mach-O path: -nostdlib, ld64, an explicit crt1. A host tool is an
ordinary ELF executable and is cc_binary. One conditional, three targets.

Two generator bugs surfaced alongside. Extra deps were emitted inside the branch that runs
for the `//darwin:sdk_env` include root, so a HOST tool -- which has no sdk_env -- silently
got NONE of them: an entry added for getuuid simply never appeared in its block. And the
mig EXTRA_COMPILE_SRCS map emitted one `compile_srcs = [...]` per entry, which Starlark
resolves by keeping the last.

### The metric keys by PATH now, and that is what made the stubs visible

buck-coverage.py used to key an edge by its artifact BASENAME. A name does not identify a
library. The reference builds 79 names at more than one path: perl's 5.18 and 5.28 module
sets, the cctools tools sitting beside their xcselect shims, cocotron's two X11s, and the
nine dev-stub frameworks, whose AppKit is called exactly `AppKit`. Collapsing a pair onto
one entry answered "ported" as soon as EITHER half was, which is how nine unported
frameworks sat inside a number that read 100%.

It keys by path now, and the denominator went 1359 -> 1434 on stock and 1368 -> 1452 on
`all` -- 84 artifacts that had been counted as somebody else. Nothing had to be invented to
make it work: every generated dylib and binary block ALREADY carries a
`# buck-registry: <reference path> = <target>` pragma, and final_registry() has keyed those
by path since the perl 5.18/5.28 collision was fixed. Resolve by path first, fall back to
the name.

The write-up this replaces said counting by full path "is not a one-line fix" because the
basename dedup was "DELIBERATE for the 16 xcselect shims". Neither half held up. The
xcselect shims are handled by the SEPARATE `exe_name` mechanism a few lines above, which is
what that comment was actually describing, and the change is one line in each of four
branches. A caveat that is never re-tested becomes a reason not to look.

What the metric still takes on trust is now PRINTED rather than assumed, as a `by-name`
line: 86 edges whose name is ambiguous and whose block has no path pragma (53 perl module
duplicates, 30 cctools/xcselect, 3 others), matched on the name alone. buck-test.sh asserts
that number cannot grow. Regenerating those blocks would emit the pragma and take it to 0.

Porting the stubs also introduced a hazard worth knowing about, because it was silent: a
stub's artifact has the SAME NAME as the framework it stands in for, so registering it by
name let three of the nine (ImageIO, OpenGL, AudioToolbox) win the plain key purely on
`os.walk` order -- and a consumer resolving a sibling or a reexport would have got the
empty stub instead of the framework. final_registry() now registers a `dev-stubs/` target
by PATH ONLY. A stub is never the answer to "which target builds libX".

### Matching install entries by NAME was shipping the wrong binaries

`target_for()` in gen-install-from-manifests.py resolved an install entry by its artifact
BASENAME, and a basename does not identify an artifact. What that was actually doing:

- **54 of the 55 Perl 5.18 module destinations held 5.28 BINARIES.** The port builds both
  sets (170 `perl5.18_*` targets and 164 `perl5.28_*`); it was shipping one of them into
  both trees.
- **Both `cmpdylib` destinations held the same file.** The reference builds the cctools
  tool and its xcselect shim separately and installs one to `Library/Developer/DarlingCLT`
  and the other to `usr/bin`.
- **CoreGraphics' X11 backend held AppKit's X11 binary.**

It resolves by path first now, which the generated blocks already supported: they carry
`# buck-registry: <reference path> = <target>` and the registries key those by path. The
answer was there to be asked for.

Taking the coverage metric's `by-name` count from 86 to **0** was the same exercise, and it
was not bookkeeping. It found **14 xcselect shims** (cmpdylib, codesign_allocate,
ctf_insert, install_name_tool, libtool, lipo, nm, otool, pagestuff, redo_prebinding,
segedit, size, strings, strip), **python's datetime.so** and **xcselect's xcrun** that were
never ported at all -- each invisible because a same-named artifact the port DOES build
answered for it. The same shape as the nine dev-stubs.

One entry is out of scope BY PATH now rather than by name:
`src/external/cctools-port/cctools/misc/lipo`. The reference builds lipo twice and installs
only cctools' copy; cctools-port's is a build-time tool like ld, ar and ranlib. Excluding it
by name would have dropped the installed one too.

**And it cost a green check, correctly.** buck-appkit-check.sh went PASS -> PARTIAL: with
AppKit's binary wrongly installed as CoreGraphics' backend, CoreGraphics had no usable
backend at all (that binary defines X11Display, not the CGSConnectionX11 its Info.plist
names) and NSApplication came up. With the RIGHT binary there it dies silently. The pairing
was checked two ways before believing it -- the reference's own link edges, and each
binary defining the principal class its own Info.plist declares -- so this is a cocotron
bug a wrong file was hiding, not a mapping regression. Reverting a correct fix to keep a
probe green would have buried it again.

### UNMAPPED is 0: the last three were never build outputs at all

The three entries the RENAME fix exposed all read as "build output with no target", and
none of them is a build output. That phrasing was the resolver describing its own
assumption, not the artifacts.

- **python-config** and **xattr-0.6.4-2.7** are written by cmake at CONFIGURE time.
  `configure_file(Misc/python-config.in python-config)` and the `easyinstall()` function's
  configure_file of `easyinstall.py.in`. No ninja edge produces either -- `grep python-config
  build.ninja` finds two hits, both inside the cmake re-configure edge -- so nothing in the
  graph could ever be matched against them. The port has a `configure_file` rule and now
  reproduces both, with the same substitutions the cmake sets (EXENAME, and EXEPATH /
  PACKAGE_NAME / PACKAGE_VERSION / PYTHON_VERSION).
- **python.o** is `$<TARGET_OBJECTS:python27exe_obj>`, which cmake expands to
  `CMakeFiles/python27exe_obj.dir/./Modules/python.c.o`. It is a single object out of a
  group, not a library or an executable, so every registry the resolver consulted was the
  wrong kind of thing. `target_for()` now recognises the `CMakeFiles/<target>.dir/` shape
  and answers with the cc_objects group of that name, which is general: that is how cmake
  always expands the generator expression.

Every install entry the reference has now resolves to something the port builds.

### The dev STUBS install over the real frameworks, and that shipped an empty AppKit

The nastiest bug of the campaign, and one the port INHERITED and then made visible.

The reference installs the dev-stub frameworks to the SAME destinations as the real ones:
`src/frameworks/dev-stubs/AppKit/AppKit` and `src/external/cocotron/AppKit/AppKit` both land
in `AppKit.framework/Versions/C`. Nine of them do it -- AppKit, AudioToolbox, Cocoa,
CoreData, CoreGraphics, CoreText, ImageIO, OpenGL, QuartzCore. In cmake whichever install
script runs last wins; in the port whichever entry was read last won.

While install entries were matched by artifact BASENAME the collision was invisible, because
both entries resolved to the same target anyway. The moment they resolved by PATH -- the
correct behaviour -- the stub entry started resolving to the stub, and the prefix shipped
**an AppKit with no implementation in it**. NSApplication has nothing to come up in.

gen-install-from-manifests.py now REPORTS every destination two different targets install
to, and keeps the real implementation:

```
  destination collisions (real wins): 9
      libexec/darling/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
          kept //buck-src:AppKit_dylib
          over //darwin/frameworks:AppKit_stub_dylib
```

A stub exists so a program can LINK against a framework that is not built. When the
framework IS built, shipping the stub in its place is never what anyone wanted, so this is
a judgement the port makes deliberately rather than inheriting cmake's ordering. It is
printed rather than silent, because the previous silent version of this cost a working GUI.

Two smaller lessons came with it. `binary_index()` had the same name-vs-path problem and now
refuses to answer a NAME lookup with a dev-stub, matching what final_registry() already did.
And the collision check had to go in BOTH branches of the entry loop -- the first version
only guarded FILE entries, and frameworks arrive as SHARED_LIBRARY, so it reported nothing
at all and looked like the problem was elsewhere.

### CoreGraphics finds its backend fine, and the claim that it cannot was WRONG

This section used to say that CoreGraphics can never find its X11 backend, because the
reference installs the binary to `Versions/A/CoreGraphics` and the backend to
`Versions/C/Resources/Backends` with `Current -> A`, so `_CGSLoadBackend` would look in
`Versions/A/Resources/Backends`, which does not exist. The layout split is real. The
conclusion drawn from it was not, and it was written down as fact after being inferred from
NSBundle semantics rather than tested.

Two measurements kill it:

- `CGMainDisplayID()` returns **1**, a valid display. The 0 that started the whole theory
  was measured while the prefix had the STUB CoreGraphics installed (54K, no
  implementation); with the real framework (176K, 25 CGSConnection symbols) it reports a
  display. That was the dev-stub collision bug, not a lookup problem.
- Adding the supposedly missing path -- `Versions/A/Resources -> ../C/Resources` -- into a
  materialized prefix changes NOTHING. Same `cg-display=1`, same `APPKIT_PROBE_OK`, no new
  log line. If the lookup were blocked by the layout, that symlink would unblock it.

So the split is harmless, whatever the mechanism, and the port should NOT diverge from the
reference here. That is the seventh recorded diagnosis in this campaign to fail on contact
with a measurement, and the pattern in all seven is the same: a real observation, an
untested explanation attached to it, and the explanation written into the plan as though it
were the observation.

### jsc's empty StackBounds: the main thread has no stackaddr, measured end to end

`tests/buck2/guest/stack_probe.c` is a plain-C guest program that measures exactly what
WTF's StackBounds reads. It turns a theory into four numbers:

```
STACK_PROBE rlimit rc=0 rlim_cur=8388608
STACK_PROBE main   main_np=1 stackaddr=0x0            stacksize=8388608
STACK_PROBE usrstack rc=0 len=8 value=0x0
STACK_PROBE worker main_np=0 stackaddr=0x7263ca5c9000 stacksize=524288
```

**`pthread_get_stackaddr_np` returns NULL on the MAIN thread and a real address on a spawned
one.** That is the whole of jsc's assertion: `currentThreadStackBoundsInternal()` takes the
`pthread_main_np()` branch, gets a null origin, and `ASSERT(m_origin && m_bound)` fires.
Spawned threads are fine because their stack comes from the pthread attrs.

The chain underneath, in order, each step measured or read rather than assumed:

1. libpthread's `__pthread_init` asks `parse_main_stack_params(apple, ...)` first and falls
   back to `sysctl(CTL_KERN, KERN_USRSTACK)`, and only if THAT fails to the `USRSTACK64`
   constant.
2. The sysctl returns **success with a value of zero**, so the constant fallback never runs
   and stackaddr stays NULL. `stacksize` becomes DFLSSIZ (8MB), which is what the fallback
   hardcodes and is visible in the numbers above.
3. That sysctl is `handle_usrstack64` in xnu's emulation, which returns
   `__darling_thread_get_stack()`, which elfcalls into the loader, where
   `ec_thread_get_stack()` in darwin/loader/src/elfcalls.rs is **a stub returning null**.
4. So mldr now passes `main_stack=<stackaddr>,<stacksize>,<allocaddr>,<allocsize>` in
   `apple[]`, which is what XNU itself does. That is better than fixing the sysctl, because
   it also carries the SIZE: the sysctl path hardcodes 8MB for a stack that is 16 pages
   here, which would leave WTF believing it had 8MB of room below the commpage.

**libpthread demonstrably CONSUMES it** -- `parse_main_stack_params` ends with
`bzero((char *)p, strlen(p))`, and the guest's own `apple[]` now reads `main_stack=` with
the value blanked, which is that bzero and nothing else.

5. The value has to be written with **0x PREFIXES**. libpthread parses these fields with
   its own `_pthread_strtoul`, whose comment says "Expect hex string starting with 0x" and
   whose body checks `p[0] == '0' && p[1] == 'x'` before consuming anything. Bare hex parses
   as zero, the comma check fails, and the whole function takes the goto-out path.

The trap in step 5 is worth keeping, because the obvious evidence points the wrong way.
`parse_main_stack_params` bzeros the value on BOTH paths -- the `out:` label is reached on
success too -- so a blanked `main_stack=` in the guest proves only that the function RAN,
not that it worked. What distinguishes them is the **stacksize**: 0x10000 when the parse
succeeds, and 8388608 when it fails and the sysctl fallback hardcodes DFLSSIZ. Reading the
blanking as success cost an increment.

With the prefixes:

```
STACK_PROBE main main_np=1 stackaddr=0x7fffffe00000 stacksize=65536 bound=0x7fffffdf0000
```

**And jsc evaluates JavaScript:**

```
JSC_OK sum=19999900000 json={"a":1}
PASS: jsc evaluated JavaScript inside the buck2-built Darling
```

That is the JavaScriptCore cone -- JavaScriptCore, WTF, bmalloc, mbmalloc, ICU, the JIT and
the GC -- running end to end for the first time. All four runtime checks are rc=0 now, and
buck-test is 143 of 143.

A correction to what this section used to say: "JavaScriptCore works on Darling was never
true upstream either" was too strong. The reference does compile JSC with assertions
enabled, which is why its jsc would assert in the same place, but the FIX turned out to be
in mldr, which is first-party Rust the port owns. Whether the C mldr passed main_stack is
not something this port can check any more, so it should not be claimed either way.

One refinement to the note below: the false "kernel's final pass is not two-level" failure
correlates with a leftover **darlingserver**, not only with a concurrent buck2 build.
`llvm-objdump` on the same artifact says TWOLEVEL, and the suite is 143 of 143 once the
stray daemons are killed.

### The scripting cones: 97 of 100 loadable extensions actually load

`scripts/buck-scripting-check.sh` is the widest runtime probe in the tree by artifact
count. python's 54 lib-dynload extensions, zsh's 32 loadable modules and perl's XS modules
are each a separate Mach-O that buck2 built, linked and installed, and until this ran every
one of them had been checked only for "does it link". Loading a module runs its
initializer, resolves its symbols against the frameworks underneath, and hands the
interpreter something usable, which is a great deal more.

```
PY_RESULT 53/55      ZSH_RESULT 32/32      PL_RESULT 13/14
```

**All three failures were upstream's, and each was checked against the reference rather than
assumed. One is now fixed:**

- `_sqlite`: **FIXED, by diverging from the reference deliberately.** The reference installs
  the file as `_sqlite.so` while the symbol it exports is `init_sqlite3`, and CPython 2.7
  imports an extension X by dlopening `X.so` and calling `initX`. python's own sqlite3
  package does `from _sqlite3 import *`, so `import sqlite3` failed with "No module named
  _sqlite3" in the reference too. The artifact IS the _sqlite3 module; only the installed
  name is wrong. gen-install-from-manifests.py's EXTRA map now ALSO installs it as
  `_sqlite3.so` and leaves the reference's `_sqlite.so` in place, so nothing the reference
  ships disappears. `import sqlite3` now opens a database and round-trips a row
  (SQLite 3.32.3), and the check asserts that rather than mere importability.
- `_curses_panel`: "No module named _curses". `_curses_panel.so` is installed and
  `_curses.so` is not, in the reference too.
- `Storable`: "object version 2.4 does not match bootstrap parameter 2.41". The 5.18
  `Storable.pm` says 2.41 and the XS is built with `-DVERSION=\"2.4\"`. **The reference
  passes exactly the same define.** It is not the 5.18/5.28 mixing bug either: the prefix
  maps each tree to its own target and the source .pm versions match their trees.

That is the eighth time in this campaign that checking changed the answer, and the first
time the answer came out in the port's favour three times over. Worth stating because the
reflex by now is to assume a probe failure is the port's fault.

The counts are the assertion, not per-module pass/fail: a handful of extensions can
legitimately fail on a system without the thing they wrap, so the check asserts floors
(50, 30, 12) measured from the first run.

### The runtime checks CANNOT be chained in one shell

Running buck-bash-check.sh, buck-smoke-check.sh and buck-appkit-check.sh back to back makes
the first two fail while each passes alone. The cause is not subtle once looked at:

```
pgrep -a -x darlingserver
301939 darlingserver /tmp/darling-jsc-1000/prefix
720293 darlingserver /tmp/darling-appkit-1000/prefix
721577 darlingserver /tmp/darling-buck2-1000/prefix
721668 darlingserver /tmp/darling-smoke-1000
```

FOUR daemons alive at once. Each check kills stale processes under its own root at START
and not at exit, so every run leaves its daemon up for the next one, and concurrent daemons
interfere. Run them one at a time, and kill the strays by PID between runs:

```
for pid in $(pgrep -x darlingserver); do kill -9 "$pid"; done
```

`pgrep -x`, never `pgrep -f`: an `-f` pattern matches the command line of the shell running
it, which is how a cleanup loop ends up killing its own invocation.

### libstdc++ built all along, and sdk_env was the reason it did not

`libstdc++.6.dylib` was the ONLY target in the tree that would not build, and the recorded
reason -- that GCC 4.2.1's vendored headers do not compile against this SDK with clang at
`-std=c++14` -- was wrong. It compiles fine. What broke it was the port's own environment.

The reference passes `-nostdinc++` for that target AND never puts `libcxx/include` on its
include path; its include list has the rest of ENV_INCLUDES and not that one entry. The
port folds libcxx into `//darwin:sdk_env` -- deliberately, so it appears exactly once, since
two copies on a command line break `#include_next` -- and sdk_env is all-or-nothing, so
libstdcxx got libc++'s `stdlib.h` anyway. GCC's `<cstdlib>` does `using ::abs;` and then
declares `abs(long)`; with libc++'s `stdlib.h` already declaring it, that is a redeclaration
of what the using-declaration brought in. Eight such conflicts, and none of them anything
to do with the SDK.

`//darwin:sdk_env_nocxx` is the same environment without libcxx, and the generator chooses
between the two by READING THE REFERENCE -- a unit whose include list does not mention
libcxx gets the nocxx one -- the same way HOST_TARGETS is derived from the absence of
`-target` rather than from a list of names. Both are built from shared Starlark lists with
libcxx spliced at the position the reference gives it, because appending it instead would
have quietly changed the include ORDER for every other target in the build.

That is the fifth recorded diagnosis this campaign that turned out to be a guess nobody had
re-tested, and the fourth that pointed away from a fix that took under an hour. Coverage is
1453 of 1453 now, with `libstdc++.6.dylib` out of the out-of-scope list.

### The reference is the `all` graph now

`result-graph-ref` pointed at `stock` from the stock switch until `all` reached 100
percent; it points at `all` now, and the prefix is generated from it. The move was small
by design -- `all` adds 16 install entries over stock -- and it removes the one structural
inconsistency left in the port: it BUILT the whole `all` component while SHIPPING a stock
prefix, which is why buck-jsc-check.sh had to hand-stage JavaScriptCore into the tree
before it could run anything. It does not any more.

Numbers move with it: the coverage floor in buck-test.sh is 1452 rather than 1434, and the
prefix is 39,168 entries.

### What "100 percent" does NOT mean

Worth stating plainly, because the coverage number invites the wrong reading.

`buck2 build //...` over all **12,115 targets** fails on exactly TWO: `stdcxx_obj` and
`stdcxx_obj2`, the out-of-scope `libstdc++.6.dylib`. So the build-level claim is strong.
What it does not cover:

- **32-bit is not built and will not be.** `libsyscall_32` -> `libsystem_kernel_static32.a`,
  plus the 74 i386 MIG edges. A deliberate scope reduction, not a gap: the long-term target
  for this project is aarch64, so spending on i386 buys nothing.
- **cctools ld/ar/ranlib come from Nix** rather than being built here.
- **The metric counts LINK edges only**: 1439 of the reference's 38,337 ninja edges. The
  3,462 CUSTOM_COMMAND (codegen) edges are covered only by IMPLICATION -- a target missing
  its generated sources fails to build, and everything builds -- with no 1:1 check.
- **86 edges are matched on artifact name alone** (the `by-name` line).

**And the big one: build parity is not runtime parity.** buck-test.sh's 143 checks are
almost entirely static -- does it link, does it export the right symbols, is the
install_name right. Execution lives in separate scripts, and their combined scope is: the
container boots, launchd boots, bash runs, guest nix builds and runs bash, plus 22 smoke
assertions (shell, uname/sw_vers, filesystem, sandbox-exec, diskutil, Directory Services).
Of ~1450 built artifacts, a few dozen have ever been RUN.

`scripts/buck-jsc-check.sh` is the first probe aimed at that gap, and it paid immediately.
jsc loads, links against the buck2-built JavaScriptCore, WTF and bmalloc, and gets as far
as WTF's stack setup inside the container -- then dies on

```
ASSERTION FAILED: m_origin && m_bound
wtf/StackBounds.h(129) : bool WTF::StackBounds::isGrowingDownwards() const
```

Both members nullptr is exactly what the `constexpr StackBounds()` default constructor
produces, so a DEFAULT-CONSTRUCTED bounds is being queried before anything filled it in.

**This is not a port defect, and checking that was the important step.** The reference does
not put `-DNDEBUG` on the JavaScriptCore compile edge -- the token appears 1379 times
elsewhere in the graph and not once there -- so the reference compiles JSC with assertions
enabled too and its jsc asserts in the same place. The port reproduces the reference
faithfully; "JavaScriptCore works on Darling" was never established upstream either. The
probe therefore exits 3 for this state and 1 only if jsc fails to reach WTF init, which
WOULD be a regression.

### The AppKit probe, and the 167 install entries nothing could see

`scripts/buck-appkit-check.sh` runs `tests/buck2/gui/appkit_probe.m` against an Xvfb
server: NSApplication comes up, an NSWindow opens, the run loop is pumped once. **It
passes** -- MapNotify and VisibilityNotify come back from the X server -- and getting there
turned up three things, two of them real gaps.

**The host ELF libraries must be on LD_LIBRARY_PATH for the LOADER, not just for wrapgen.**
Without it, loading AppKit does not merely fail to draw: the process dies BEFORE main with
no output whatsoever, because the sixteen src/native stubs forward into libX11, cairo and
freetype through elfcalls, and a stub whose .so cannot be dlopened takes the process with
it. `darling.elf_lib_dirs` in .buckconfig.local already holds the directories -- it is how
wrapgen finds the same libraries at build time -- and the check now reuses them.

**The prefix was dropping every `file(INSTALL ... RENAME "x" ...)` entry. All 167 of
them.** ENTRY in gen-install-from-manifests.py demanded `FILES` immediately after the type
modifiers, and cmake writes

```
file(INSTALL DESTINATION "..." TYPE FILE RENAME "Info.plist" FILES ".../X11.backend/Info.plist")
```

so those lines simply did not match, and a line that does not match is a line nobody
counts. **Neither existing metric could see it**: UNMAPPED cannot report an entry that
never parses, and coverage only counts link edges. What found it was running a program.
cocotron loads its display backend as a BUNDLE and reads NSPrincipalClass out of the
bundle's Info.plist; with no Info.plist there is no principal class, no backend can be
instantiated, and NSApplication exits 1 in silence.

The fix keys renames by (destination, source) rather than by source, because one source
really is installed under several names -- python's `fix/dummy.py` is a placeholder that
ships as both `xattr` and `python-config` -- and the first version, keyed by source alone,
said so loudly on its first run instead of quietly picking one.

Bringing those 167 in took the prefix from 34,582 entries to 39,155 and made THREE entries
newly unmapped: `python-config`, `xattr-0.6.4-2.7` and `python.o` are build outputs the
port has no target for. They were always missing; the difference is that now they are
counted. buck-test's UNMAPPED ceiling is 3 until they are mapped.

The general lesson is the one this section keeps re-learning in a new costume: a parser
that SKIPS what it does not recognise reports success on the subset it happens to
understand. ENTRY had no else-branch, and 167 lines went past it without a word.

NOTE that UNMAPPED counts install entries whose TARGET EXISTS, not ones that build, so a
target that does not build must have its block REMOVED, not left in place.

Three things worth knowing before touching this again. buck-port.py's framework resolver has
to be re-run AFTER the gen_srcs are wired: a target that builds without its generated
sources can still fail once they arrive, because the generated header drags in frameworks
the original sources never named (kextmanager.h -> Security/Authorization.h ->
CoreFoundation). The holdback markers match as WHOLE LINES, so a target with both a
"<name>" and a "<name> dylibs" block needs both spelled out -- removing one leaves the
other referencing a target that no longer exists. And gen-install-from-manifests.py used to
take EIGHT MINUTES a run because target_for called gen.final_registry() and
gen.archive_registry() per entry, and each of those WALKS THE WHOLE REPO re-reading every
BUCK file; they are built once now and it takes 1.6 seconds. If another generator in
scripts/ feels hung, look for the same shape before assuming it is the ninja parse.

**The registry is a TEXT SCAN, so a target built from a Starlark table is invisible to it.**
`final_registry()` in gen-buck-from-ninja.py matches a literal `name = "X_dylib",` followed
by `dylib_name = "..."`. src/native writes its sixteen wrap_elf stubs as three list
comprehensions over a `_NATIVE` table, so it matches none of them, and buck-coverage.py
reported all sixteen as unported while buck-test.sh was building and checking them by
export count. They sat in the missing list for as long as nobody cross-read the two. Such a
package now declares what it produces with a `# buck-registry: <artifact> = <target>`
pragma, which the registry reads alongside the literal form; buck-test.sh asserts the
pragma list and `_NATIVE` still agree, because duplicated data drifts. When a coverage
number disagrees with something you know builds, suspect the scan before the port.

One more for buck-test.sh specifically: read Mach-O symbols with llvm-nm, never plain nm.
Inside `nix develop` the bare name resolves to the clang wrapper's binutils nm, which
answers "file format not recognized" on a Darwin dylib and, with 2>/dev/null, an empty
symbol list that looks exactly like a library missing every symbol. Six freshly added
checks all failed that way while the same command outside the dev shell found all six. The
file already used llvm-nm everywhere else; the lesson is to follow the surrounding code
rather than reach for the obvious name.

## Status (2026-07)

Done:
- **Rust rewrite complete and default.** Host daemon (`linux/server`, crate `darling`, bin
  `darlingserverd`), launcher (`linux/launcher`, bin `darling`), guest loader
  (`darwin/loader`, bin `mldr`). The C++ daemon and C launcher/loader are deleted.
- **Boots to Darwin; M1 achieved.** Guest nix 2.34.8 builds and runs `hello` (and `pv`)
  from source under rootless Darling, launchd-free. `nix eval builtins.currentSystem` →
  `"x86_64-darwin"`.
- **Off git submodules.** Nix (`nix/submodules.json`, 147 pins + `nix/lib/darling-src.nix`)
  is the sole source path; `.gitmodules` + gitlinks deleted, no `?submodules=1`.
- **Full `.#default` builds green and boots.**
- **Identity:** macOS **14.4.1** / Darwin **23.4.0** / build **23E224**
  (`patches/xnu/0005` + `SystemVersion.plist`); clang auto-targets
  `x86_64-apple-darwin23.4.0`. `CMAKE_OSX_DEPLOYMENT_TARGET` stays 11.0 by choice.

Phases A (identity), B (symbol gap), C (bootstrap tools execute + build hello / M1) are done.
The open frontier is D (oracle), E (package ladder), F (ARM prep), plus the Rust/build/perf
tracks below.

---

## Architecture

- **Call chain (the debugging map):** Darwin binary → Darwin libc → `libsystem_kernel`
  BSD-trap stub → daemon translates to Linux → kernel. Syscalls are implemented only to the
  depth Nix needs, not for general macOS compat.
- **launcher** (`linux/launcher`, libc-only, builds offline): rootless userns re-exec,
  prefix bootstrap, spawns the daemon as container init, shellspawn client, teardown. Owns
  NO mounts/vchroot (the daemon does).
- **daemon** (`linux/server`): single-threaded epoll loop + a **stackful microthread
  scheduler** (`sched.rs`) — not async, because duct-tape suspends microthreads
  synchronously from inside C stacks; single-worker is correct (duct-tape locks are
  cooperative). RPC codec (`rpc_wire.rs`) is generated from the calls list, 162/162
  byte-identical to C. Wire = SOCK_DGRAM + SO_PASSCRED (sender pid via SCM_CREDENTIALS, used
  for `process_vm_readv` because the guest is in its own PID namespace).
- **duct-tape** (`src/external/darlingserver/duct-tape/`, still C): kernel-emulation glue
  that compiles the vendored XNU (osfmk/bsd). Linked into the daemon crate by
  `linux/server/build.rs`: bindgen generates the 36-field `dtape_hooks_t` from source
  headers; static libs (`libdarlingserver_duct_tape.a`, `liblibsimple_darlingserver.a`)
  come via the `DUCT_TAPE_LIB` env var. The Rust/C seam is the frozen `dtape_*` API +
  `dtape_hooks` vtable — Rust above, C+XNU below.
- **mldr loader** (`darwin/loader`, libc + goblin): guest Mach-O loader — segment mmap/slide,
  commpage, the elfcalls vtable (ELF↔Mach-O), start stack, daemon checkin, jump to dyld.
- **Container model:** an overlayfs prefix (`~/.darling`, macOS FS hierarchy) entered
  **rootless** via unprivileged user namespaces (needs
  `kernel.unprivileged_userns_clone=1`, kernel ≥5.11). **One command per fresh container** —
  a sibling userns cannot join a running container's mount ns.
- **Shared store:** guest `/nix/store` is the host store via a `/nix →
  /Volumes/SystemRoot/nix` symlink (the host root is mounted at `/Volumes/SystemRoot`);
  `/nix/var` stays Darling-local to avoid db/schema conflicts.
- **apple-sdk `.tbd` stubs:** binaries link against stub symbols, resolved at runtime from
  Darling's reimplemented libraries — so derivation hashes never depend on Darling.
- **sandbox-exec** is a parse-and-ignore stub (the Linux container already isolates).
- **Nix packaging:** `nix/lib/darling-src.nix` assembles the tree from the 147 pins +
  `patches/<name>/`; `nix/package.nix` builds the Darwin userland and installs the Rust
  crates; `nix/{launcher,server,duct-tape,loader,cctools-port}.nix`.

---

## Invariants (never violate)

1. **Official nixpkgs 26.05 only.** A patched input makes hashes incomparable and the oracle
   worthless. Record nixpkgs-side needs as a blocker entry (see Blockers), don't fork inputs.
2. **No Apple-proprietary bits** in outputs or the repo. Reimplement from Apple open source
   (APSL) or clean-room from public docs; note provenance in commits. SDK stubs flow through
   Nix's own `apple-sdk` fetch, never vendored.
3. **Green never regresses.** Every fix lands with a regression test; `scripts/run-tests.sh`
   + flake checks pass before every commit; the compatibility matrix is append-only.
4. **Arch discipline.** Code touching registers, syscall numbers, thread state, signal
   frames, TLS, page size, or Mach-O CPU types goes behind the arch boundary. aarch64 is the
   customer; x86_64 is the test rig.

---

## Open work

### D — Correctness oracle (the keystone remaining) [ARCH-FREE]
"It built" → "it built **correctly**." The project's core value proposition.
- **D.1** `scripts/oracle.sh <attr>` = `nix build --rebuild` vs cache.nixos.org, JSON
  (match / mismatch / build-failure / known-nondeterministic).
- **D.2** oracle column in `tests/nix/compatibility-matrix.sh`; a justified
  non-determinism allowlist.
- **D.3** on mismatch: diffoscope + classify (codegen vs metadata vs fs-ordering vs
  miscompile). **A codegen-class divergence is stop-the-line** — the shim is lying to the
  compiler (math, memory layout, or a syscall result) and everything above is suspect.

### M1 tail (Phase C.3–C.4b) [ARCH-FREE]
- Drive the official `pkgs.hello` **derivation** through guest nix (not hand-run
  configure/make). `scripts/build-pkg-bypass.sh <attr>` generalizes to any nixpkgs
  x86_64-darwin attr. Widen to no-substitute deps.
- **C.4b** gdb-on-timeout stall capture (timeout + on-timeout stack of the guest process +
  daemon), filed to the Stall notes below. (The old `config.status` here-doc pipe hang was
  the checkout lifetime-pipe fd leak → pipe-page starvation, now FIXED; reverify if it
  recurs.)

### E — Climb the package ladder [ARCH-FREE]
- **E.1** dependency-weighted 26.05 x86_64-darwin target list (CLI-only; GUI *runtime* out
  of scope — building GUI apps against link-time framework stubs is fine).
- **E.2** grind loop per package: build → triage (syscall / symbol / stall / semantic
  divergence) → fix with a regression test → oracle → append to matrix.
- **E.3** milestone packages: `python3` (pip-stall class), `git`, `cmake`, `openssl`, a
  large C++ package (`llvm`); stretch: `swiftc` (stresses libdispatch/CF).
- **Exit (campaign):** the full Tier-1..3 matrix green with oracle, on a frozen 26.05 pin,
  in CI, reproducibly from a clean prefix.

### F — ARM readiness (prep only, do not start the port) [ARCH-PARAM]
- **F.1** salvage-assess the three `feature/arm-support*` branches → `plan/arm-salvage.md`.
- **F.2** arch-boundary audit (syscall numbers, ucontext layouts, asm, page size). Audit
  host-page-size vs Darwin `vm_page_size`: arm64 userland assumes **16K pages** — plan to
  report 16K from libSystem regardless of host, and prefer `CONFIG_ARM64_16K_PAGES` guests.
- **F.3** parameterize harness / VM tests / matrix / oracle / symbol tooling by arch.
  aarch64-darwin outputs carry ad-hoc code signatures (nixpkgs signs via sigtool) — the
  oracle must handle signature bytes correctly, not diff them naively.
- **F.4** document the QEMU aarch64 dev recipe (share `/nix/store` via virtiofs; never run
  darlingserver under qemu-user — signal/TLS fidelity).

### Rust + tooling
- **#63 exec across architectures** [narrow] — daemon cross-arch exec; the guest 32-bit
  loader (`mldr32`, cmake `BUILD_TARGET_32BIT`) is port-or-drop-undecided. Fat/universal
  Mach-O selection already done.
- **#72 duct-tape → self-contained `-sys` crate** — decouple XNU from the cmake tree (today
  linked via `DUCT_TAPE_LIB` at the cmake build's `.a`; bindgen runs on in-tree headers).
  Aspirational, not started.
- **#73 port build-time codegen to Rust** — `generate-rpc-wrappers.py` (already extended to
  emit the Rust codec, but still Python) and `tools/generate-xcode-stubs.py`.
- **#69 mig (Mach Interface Generator)** — still the C `bootstrap_cmds` fork (Apple-tracking,
  no nixpkgs substitute). A Rust rewrite is unstarted; only its nix-ninja edge handling is
  patched (see Build system).
- **#68 finish the repo reorg** — move the C++ darlingserver + duct-tape from `src/external`
  into `linux/darlingserver/`, completing the `darwin/` (guest) + `linux/` (host) seam.
- **Linker (#57 tail)** — `packages.darling-ld64` (`nix/cctools-port.nix`) done; fold in
  `install_name_tool`/`nmedit`, validate a real darwin dylib link with `-DDARLING_LD64_DIR`.

### Build system — make nix-ninja the primary incremental build (#26/#39)
Lower every edge of Darling's ~26k-edge ninja graph to its own content-addressed nix
derivation (the ~40-min monolith → seconds-incremental, fully cacheable, pure-nix). Infra:
`nix/lib/darlingNinja.nix` (`buildTarget`), vendored `nix/lib/nix-ninja/`.
- **State:** the libSystem umbrella builds per-edge (~5036 edges, valid Mach-O);
  darlingserver-ninja green per-edge; the graph-json IFD is feasible (~100s). Interim fast
  loops exist (`packages.darlingserver` coarse ~5-6 min vs 40; launcher fast-path).
- **Open blocker:** full-graph `buildTarget {}` (the `all` phony) stops at
  `migHeaderIncsFor` scope-sensitivity — `asl.c`'s `<asl_ipc.h>` `-I` resolves at subgraph
  scope but returns `[]` at full-graph scope.
- **To make primary:** (1) close the asl.c blocker → full-graph green; (2) build the
  install/fixup wrapper reproducing `package.nix`'s exact `libexec/darling` layout from
  per-edge outputs, diff'd identical; (3) wire `packages.darling-ninja`, kept OUT of
  `nix flake check` (thousands of derivations hang it); (4) vendor rust-ninja, drop the
  `overby` input.

### Multi-user / launchd / #47
- **#47 launchd: a guest RPC sendmsg gets ECONNREFUSED** [long-term] — narrowed 2026-08-01
  from "launchd deadlocks" to a 15-line syscall reproduction. The SPIN half is FIXED
  (patches/xnu/0008): a failed sigexc used to abort, and aborting needs the machinery that
  just failed, so it looped on ud2 -- 56,676,502 SIGILLs at one address, ~50% CPU,
  unkillable. It now exits with a diagnostic. launchd still does not work.

  The whole failure, from `strace -ff -e trace=socket,connect,bind,close,fcntl,sendmsg,sendto`:

        socket(AF_UNIX, SOCK_DGRAM, 0)  = 10
        bind(10, {AF_UNIX}, 2)          = 0        # autobind, NOT connected
        fcntl(10, F_DUPFD_CLOEXEC, 512) = 513      # RPC fd parked high
        close(10)
        sendto (513, #1  checkin)            = 40  # ok
        sendmsg(513, #35 thread_self_trap)         # ok
        sendmsg(513, #8  set_thread_handles)       # ok
        sendmsg(513, #31 pthread_canceled)         # ok
        sendmsg(513, #36 mach_reply_port)          # ok
        sendmsg(513, #38 mach_msg_overwrite)       # ok
        sendmsg(513, #31 pthread_canceled)         # ok
        sendmsg(513, #38 mach_msg_overwrite) = -1 ECONNREFUSED   <-- the bug
        --- SIGABRT {si_code=SI_USER, si_pid=1} ---             # __simple_abort
        sendmsg(513, #14 interrupt_enter)    = -1 ECONNREFUSED  # sigexc, same fault
        +++ exited with 1 +++                                    # 0008 working

  So: the SECOND mach_msg_overwrite on a socket whose previous seven sends all succeeded,
  same fd, same path, sender never connected. That is the entire open question.

  The FIRST failure in the system is not launchd's, though. A launchd JOB (guest pid 4)
  starts, closes the inherited RPC fds 512/513/514, opens its own, checks in, runs ~20 RPCs
  fine, and then its last mach_msg_overwrite comes back with reply status **0x10000003 =
  MACH_SEND_INVALID_DEST**, whereupon it exit_group(1). launchd sees that as
  `SIGCHLD {si_pid=4, si_status=1}`, keeps going for another dozen successful RPCs, and only
  THEN gets ECONNREFUSED. So MACH_SEND_INVALID_DEST is the earliest thing that goes wrong and
  is the better thread to pull; the ECONNREFUSED may well be downstream of whatever state
  that leaves behind.

  ELIMINATED by measurement, do not re-investigate:
    * The portset/kqueue linkage. One portset, not empty, and a message on a member port
      DOES wake the kqchan waiter.
    * "Stranded messages on ports with empty klists." Posted == consumed, 18 for 18.
    * The daemon restarting or its socket being replaced. `Listener::bind` unlinks and binds
      once; the socket inode is stable across a run and `lsof` shows it alive and
      `type=DGRAM (UNCONNECTED)` at failure time.
    * "Two daemons fighting over the path." The WORKING (DARLING_NO_LAUNCHD=1) run has
      three darlingserver processes and the failing one has two, so the count is not it.

    * The socket being replaced mid-run. Sampled at 100 Hz for 6s: the inode at
      <prefix>/.darlingserver.sock never changes.
    * The container's mount namespace resolving the path differently. The host, the daemon's
      /proc/PID/root and the guest's /proc/PID/root all stat the SAME inode.

  ANSWERED: the destination is **MACH_PORT_NULL**. Instrumenting all three INVALID_DEST
  exits of ipc_kmsg_copyin_header gives exactly one event per boot:

        copyin_header: INVALID_DEST (name not valid) dest=0x0 reply=0x403 dest_type=19

  dest=0x0 with a perfectly good reply port (0x403) and dest_type 19 (COPY_SEND). The job is
  not sending to a stale or dead port; it is sending to a port it never got. That makes this
  a BOOTSTRAP PORT problem, not an IPC one: a launchd job whose bootstrap_port is null fails
  its first service lookup and exits, which is the exit(1) launchd sees.

  ROOT CAUSE FOUND AND FIXED (the first cause, not the whole task). Every guest task was
  created with NO PARENT: Registry::ensure_task passed std::ptr::null_mut() to
  dtape_task_create, which its own comment admitted ("Parent is NULL for now"). ipc_task_init's
  parent==TASK_NULL branch sets itk_bootstrap = IP_NULL, so a launchd JOB could never inherit
  launchd's bootstrap port however correct everything else was. It asked, got nil, sent its
  first service lookup to MACH_PORT_NULL and exited.

  ensure_task now finds the parent through /proc/<host pid>/PPid and passes its task. The
  lookup has to happen there rather than in Handler::set_current, because the task is created
  before the first call is dispatched and set_current's parent link comes too late. With a
  parent, ipc_task_init also inherits the exception ports, the registered ports and the
  security/audit tokens, which is what XNU does.

  Measured, same boot, before and after:

        before   dtape_task_create: nsid=4 parent=(nil)      GET bootstrap -> (nil)   INVALID_DEST dest=0x0
        after    dtape_task_create: nsid=4 parent=0x..d8e10  GET bootstrap -> 0x..cbe50   INVALID_DEST count 0

  launchd STILL does not complete. It is NOT a deadlock: it is a 30-SECOND POLL LOOP.
  Timestamping the daemon's own strace and measuring the gaps gives 29.555s, 30.001s, 30.001s,
  each ending with a reply to call #62 semaphore_timedwait. launchd waits on a semaphore with
  a 30 second timeout, times out, does two or three RPCs, and waits again -- forever. An
  earlier revision of this entry called it a quiescent deadlock with ninety seconds of
  silence; that was an artifact of filtering the trace on one timestamp prefix and missing the
  intermediate cycles. Read gaps, do not eyeball a filtered tail.

  The ECONNREFUSED cascade is HALF a teardown artifact, and the other half is the real event.
  Sampling process counts every 2 seconds against the guest's own RPC log (with that log
  DELETED first -- see below) shows a sharp partial collapse mid-run:

        t=22s  daemons=2  mldr=4  rpclog=0
        t=24s  daemons=1  mldr=2  rpclog=3

  Two mldr processes and one darlingserver disappear together at ~23 seconds, and all three
  -111 lines (mach_reply_port, mach_msg_overwrite, interrupt_enter) appear in that same
  instant, with 66 seconds of timeout still to run. In the earlier timestamped run the
  refusal coincided with the harness's own SIGTERM, which is what led to calling the whole
  cascade an artifact; it is better stated as: something in the container dies at ~23s, and
  ONE process's -111 triple is its death rattle. Exactly 3 lines per run, then silence.

  TRAP, and it cost a wrong reading: /tmp/dserver-client-rpc.log is the HOST's file. The guest
  and the host resolve it to the SAME inode, and it is opened O_APPEND, so it accumulates
  across every run. Thirty-one lines of repeating -111 look like a live retry loop and are
  actually ten runs' worth of three. Delete it before every run. `strace -ff -tt` across every
  thread settles it by timestamp:

        11:59:32.5   all activity stops, about one second into the boot
        ...          NINETY SECONDS of complete silence, every process blocked in recvmsg
        12:01:11.6   the harness's own `timeout 100` fires and SIGTERMs the daemon
        12:01:11.648832  daemon killed
        12:01:11.648946  launchd's sendmsg -> ECONNREFUSED, 114 MICROSECONDS later

  So the ECONNREFUSED, the -111, the abort and the exit(1) are all artifacts of the TEARDOWN.
  They are what any process gets for talking to a daemon that has just been killed. Do not
  chase them again; use a timeout longer than the observed hang and look at the QUIET period.

  WHO IS WAITING, from the daemon's own RECV trace (DSERVER_TRACE_CALLS=1), last call parked
  per (nsid, tid):

        nsid=1 tid=1  #38 mach_msg_overwrite   launchd's dispatch thread, blocked on the PORTSET
        nsid=1 tid=3  #62 semaphore_timedwait  a launchd worker in a timed wait
        nsid=4 tid=4  #38 mach_msg_overwrite   the JOB, blocked in a mach_msg

  And guest pid 4 is `launchctl bootstrap -S System` (from its execve). So the ORIGINAL entry
  named the right victim after all, even though its portset explanation was wrong.

  THE IPC ITSELF WORKS. Measured in one round trip, lines 793-808 of the daemon log:
    * the job sends to launchd; the message lands on a port that IS in the portset and
      `wq_prepost_do_post_locked` preposts it to set 0x40001;
    * launchd's receive CONSUMES that prepost (`waitq_clear_prepost_locked: invalidate
      prepost 0x280000`);
    * launchd replies to pid 4 and the post finds a real receiver (`receiver=0x..247b60`).
  So bootstrap messaging is not broken. After that exchange everything simply goes idle.

  THIRD FIX LANDED: proc_get_effective_thread_policy's stub returned -1 for every flavor
  except LATENCY_QOS, and -1 is TRUTHY. Every XNU caller reads that result either as a
  boolean flag (DARWIN_BG, PASSIVE_IO) or as a small non-negative tier/QoS class (IO, QOS,
  THROUGH_QOS), so every thread read as "background" and every throttle tier came back
  nonsense. The real implementation exists in xnu/osfmk/kern/thread_policy.c but is NOT in
  the duct-tape build, so the stub wins. Returning 0 (not background, no throttling, QoS
  unspecified) is the neutral answer for all of them. Measured across three runs each:
  mldr processes surviving at t=32s went from 2 to 3, consistently. The stub line was the
  LAST line of every boot log, in five runs out of five.

  Run-to-run VARIANCE is real and has corrupted single-run readings before: the -111 count
  per run is 0 to 4, while the end state (process counts, daemon log length 445-467) is
  deterministic. Measure across at least three runs before believing a difference.

  ROOT CAUSE FOUND AND FIXED. An S2C call (the daemon asking a guest to do something, e.g.
  the mmap that copies out an OOL memory descriptor) was addressed using a single global
  "current guest", set by the serve loop from the call it was dispatching. That is only
  correct while that dispatch is on top. A microthread parked in a blocking mach_msg receive
  is resumed as a SIDE EFFECT of another thread's call -- the reply that wakes it arrives on
  the SENDER's dispatch -- so when it resumed and needed an S2C, it read the sender's identity
  and sent its mmap request to the wrong process. The reply was then filed under the wrong
  (pid,tid) key, so the waiting microthread was never rescheduled: a permanent hang, with the
  guest thread stuck in recvmsg and the daemon showing a RECV with no matching reply.

  The identity now lives on the Microthread (sched.rs s2c_peer), bound when a call is
  dispatched onto it, so a resumed microthread still targets its OWN guest. The global slot
  remains as a fallback for microthreads that never had one bound.

  How it was found, because the method is the transferable part:
    * /proc/PID/task/*/syscall on the guest processes. gdb is useless here (guest Mach-O has
      no host symbols, every frame is "?? ()"), but the raw syscall number + args showed all
      three threads blocked in recvmsg(512) -- waiting for the daemon, not deadlocked on
      each other.
    * A SEND-reply trace to pair with the existing RECV trace. Received-and-parked-forever
      and received-and-answered look identical without it. That gave the decisive count:
      every thread parked in exactly ONE unanswered call.
    * The Mach msgh_id, which is the MIG routine number. 420 in subsystem "job" (base 400,
      src/launchd/src/job.defs) is job_mig_kickstart, and its reply is 520. That named the
      operation instead of leaving it as "some message".
    * The descriptor type. Every complex message in the boot carried dtype=0 (a port
      descriptor, which copies out entirely inside the daemon) EXCEPT kickstart's request and
      reply, which carry dtype=1 (MACH_MSG_OOL_DESCRIPTOR). The first message needing OOL
      copyout to a BLOCKED guest thread was exactly the one that hung. That is what turned a
      structural coincidence into a mechanism.

  Result, measured over three runs: daemon log 445-467 lines -> 4181-4210; mldr processes at
  t=36s 3 -> 6/10/14 (launchd is spawning jobs now); launchctl RECV=71 SEND=71, balanced.
  The container still does not finish -- see the next entry for where it gets to now.

  #47 IS DONE. The container now boots through launchd -- launchd as guest pid 1, launchctl
  bootstrap -S System loading the system jobs, memberd and shellspawn running, 21 guest
  threads where there used to be 3 -- and runs a command to completion. Locked in by
  scripts/buck-launchd-check.sh, which is the no-launchd check's counterpart and exists
  because "bash runs" never implied "init works": the no-launchd path skips init entirely.

  TWO OPS TRAPS, both of which cost real time here and will cost it again:

    * `pkill -9 -x a b c` is a USAGE ERROR ("only one pattern can be provided") and kills
      NOTHING, silently, exiting 2. Every cleanup written that way is a no-op. 22 stale mldr
      processes from earlier runs had accumulated and were competing with live measurements.
      Use `pkill -9 -x 'mldr|darling|darlingserver|shellspawn'` -- one ERE pattern.
    * Do NOT pre-create DPREFIX. darling treats an existing prefix directory as one it has
      already set up, so `mkdir -p` before booting skips first-time setup and launchd boots
      into an unpopulated filesystem and stalls deterministically at ~509 lines of daemon
      log. This masqueraded as a port bug for a while: the check failed 3/3 while the same
      command by hand passed 8/8, and the only difference was the mkdir.

  A SEPARATE bug found along the way, not yet fixed: a guest fd that is a SOCKET gets the
  vchroot prefix pasted onto readlink's output, producing the path
  "/Volumes/SystemRootsocket:[100816751]". Visible as a [guest kprintf] "dtype for fd 2"
  line. It blinds launchctl's stderr, which is its own reason to care. Find out whether its
  RPC reply was actually SENT after the microthread was woken, or whether the wake and the
  reply have come apart. That is a narrow question about the daemon's parked-microthread
  resume path, and it is the last unexplained step.

  Not a lead: shellspawn is PRESENT in the prefix, at usr/libexec/shellspawn (NOT
  usr/libexec/darling/shellspawn, where I looked first and wrongly concluded it was missing),
  together with System/Library/LaunchDaemons/org.darlinghq.shellspawn.plist. `launchctl
  bootstrap -S System` is what should load that plist, which is why nothing runs the command:
  the launcher waits for a shellspawn that never starts because bootstrap never finishes.

  ELIMINATED for the ECONNREFUSED before it turned out to be a teardown artifact, kept because
  the same ideas will tempt the next reader: the daemon closing its socket (it binds fd 3 once
  and never closes it), the path resolving differently after vchroot (host and every guest
  /proc/PID/root stat the same inode), and an fd-parking race on 512/513/514 across launchd's
  shared thread fd table (with -tt, no other thread touches those fds anywhere near the send).

  Do NOT misread launchd's console banner: "launchd[1] has started up" followed by "Shutdown
  logging is enabled" is its STARTUP message, and the second line is about log configuration,
  not a shutdown. The guest also keeps its own RPC log at
  /tmp/dserver-client-rpc.log -- INSIDE the container's mount namespace, so it is not visible
  at that path on the host, which is why it reads as empty there.

  A note on tools: `ss -x` cannot see the daemon socket from the host, because unix sockets
  are netns-scoped and the daemon lives in the container's namespace. `lsof -U` can (it walks
  /proc/*/fd), and /proc/<daemon pid>/net/unix reads that namespace's table directly.

  Reproduce by dropping `DARLING_NO_LAUNCHD=1`. The daemon's own log is
  `<prefix>/darlingserver.log`, NOT the launcher's stderr. Still bypassed by
  `DARLING_NO_LAUNCHD=1`; not on the nix-builds critical path.
- Multi-user nix-daemon, `_nixbldN` setuid-in-userns, concurrent-build fcntl locking — open,
  production-hardening, not on the critical path (single-user M1 sidesteps it).

### CI + remote builder (built in Campaign 1, unvalidated — needs rework)
Machinery exists but was **never validated end-to-end on a live prefix** and predates the
Rust rewrite / launchd-bypass / 26.05 pin / submodule removal:
- CI: `.tangled/workflows/ci.yml` (tangled.org), `tests/*.nix`,
  `tests/nix/compatibility-matrix.sh`, dirserv-stubs check.
- Remote builder: `nix/darlingBuilderModule.nix` (`services.darling-builder`, sshd in prefix,
  `nix.buildMachines`), `scripts/darling-build-hook`, VM tests. Design (host
  `nix.buildMachines` → sshd in Darling → guest nix-daemon, shared store avoids SSH copy) is
  the north star but unexercised — and conflicts with one-command-per-container.

### Performance (measure during E; acceptable-if-slow for CI)
Baseline: spawn ~11–12× native (~28 ms/proc), compute ~7.6×. Spawn tax: ~22 ms (78%) = the
daemon fork/exec/RPC path. Landed and done: P0 ucred cache, P1 sigmask-free context switch,
P2 epoll re-arm memoize.
- **P0.7 spawn-path round-trips** — batch the fork/exec/registration RPCs. THE biggest
  wall-clock lever (~22 ms/spawn). High risk (IPC core).
- **P3 mach_msg same-task fast path** — handle same-task/local-port sends+recvs in-process.
  High risk. **P4** userspace signal deferral (drop the per-RPC sigmask pair). **P5** psynch
  uncontended CAS fast path. **P6** inline small OOL payloads into the datagram. **P8**
  scheduler futex contention (lock-free hot path) — deepest, do last.
- P0.5 dyld shared cache: DOWNGRADED to low (saves ~1.8 ms/spawn only).
- **Meta-blocker:** P3–P8 are core-cutting and not isolate-testable → gated on a reliable
  non-flaky spawn/IPC stress harness + fast daemon iteration (nix-ninja). Build that first.
- Already optimal (don't touch): BSD syscall dispatch (table-driven to Linux),
  `__ulock_wait/wake`→`futex(2)`, `vchroot_expand` path translation, cached
  `mach_task_self`/`mach_host_self`, getpwuid via glibc NSS.

### Watch-items (reopen on demand)
- **Symbol:** 6 lazy-bound FSEvents stubs (`_FSEventStream*`, CoreServices) only if a real
  binary calls them. Re-run `symbol-demand.sh` as the package set widens (larger C++/Swift
  broadens the surface). Supply = `nm --defined-only` ∪ full export-trie (both, or you
  undercount re-exports).
- **Syscall:** dup2-to-guarded-fd → return EBADF, don't abort; may recur in
  `fcntl(F_DUPFD)`/`dup`. Network.framework `nw_*` = 39 loud NULL stubs (real impl out of
  scope; nix never uses S3 for local builds).
- **`-111`/ECONNREFUSED:** doesn't fire on `net.unix.max_dgram_qlen=16384` hosts; the two
  guest busy-spin band-aids (sigexc.c, mach_traps.c) are vestigial there but needed on
  qlen=512. Proper host-independent fix (open): the daemon drains the socket to EAGAIN
  (recvmmsg loop) into an internal queue so it never backs up.
- **SIGFPE exec-fidelity flake (#44):** intermittent signal-8 in guest build/test binaries —
  retryable (nix build ×4), not a real error nor a Rust regression.

### Upstream adoption
Fork point `f39a29489` (2026-03); upstream idle on core as of 2026-07-19. Adopt only when a
concrete failure justifies it:
- Newer-toolchain build fixes (we build under clang 21): darling
  `e3fe4288 3f277ba5 9f485c91 ddd118d9 fc5c0666`, xnu `644decacee`. Cherry-pick onto our
  patched xnu; **don't bump the gitlink** (ours diverges).
- libkqueue `b0795a2e` (EVFILT_TIMER type-punning) if a kqueue-timer stall appears.
- Upstream darlingserver C++ tracking is obsolete (we're full-Rust). Fixing the launchd-boot
  hang would be an upstream-caliber rootless contribution.

---

## Operational notes / gotchas

- **Run recipe** (from a built `$out = nix build .#default`):
  `DSERVER_LIBEXEC_PATH=$out/libexec/darling
  DSERVER_MLDR_PATH=$out/libexec/darling/usr/libexec/darling/mldr DARLING_NO_LAUNCHD=1
  DPREFIX=<fresh dir> $out/bin/darling shell sh -c 'uname -sm'` → `Darwin x86_64`.
- **Phantom-path trap:** after any commit that touches a Rust crate, `.#default`'s hash
  changes and `nix eval .outPath` returns a NEW, UNBUILT path. Booting against it fails
  SILENTLY (daemon binary absent → launcher spins in its container-acquisition loop,
  wchan=hrtimer_nanosleep, empty log, `pgrep darlingserver` finds nothing). Always
  `nix build .#default` first (or assert `test -x $out/bin/darlingserver`). The same drift
  happens dirty→committed (a dirty-tree build and its commit hash differ).
- **mldr debug is gated** behind `MLDR_DEBUG=1` (default off). Do NOT grep for `[mldr]` to
  confirm a boot with the gate off — grep guest stdout (`Darwin`/`uname` output). The ungated
  ~15-line-per-process flood interleaving with stdout under `2>&1` was the false
  "concurrent-output flake"; measure output completeness with stdout/stderr SEPARATED.
- **mldr elfcall movaps constraint:** the guest calls elfcalls on an 8-byte-misaligned
  stack, so elfcall-reachable loader code must be movaps-free — no `mem::zeroed`/`Default` of
  a >8-byte struct on the stack (emits an aligned SSE store that #GPs); use `MaybeUninit` +
  scalar fills.
- **duct-tape two-phase init:** `dtape_init` then `dtape_init_in_thread` on a kernel
  microthread (psynch etc.); no hook in the 36-field vtable may ever be NULL (NULL → indirect
  call to 0x0).
- **RPC socket fork-safety:** sockets live at high fds + FD_CLOEXEC (so a forked subshell's
  low-fd dup2/close can't clobber them); the child does a socket-refresh.
- **One command per fresh container** (kill the stale daemon first). Keep the prefix path
  short — the daemon/shellspawn AF_UNIX socket lives under `<prefix>/var/run/` and overflows
  `sockaddr_un.sun_path` (~108 chars) on long paths; use `~/.darling`. Export
  `TMPDIR=$HOME/tmp` (the default Darwin temp dir EACCESes). Two-boot warm flow; harness
  output must be file-based, never piped through a reader (a leaked container holds the pipe
  write-end open and blocks EOF).
- **`__private_extern__` is not a linker bug (#57):** modern clang emits it as an *undefined*
  symbol; link the consumer against real ncurses/libtinfo, don't touch ld64. `-fcommon`
  doesn't fix it.
- **xnu pin gotcha:** the super-repo gitlink was a Campaign-1 rev never published upstream;
  darling-src fetches the pinned rev from `submodules.json` + applies `patches/xnu/*`.
  Cherry-pick upstream fixes onto our patched xnu; don't bump the pin blindly.
- **nix-ninja / mig gotchas:** merged `$out` conflates a checked-in `osfmk/**/X.h` with the
  same-named mig-generated header (10 collisions; `notify.h` is
  `_MIG_KERNEL_SPECIFIC_CODE_`-sensitive — force it to 1 via a duct-tape patch); mig edges
  need `-DKERNEL_USER -DMACH_KERNEL -DKERNEL`; `lower.nix` must `rm -f` a staged read-only
  source symlink at a declared output path (else mig `fopen`→EACCES). Full-graph nix-ninja is
  ~26k derivations — keep it OUT of `nix flake check`.

---

## The goal: full parity with upstream Darling

Everything upstream Darling supports, this project supports. Same libraries, same
frameworks, same features. What changes is only HOW it is built: buck2 instead of cmake,
Rust instead of the C daemon/launcher/loader, Nix instead of a system install. The port is
not a subset and is not finished when something merely boots.

Darling's own COMPONENTS hierarchy (cmake/darling_parse_components.cmake) is the measure,
because it is upstream's own decomposition:

    core -> system -> cli
    stock = cli + python + ruby + perl + dev_gui_common + dev_gui_frameworks_common
                  + dev_gui_stubs_common + gui_frameworks + gui_stubs
    all   = stock + jsc + webkit + cli_extra + cli_dev_gui_stubs

Where the port stands: `result-graph-ref` is the **cli** graph, and against it the port
covers 759 of 871 link edges (87%) with 6 unmapped install entries. So "87%" means 87% of
`cli`, not of Darling. `cli` is the current front; `stock` (which is what an ordinary
Darling install is) adds the GUI framework and stub trees plus the three scripting
languages; `all` adds WebKit and JavaScriptCore on top.

Order of attack, each stage gated on the one before:

1. **cli to 100%** -- close the last install entries and link edges, keep every check green.
2. **stock**. The flake already builds a `stock` graph (`packages.darling-graph`), so
   coverage can be measured against it the day cli is done. Expect the GUI frameworks to be
   the bulk of the work and dev-stubs to be cheap.
3. **all** -- jsc and webkit last; they are the largest single consumers and depend on
   everything before them.

Two things to hold onto while working the near term. Coverage numbers are always relative
to the graph in `result-graph-ref`, so state which component a percentage refers to.
And the reference build is a wasting asset: gen-mig-from-ninja.py, gen-buck-from-ninja.py
and gen-install-from-manifests.py all read it, and it disappears when cmake does, so every
generator needs to be re-runnable before that happens.

### Near-term queue (stage 1, cli)

Re-derive before trusting: `scripts/buck-coverage.py --missing` and
`scripts/gen-install-from-manifests.py`.

1. **The `all` component.** Sized and started; see "Stage 3" above. Three targets left
   and each has a known cause: JavaScriptCore (HANGS buck2 with the daemon at 0% CPU,
   reproducible across a daemon restart -- the real blocker), MachExceptions_xtrace_mig
   (does not link) and the 9 dev-stub frameworks the coverage metric hides behind their
   basename collision with the real frameworks.

   Start with the GUI framework dylibs: they are 362 of the 497 missing edges, and
   everything else in stock sits downstream of them. The 16 src/native ELF wrappers are
   already done, see below; the rest are Darling's own framework implementations under
   src/frameworks (101) and src/private-frameworks (45), plus 314 in src/external which is
   mostly python, ruby, perl and their extension modules.

   Stage 2 is effectively complete: 1354 of 1359 stock link edges. The five that remain
   (DBusKit, iokitd, bsdln, getuuid, elfdep) have their blocks removed and their causes
   written up above. The next item is THE STOCK SWITCH itself, which unlike everything
   else in stage 2 does change buck/prefix/BUCK, so it needs the runtime checks and the
   guest-nix milestone run rather than skipped.

   Beware NAME COLLISIONS when driving the generator by cmake target name across the wider
   graph. `X11` is both the src/native wrap_elf stub and CoreGraphics' X11 backend in
   src/frameworks, and `gen-buck-from-ninja.py --dylibs X11` silently picks the latter.
   cli was small enough that names were unique; stock is not.

2. **The 9 genuinely unported in-scope cli edges**: bsdln, elfdep, getuuid (host tools),
   csparser.bundle, lzfse, ping, vifs, libbind9_isccc.a, libopendirectory_internal.a. None
   is installed by the cli component, which is why UNMAPPED is 0 without them.

2. **launchservicesd** (darwin/frameworks/CoreServices/src/LaunchServices/launchservicesd;
   launchservicesd.m and LSBundle.m; links Foundation CoreServices FMDB sqlite3 z).
3. **hdiutil** (buck-src/darling-dmg; wants fuse, a HOST library, so check how the reference
   supplies it before assuming this is portable).
4. **Make the generators re-runnable** before the reference graph goes away.
   gen-mig-from-ninja.py is the worst case: buck-split-pins.py has since rewritten its
   committed blocks' `defs` to labels and changed `out_base`, so regenerating would clobber
   them and the last fix had to be spliced in by hand.
5. The other four host tools (bsdln, elfdep, getuuid, wrapgen). Not install entries and not
   used by the port, so low priority.
6. Task #11 per-action source filtering; #10/#12 NixOS VM; #63 exec-cross-arch; #57 linker;
   #26/#39 nix-ninja.

---

## Harness traps (read before writing a check or blaming the port)

Every one of these presented as "the port is broken" when it was the harness. The rule that
falls out: when a script and an identical hand-run disagree, the SCRIPT is the suspect. That
has been true six times running, each time a check freshly written.

- **`llvm-nm`, never bare `nm`, for Mach-O.** Inside `nix develop` the bare name is the
  clang wrapper's binutils nm, which answers "file format not recognized" and, with stderr
  discarded, yields an empty symbol list indistinguishable from a library missing
  everything.
- **Never `cmd | grep -q` in buck-test.sh.** grep -q exits on the first match, the writer
  takes SIGPIPE, and under `set -o pipefail` the pipeline reports FAILURE on a match.
  Capture into a variable and match with `case`.
- **file(1) strings**: `Mach-O 64-bit x86_64 dynamically linked shared library` and
  `Mach-O 64-bit x86_64 executable`. x86_64 comes BEFORE "dynamically". Copy an existing
  case rather than writing it from memory.
- **A whole-tree glob over a vendored pin dies on one dangling symlink**, failing the whole
  package with an error naming a subtree unrelated to what you built. Check with
  `find buck-src/<pin> -xtype l`; fix in `GLOB_EXCLUDE` in gen-buck-from-ninja.py.
- **MIG runs the C preprocessor over the .defs**, so its -D flags decide which routines
  EXIST. A mysteriously absent symbol from a MIG-generated library is a mig_flags question
  first.
- **Confirm a port with a direct `buck2 build <label>`**, never with buck-port.py's verdict.
  It also says "failed (no recognisable error)" when the cause is a package-level file
  error.
- **buck2 runs**: `nix develop --command bash -c 'source scripts/buck-env.sh; buck2 ...'`.
  Sourcing buck-env.sh alone is not enough: the direnv cache goes stale (rustc and bindgen
  went missing that way), and buck2's daemon inherits the client PATH at daemon START, so
  `buck2 killall` after fixing PATH.
- **Never pre-create DPREFIX.** darling treats an existing prefix as already set up, and
  launchd then boots into an unpopulated filesystem and stalls deterministically.
- **`pkill -f <pattern>` matches the command you are about to run** (exit 144). For
  containers use one ERE pattern: `pkill -9 -x 'mldr|darling|darlingserver|shellspawn'`.
- **A `jj git push` "Could not read from remote repository" is the remote**, not you
  (`ssh -o BatchMode=yes git@tangled.org` shows an IPv6 connect timeout). Retry.
- **Rebuild costs**: touching buck/generated/sdk_headers.bzl or the ksmig mig_flags rebuilds
  essentially everything, roughly 14,000 actions, about 20 minutes.
- **Known flakes**, re-run before believing a failure: buck-bash-check.sh fails roughly 1 in
  5 with a core dump (shared SIGFPE); buck-smoke-check.sh failed once at 11/31 then passed
  3/3.
- **All three runtime checks failing together is usually the MACHINE, not the tree**, and it
  has had three separate causes so far, so work through them in order before believing a
  regression. (1) Leftover containers, especially after a guest-nix milestone, which leaves
  its own prefix and daemon behind: `pkill -9 -x 'mldr|darling|darlingserver|shellspawn'`.
  (2) A wrong ARTIFACT at a right path, which looks identical from outside: read the
  `buck/prefix/BUCK` diff, which is how a dylib landing at usr/bin/login was found. (3) Load.
  Running the checks immediately after a large rebuild fails them; the same scripts pass on
  an idle machine minutes later. Boot the container by hand as the tiebreaker -- it takes
  seconds and tells you at once whether the tree or the harness is at fault:
  `DPREFIX=<fresh> DSERVER_LIBEXEC_PATH=$rt/libexec/darling
  DSERVER_MLDR_PATH=$rt/libexec/darling/usr/libexec/darling/mldr DARLING_NO_LAUNCHD=1
  $rt/bin/darling shell /bin/bash -c 'echo HELLO'`.
- **Measure before attributing slowness**, and revert a fix whose premise turns out wrong.
  gen-install-from-manifests.py's eight minutes were a per-entry repo walk, not the
  backtracking regex I first blamed.

Guest-nix milestone against a buck2 prefix: materialize it to an `rt` dir, then
`DSERVER_LIBEXEC_PATH=$rt/libexec/darling
DSERVER_MLDR_PATH=$rt/libexec/darling/usr/libexec/darling/mldr bash
scripts/build-hello-bypass.sh --mono $rt --prefix /tmp/darling-hello-m1-buck2`. Expect
`build_rc=0` and "Hello, world!".

---

## Working agreements

- **Verification is execution in a clean prefix**, not inspection. A task is done when its
  test runs green from a fresh prefix, not when the code looks right.
- **Small commits**, phase-tagged (`feat(phaseB.3): ...`), tests included, this doc updated
  in the same commit.
- **When blocked** (a nixpkgs-side change seems required, a licensing question, a
  divergence-class stop-the-line, or >1 day stuck on one signature): add a dated entry under
  Blockers with reproduction steps and stop that thread; take the next ranked item.
- **Insurance:** mirror the bootstrap-tools closure + key reference narinfo/nars to our own
  Cachix early (the oracle depends on cache retention past 26.05 EOL, end of 2026).

## Risk register

| Risk | Class | Mitigation |
|---|---|---|
| Silent output divergence (shim lies subtly) | correctness | Phase D oracle + stop-the-line |
| Stalls in event-loop-heavy builds (kqueue/poll) | fidelity | C.4b watchdog + stall triage |
| macOS-14 symbol surface larger than expected | scope | demand-driven ordering; stubs last |
| Mach IPC perf through userspace daemon | perf | measure during E; acceptable for CI |
| Cache retention past 26.05 EOL | infra | mirror reference closures to own Cachix |
| x86-only effort waste | strategy | ARCH tags; Phase F keeps the boundary honest |

---

## Blockers

Active blockers get a dated entry here (repro steps + what's stuck); resolved ones fold into
Gotchas or Open work. The known standing limitations are already tracked above — the launchd
portset deadlock (#47, bypassed by `DARLING_NO_LAUNCHD=1`), the SIGFPE exec-fidelity flake
(#44, retryable), and the nix-ninja full-graph `migHeaderIncsFor` blocker. Nothing else is
currently un-tracked.

## Grouped build: eval speed (done) vs incremental rebuild (open) — task #80

The grouped lowering (task #78) built every ninja edge's command + staging script as a Nix
string DURING EVAL, so whole-Darling eval was ~15-40 min, paid on every build (the graph-json
IFD busts Nix's eval cache). Fixed by **build-time lowering** (`nix/lib/nix-ninja/build/lower_group.py`,
flag `buildTimeLowering`): Nix eval now computes only each group's `{edge list, external-group
drvs}`; the tool reads the shared `graph.json` in the sandbox and does the rewrite/stage/run.
Measured: `darling-full-group-bt` eval **~58 s** (was ~35 min); migcom + libSystem green through
it. `darling-{group-test3,libsystem-group,full-group}-bt` exercise it; the legacy eval-time
`mkGroup` path is untouched behind the flag.

**Incremental rebuild is a separate, still-open problem, and it is NOT just source staging.**
A small source edit currently triggers a ~full recompile, because of a chain of store-path
couplings that all rehash on any source change:
- `cmakeSrcStore` (whole source tree) rehashes → CMake **re-configures** (~min) →
- `build.ninja` bakes absolute `cmake-src` / `cmake-ninja-configured` paths → the **graph-json
  (`graphDrv`) rehashes** (confirmed: `graphDrv` contains those store paths) →
- every bt group derivation reads `graphDrv` (and mounts the rewrite roots) → **all ~900 groups
  rebuild**.

So per-component source staging alone cannot deliver incrementality — `graphDrv` is the dominant
blocker. The full fix is three pieces, in order:
1. **Relativise the graph** so `graphDrv` is content-stable across source edits (strip the
   rewrite-root prefixes in the graph-json derivation; make it content-addressed so a re-config
   that yields byte-identical relative content keeps the same store path). This is the key
   enabler — without it (2)/(3) are moot.
2. **Per-component source subtrees** (`builtins.path` slice of `cmakeSrcStore/<component>`,
   content-addressed): a group depends only on its component's subtree, so editing one `.c`
   re-keys just that component. Keeps eval fast (no per-file `indivOf`/`readDir` in eval).
3. **Configure decoupling**: feed the configure derivation only CMake-relevant files so a
   `.c`-content edit does not re-run cmake at all.

Honest architectural note: this is exactly where the nix-ninja + IFD approach hits its
structural ceiling. Even done perfectly, it re-evaluates every build (~58 s) and its
incrementality is per-*derivation* (whole component recompiles), never per-*action* (one `.o` +
relink). **Buck2's persistent daemon avoids all of these store-path-rehash couplings by design**
(no configure/eval per build, per-action deps) — so the fast edit->rebuild inner loop is the
genuine case FOR a Buck2 port, distinct from the eval-speed problem (which was a fixable Nix
issue, now fixed). Recommendation: finish the full-green grind (#2) + implement (1)-(3) to get a
~1-3 min component-incremental loop with no port; treat Buck2 as the deliberate next step only if
that loop proves too slow for how Darling actually gets developed.

### Full-green grind (#2): where it stands (branch `wip-mega-group-unwind`)

The build-time path (`darling-full-group-bt`) grinds green through migcom -> libSystem -> duct-tape
-> libc -> and reaches the `security/*` / openssh tier. Mechanical gaps fixed along the way (all
committed): skip CMake housekeeping targets, shebang rewrites on staged sources AND generated script
outputs, rspfiles, ext-dir de-symlink before cp, command-referenced source staging, srcHeaders
non-header include-chain data (`.exp`/`.exp-in`/`.list`/`.ipp`), cctools ar+ranlib co-grouping by
OUTPUT tool dir.

Wall #2 from the earlier note (the `build-mig` dense-staging mega-SCC) is now UNWOUND, and the
duct-tape `notify.h` wall is FIXED. Committed on the branch (`639e374e`, `c723f265`):
- **notify.h source-restore** (`lower_group.py`): `mach/notify.h` exists as BOTH a hand-written
  source header (defines `MACH_NOTIFY_*` + the notify structs) and a mig re-emission (routine stubs
  only). The merged `$out` cannot hold both; mig's copy shadowed the source and broke every
  `<mach/notify.h>` kernel consumer. Fix: after a source-backed generated header is produced, restore
  the authoritative source copy over it (the mig `.c` consumers only need the structs, also in source).
- **mega-SCC unwind** (`lower.nix`): `rawHeaderProducerGroups` is now GROUP-LEVEL pure -- a mixed
  pure-gen + compile-dependent group no longer becomes a universal dep, so `build-mig` no longer
  absorbs duct-tape/bootstrap_cmds/... Mixed-group header producers retarget per-component via
  `migByCompDir` (which skips source-backed headers).
- **Tarjan SCC topo** (`lower_group.py`): the old Kahn fallback dumped a blocked SCC's edges in
  list order, mis-ordering acyclic producer->consumer pairs riding on the SCC (libc's dylib link ran
  before the `notify_firstpass` it links). Replaced with iterative Tarjan condensation (producers
  first; only genuine cycles emit as a block). Fixed libc.

Remaining `darling-full-group-bt` failures (18, taxonomised), in priority order:

1. **Source header shadows a SYSTEM header for a C compile (WALL #1, ~14 failures, dominant).**
   Confirmed via the compiler's `In file included from` chain (NOT a plain libcxx-on-`-I` issue):
   a C compile in `security/*` (e.g. `Security_x86_64_only_stuff`, `SecLogging.c`; `-std=gnu99`, no
   `-isysroot`) includes the SDK's `corecrypto/ccdigest.h` -> `cc.h` -> `cc_config.h:429`, which does
   `#include <endian.h>`. That resolves to `src/external/security/OSX/libsecurity_utilities/lib/
   endian.h` -- a SOURCE header shadowing the system `<endian.h>` because security's lib dir is on the
   compile's `-I` list -- and it drags in the security_utilities C++ chain (`utilities.h` -> `errors.h`
   -> `<exception>` -> libcxx `<cstddef>`), which is C++-only and explodes in C mode (`unknown type
   name 'using'`). So the trigger is `-I` precedence over SYSTEM headers, not libcxx per se. The
   reference build avoids it (some mix of `-isysroot`, `-iquote` vs `-I`, or not having that lib dir on
   the C compile's search path); our flat merged-`$out` + broad `-I` list does not. Fix needs deliberate
   header-search scoping so source-tree dirs do NOT shadow toolchain/SDK system headers for a compile
   that only asked for `<endian.h>` -- e.g. move project header dirs to `-iquote`/`-idirafter`, or add
   `-isysroot <SDK>` AND ensure system-name includes prefer the sysroot. This is the genuinely DEEP
   design wall (same class the eval-time `mkGroup` path would hit); needs a header-search decision, not
   a one-line strip. UNVERIFIED fix.
2. **libbsm cross-group `libSystem.B.dylib` staging (1 failure, foundational).** `libbsm` links the
   final umbrella `libSystem.B.dylib`; at BUILD time it is missing from libbsm's group sandbox. Ground
   truth (instrumented): libbsm's group ran but did NOT contain the libSystem.B producer edge, and the
   umbrella dylib was not ext-dir-staged in -- yet an eval probe reported the two edges in the SAME
   group with the producer in `extGids`. That **eval-vs-build grouping inconsistency** is the bug to
   chase next (idsInGroup vs the `--edges` actually passed, or a realProducers path-form mismatch).
3. **Generated data files not staged (2 failures).** openssh `ge25519_base.data`, libsecurity_cssm
   `derived_src/funcnames.gen` -- generated non-header data a compile reads, not reaching the sandbox.

Status: the eval floor is fixed+committed; the notify.h wall + mega-SCC are fixed+committed; libc
green. `main` stays green on the default (eval-time) path and `darling-{group-test3,libsystem-group}
-bt`; `libSystem-group-bt` is green on the build-time path too (re-verified). `full-group-bt` green
through libc; the dominant remaining blocker is WALL #1 (root-separation). The generic `nix-ninja`
lib is upstreamable to overby.me (sibling to its buck2/cargo libs; rust-ninja extractor already
lives there) -- root-separation is the main pre-upstream item.
