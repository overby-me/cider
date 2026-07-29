# A toolchain is a bundle of tools plus the flags every compile with it gets.
# There are two instances (see BUCK in this directory):
#
#   native_cc  the HOST (Linux/ELF) toolchain: plain nixpkgs clang + binutils ar.
#              Builds duct-tape, the XNU emulation glue, libsimple, migcom.
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
        "ldflags": attrs.list(attrs.string(), default = []),
    },
    is_toolchain_rule = True,
)
