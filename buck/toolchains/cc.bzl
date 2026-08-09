# A toolchain is a bundle of tools plus the flags every compile with it gets.
# There are two instances (see BUCK in this directory):
#
#   native_cc  the HOST (Linux/ELF) toolchain: plain nixpkgs clang + binutils ar.
#              Builds xnu-sys, the XNU emulation glue, libsimple, migcom.
#   darwin_cc  the GUEST (Darwin/Mach-O) cross toolchain: the same clang driving
#              `-target x86_64-apple-darwin20`, with the cctools Mach-O archiver
#              and (for links) Darling's own ld64.
#
# One provider serves both, because the difference between them IS just tools and
# flags. Keeping them separate targets is the point: a host compile can never
# accidentally inherit guest flags or header roots, and vice versa.

CcToolchainInfo = provider(
    fields = [
        # Command names (resolved from PATH) or absolute paths.
        "cc",
        "cxx",
        "ar",
        # Flags applied to every compile / archive done with this toolchain.
        "cflags",
        "cxxflags",
        "ldflags",
        # Mach-O links only: the linker to drive via -fuse-ld, and the dirs whose
        # tools the link invokes (-B). Empty for the host toolchain, which uses
        # whatever clang's driver already finds.
        "ld",
        "ld_search_dirs",
        # The linker as a BUILT TARGET rather than a path (#65). None keeps the string
        # path above, which is what every configuration used before ld64 was portable.
        #
        # WHY IT MATTERS: as a path, ld64 is an external nix derivation whose src is the
        # ENTIRE assembled project, so it rebuilds on every first-party edit, about 15 of the
        # 17.5 minutes such an edit costs. As a target its sources are under
        # buck-src/cctools-port, a PIN, which does not move when a first-party file changes.
        # The lowering needs nothing new for this: migcom is the same shape already, a host
        # tool built by this graph that appears in the INPUTS of all 110 actions running it.
        "ld_artifact",
    ],
)

def _cc_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        CcToolchainInfo(
            cc = ctx.attrs.cc,
            cxx = ctx.attrs.cxx,
            ar = ctx.attrs.ar,
            cflags = ctx.attrs.cflags,
            cxxflags = ctx.attrs.cxxflags,
            ldflags = ctx.attrs.ldflags,
            ld = ctx.attrs.ld,
            ld_search_dirs = ctx.attrs.ld_search_dirs,
            ld_artifact = (
                ctx.attrs.ld_target[DefaultInfo].default_outputs[0]
                if ctx.attrs.ld_target else None
            ),
        ),
    ]

cc_toolchain = rule(
    impl = _cc_toolchain_impl,
    attrs = {
        "ar": attrs.string(default = "ar"),
        "cc": attrs.string(default = "clang"),
        "cflags": attrs.list(attrs.string(), default = []),
        "cxx": attrs.string(default = "clang++"),
        "cxxflags": attrs.list(attrs.string(), default = []),
        # Path to a linker for -fuse-ld (Darling's own ld64 for Mach-O links).
        "ld": attrs.string(default = ""),
        "ldflags": attrs.list(attrs.string(), default = []),
        "ld_search_dirs": attrs.list(attrs.string(), default = []),
        # exec_dep: the linker runs on the machine doing the build, not on the target
        # platform it emits Mach-O for.
        "ld_target": attrs.option(attrs.exec_dep(), default = None),
    },
    is_toolchain_rule = True,
)
