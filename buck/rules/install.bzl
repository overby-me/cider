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

# What a prefix_dir hands to a prefix_tree: {path inside the tree: artifact}.
#
# The directory ARTIFACT is not enough, because cmake's install(DIRECTORY) merges: zsh
# installs the contents of gen/install-this/ straight into libexec/darling, which already
# holds bin/, usr/ and everything else. symlinked_dir refuses overlapping destinations (and
# is right to -- a symlink at libexec/darling would shadow the rest), so a tree is expanded
# into its individual files and merged path by path instead.
PrefixDirInfo = provider(fields = ["files"])

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

    # Second names for things already in the tree. Darling installs these through
    # cmake/InstallSymlink.cmake, which creates the link in the build directory and then
    # install()s it as an ordinary file -- so the manifests name bin/sh but never say what it
    # points at, and nix/lib/darling-graph.nix records the link values separately.
    #
    # A prefix_tree is a symlink farm already, so a second name is the same artifact mapped
    # twice: whatever a consumer does with the tree (dereference it, copy it, mount it) it
    # gets a working bin/sh, and the basename it runs under -- which is exactly what bash
    # reads from argv[0] to decide whether to start in POSIX mode -- comes from the
    # destination, not from the artifact.
    for dest, target in ctx.attrs.symlinks.items():
        if target not in mapping:
            fail("prefix_tree: %s is a link to %s, which nothing installs" % (dest, target))
        mapping[dest] = mapping[target]

    # Whole directories, expanded per file so two trees can share a destination root.
    for dest, dep in ctx.attrs.trees.items():
        for rel, art in dep[PrefixDirInfo].files.items():
            full = "%s/%s" % (dest, rel) if dest else rel
            if full in mapping:
                fail("prefix_tree: %s is installed twice" % full)
            mapping[full] = art

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
        # {prefix-relative destination: another destination in this tree it names}
        "symlinks": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # {prefix-relative destination: prefix_dir target whose tree is merged in there}
        "trees": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # Prefixes compose: a subtree can be merged in whole.
        "deps": attrs.list(attrs.dep(), default = []),
    },
)

# A directory installed WHOLE.
#
# cmake's install(DIRECTORY) copies a tree with optional exclusions, and Darling uses it for
# the parts of the prefix that are data rather than build output: the base filesystem layout
# (src/external/files/{System,usr,private,Library}), terminfo, the locale assets, zsh's help.
# Ten of them, 4,600 files.
#
# It is a separate rule, and it lives in the PIN's package rather than in buck/prefix,
# because a glob cannot cross a package boundary -- buck-src/<pin> owns its files, so only a
# target there can name them. The prefix then maps the resulting directory into place, which
# also keeps buck/prefix/BUCK a list of destinations instead of 4,600 literal paths.
def _prefix_dir_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + "__dir", dir = True)

    mapping = {}
    for src in ctx.attrs.srcs:
        rel = src.short_path
        if ctx.attrs.strip:
            if not rel.startswith(ctx.attrs.strip):
                fail("prefix_dir: %s is not under strip prefix %s" % (rel, ctx.attrs.strip))
            rel = rel[len(ctx.attrs.strip):].lstrip("/")
        mapping[rel] = src

    return [
        DefaultInfo(default_output = ctx.actions.symlinked_dir(out, mapping)),
        PrefixDirInfo(files = mapping),
    ]

prefix_dir = rule(
    impl = _prefix_dir_impl,
    attrs = {
        # Usually a glob, with the install's REGEX ... EXCLUDE patterns as glob excludes.
        "srcs": attrs.list(attrs.source(), default = []),
        # Package-relative prefix removed from each source, so the tree is rooted where the
        # install destination expects rather than at the pin root.
        "strip": attrs.string(default = ""),
    },
)
