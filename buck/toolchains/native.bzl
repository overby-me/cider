# The HOST (Linux/ELF) C toolchain: what builds darlingserver's duct-tape, the
# XNU kernel-emulation glue, and libsimple. Plain nixpkgs clang + binutils ar,
# no cross-compilation, no Mach-O.
#
# The Darwin/Mach-O cross toolchain (clang -target x86_64-apple-darwin*, the
# cctools ld64 from nix/cctools-port.nix, the SDK sysroot) is a separate
# toolchain rule, added when the guest tier is ported. Keeping them distinct is
# the point: a host compile can never accidentally inherit guest header roots.

NativeCcToolchainInfo = provider(
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

def _native_cc_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        NativeCcToolchainInfo(
            cc = ctx.attrs.cc,
            cxx = ctx.attrs.cxx,
            ar = ctx.attrs.ar,
            cflags = ctx.attrs.cflags,
            cxxflags = ctx.attrs.cxxflags,
            ldflags = ctx.attrs.ldflags,
        ),
    ]

native_cc_toolchain = rule(
    impl = _native_cc_toolchain_impl,
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
