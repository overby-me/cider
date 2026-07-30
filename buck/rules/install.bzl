# Laying out a Darling PREFIX, which is what turns built artifacts into something that
# runs.
#
# The reference build says nothing useful about this in build.ninja: `install` is a single
# opaque edge that shells out to `cmake -P cmake_install.cmake`. The real statement is the
# per-directory cmake_install.cmake files cmake writes at configure time -- 433 entries
# across 65 destinations for the system component -- and nix/lib/darling-graph.nix now ships
# them so scripts/gen-install-from-manifests.py can generate these rules from the reference
# rather than transcribing 89 install() calls by hand (plan/buck2-port.md, bash milestone).
#
# Destinations follow Darling's cmake helpers: libraries and executables under
# libexec/darling/..., frameworks under
# libexec/darling/System/Library/Frameworks/<name>.framework/Versions/..., and the xtrace
# MIG stubs under libexec/darling/usr/lib/darling/xtrace-mig/.

load("//buck/rules:cc.bzl", "CcLibInfo")

def _prefix_tree_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + "__prefix", dir = True)

    # {destination path -> the artifact that lands there}. A dep contributes its DEFAULT
    # output, which for the port's rules is the dylib, the executable or the archive.
    mapping = {}
    for dest, dep in ctx.attrs.entries.items():
        info = dep[DefaultInfo]
        outs = info.default_outputs
        if len(outs) != 1:
            fail("prefix_tree: %s produces %d outputs, expected exactly one" % (dep.label, len(outs)))
        mapping[dest] = outs[0]

    # Files taken straight from the source tree (data, configs, certificates): they have no
    # producing target, so they arrive as sources.
    for dest, src in ctx.attrs.files.items():
        mapping[dest] = src

    staged = ctx.actions.symlinked_dir(out, mapping)

    return [
        DefaultInfo(default_output = staged),
        # A prefix is a tree, not a link input, so it carries no CcLibInfo. Named here so a
        # consumer that mistakenly puts a prefix on an include path fails loudly.
        CcLibInfo(
            include_dirs = [],
            exported_flags = [],
            static_libs = [],
            linker_flags = [],
        ),
    ]

prefix_tree = rule(
    impl = _prefix_tree_impl,
    attrs = {
        # {prefix-relative destination: target whose default output goes there}
        "entries": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # {prefix-relative destination: source file that goes there}
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # Prefixes compose: a subtree can be merged in whole.
        "deps": attrs.list(attrs.dep(), default = []),
    },
)
