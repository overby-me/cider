# Laying out a Darling PREFIX, which is what turns built artifacts into something that
# runs.
#
# The reference build says nothing useful about this in build.ninja: `install` is a single
# opaque edge that shells out to `cmake -P cmake_install.cmake`. The real statement is the
# per-directory cmake_install.cmake files cmake writes at configure time -- 433 entries
# across 65 destinations for the system component -- and nix/lib/cider-graph.nix now ships
# them so scripts/gen-install-from-manifests.py can generate these rules from the reference
# rather than transcribing 89 install() calls by hand (plan/buck2-port.md, bash milestone).
#
# Destinations follow Darling's cmake helpers: libraries and executables under
# libexec/cider/..., frameworks under
# libexec/cider/System/Library/Frameworks/<name>.framework/Versions/..., and the xtrace
# MIG stubs under libexec/cider/usr/lib/cider/xtrace-mig/.

load("//buck/rules:cc.bzl", "CcLibInfo")

# What a prefix_dir hands to a prefix_tree: {path inside the tree: artifact}.
#
# The directory ARTIFACT is not enough, because cmake's install(DIRECTORY) merges: zsh
# installs the contents of gen/install-this/ straight into libexec/cider, which already
# holds bin/, usr/ and everything else. symlinked_dir refuses overlapping destinations (and
# is right to -- a symlink at libexec/cider would shadow the rest), so a tree is expanded
# into its individual files and merged path by path instead.
load("//buck/rules:inproc.bzl", "InProcInfo")

PrefixDirInfo = provider(fields = ["files"])

# Three kinds of entry, in an order that matters: a directory before anything inside it, and
# a link after whatever it points at, so that a link into the tree resolves as soon as it is
# made.
#
# Installed artifacts are COPIED, not linked, which makes the tree SELF-CONTAINED. That is
# what lets the same rule serve both consumers: the daemon overlay-mounts this directory as
# the container's read-only root, where a link to a host path leads nowhere, and the Nix
# endpoint turns it into a store path, where a link into a build directory dangles the
# moment the build ends. 107 MB, and only when an input changes.
_BUILD_PREFIX = """set -euo pipefail
out="$1"; manifest="$2"
mkdir -p "$out"
# The manifest travels WITH the tree, at the prefix root rather than inside
# libexec/cider, so it is never part of what the container mounts. Nothing depends on it
# now that artifacts are copied and only the layout's own links remain symlinks, but it is
# the one place that says what the prefix is MEANT to contain, which is worth having next
# to what it does contain.
cp "$manifest" "$out/.prefix-manifest.tsv"
while IFS=$'\\t' read -r kind dest src; do
  case "$kind" in
    dir)  mkdir -p "$out/$dest" ;;
    link)
      mkdir -p "$out/$(dirname "$dest")"
      # A destination that is already a REAL directory is left alone, which is what the
      # reference does too: install(DIRECTORY DESTINATION libexec/cider/var/root) runs
      # before the install(CODE) that would link var -> private/var, and cmake -E
      # create_symlink then fails into an execute_process nobody checks. Linking anyway
      # would put the link INSIDE the directory (var/var), dangling.
      if [ -d "$out/$dest" ] && [ ! -L "$out/$dest" ]; then
        :
      else
        ln -sfn "$src" "$out/$dest"
      fi
      ;;
    # -L: a file entry's source may itself be a link -- a prefix_dir stages its tree as a
    # symlink farm -- and it is the CONTENT that has to land in the prefix. Only `link`
    # entries stay links, which is what keeps Volumes/DarlingEmulatedDrive from being
    # followed to the root of the machine.
    file) mkdir -p "$out/$(dirname "$dest")"; cp -L -p --reflink=auto "$src" "$out/$dest" ;;
    # install(FILES ... PERMISSIONS ... OWNER_EXECUTE): the mode comes from the install
    # entry, not from the source tree. chmod is safe because the entry is a COPY -- the
    # dirserv stubs are 644 in the repo and have to be 755 in the prefix.
    exec) mkdir -p "$out/$(dirname "$dest")"; cp -L -p --reflink=auto "$src" "$out/$dest"; chmod 0755 "$out/$dest" ;;
    *)    echo "prefix_tree: unknown entry kind '$kind' for $dest" >&2; exit 1 ;;
  esac
done < "$manifest"
"""

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

    # The same, for entries whose install() grants an EXECUTE permission. Kept apart from
    # `files` because the difference is the MODE the file lands with, which the manifest has
    # to carry through to the builder.
    exec_mapping = {}
    for dest, src in ctx.attrs.exec_files.items():
        exec_mapping[dest] = src

    # Second names for things already in the tree. Darling installs these through
    # cmake/InstallSymlink.cmake, which creates the link in the build directory and then
    # install()s it as an ordinary file -- so the manifests name bin/sh but never say what it
    # points at, and nix/lib/cider-graph.nix records the link values separately.
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

    # Built by a script from a MANIFEST rather than by symlinked_dir, because a Darling
    # prefix is not only files. The reference also installs
    #
    #   17 EMPTY directories, through `install(DIRECTORY DESTINATION ...)` with no source.
    #      libexec/cider/proc is one of them, and without it the daemon cannot mount
    #      procfs for the container's PID namespace and the container init dies at once.
    #   74 SYMLINKS to paths outside the tree, through install(CODE) blocks that run
    #      cmake -E create_symlink: etc -> private/etc, var -> private/var,
    #      private/etc/mtab -> /proc/self/mounts, Volumes/DarlingEmulatedDrive -> /.
    #
    # symlinked_dir maps destinations to artifacts and can express neither. The manifest can
    # express all three kinds, and the tree is still built from links rather than copies, so
    # it costs no more than the farm did.
    lines = []
    for dest in sorted(ctx.attrs.dirs):
        lines.append(cmd_args("dir", dest, "", delimiter = "\t"))
    for dest in sorted(mapping):
        lines.append(cmd_args("file", dest, mapping[dest], delimiter = "\t"))
    for dest in sorted(exec_mapping):
        lines.append(cmd_args("exec", dest, exec_mapping[dest], delimiter = "\t"))
    for dest in sorted(ctx.attrs.links):
        lines.append(cmd_args("link", dest, ctx.attrs.links[dest], delimiter = "\t"))

    # THE MANIFEST IS TEXT ONLY, and the sources it names are attached HIDDEN instead.
    #
    # This used to be `write(..., with_inputs = True)`, and with_inputs attaches every artifact
    # the manifest NAMES as an input of the resulting artifact. The manifest names every file
    # the prefix installs. buck/bxl/materialize.bxl ensures InProcInfo.artifacts, and the
    # manifest is in there, so "materialize the in-process artifacts" quietly meant BUILD THE
    # ENTIRE PREFIX -- inside the graph DUMP, which is supposed to run no compiles at all.
    # MEASURED: with a skeleton tree the dump tried to compile libtrustd_obj, cider-coredump,
    # dyld, compiler_rt_final and system_dyld_final, every one of them something this manifest
    # lists. On the real tree they simply succeeded, which is why it went unnoticed for so long,
    # and removing them roughly HALVED the graph derivation, 18m34s to about 10 minutes.
    #
    # The prefix build still needs those sources materialised before build.sh copies from them,
    # so they go on as hidden arguments: inputs to the action, absent from the command line.
    #
    # NOT A SECOND `write`, and that was measured rather than assumed. Writing the same text a
    # second time with with_inputs set worked, but it INSERTS AN ACTION, and the lowering keys
    # on action ids: the graph equivalence check reported every action identical and every
    # staged artifact identical, with only the prefix target ids renumbered (build.sh 1 to 2,
    # the prefix 2 to 3), which is enough to move the derivation and rebuild the endpoint for
    # no gain. Attaching the artifacts directly adds no action at all.
    manifest = ctx.actions.write(ctx.label.name + "__manifest.tsv", lines)
    builder = ctx.actions.write(ctx.label.name + "__build.sh", _BUILD_PREFIX, is_executable = True)
    cmd = cmd_args(["bash", builder, out.as_output(), manifest])
    cmd.add(cmd_args(hidden = list(mapping.values()) + list(exec_mapping.values())))
    ctx.actions.run(
        cmd,
        category = "prefix_tree",
        identifier = ctx.label.name,
    )
    staged = out

    return [
        DefaultInfo(default_output = staged),
        # The manifest and the builder script are written, not run, so nothing else reaches
        # them and the Nix endpoint has to carry both.
        InProcInfo(artifacts = [manifest, builder]),
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
        # The same, for a source file whose install() grants an EXECUTE permission: it
        # lands 0755 whatever mode it has in the repo. The Directory Services stubs are
        # 644 here and 755 once installed.
        "exec_files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # {prefix-relative destination: another destination in this tree it names}
        "symlinks": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # {prefix-relative destination: prefix_dir target whose tree is merged in there}
        "trees": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # Destinations created as EMPTY directories (install(DIRECTORY) with no source).
        "dirs": attrs.list(attrs.string(), default = []),
        # {prefix-relative destination: literal symlink value}, for links whose target is
        # not a file this tree installs -- /proc/self/mounts, /dev/log, or a relative path
        # resolved inside the running container.
        "links": attrs.dict(attrs.string(), attrs.string(), default = {}),
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

# The same, for a directory the build GENERATES rather than one the repo ships.
#
# install(DIRECTORY) does not care where its source came from, but buck2 does: prefix_dir
# globs, and a glob cannot see something no action has written yet. Security's
# Certificates.bundle is the case -- generate-ca-bundle.py reads 159 .crt files plus eight
# plists and writes a bundle of DER tables and property lists -- so the tree arrives as one
# directory artifact and the paths inside it are named.
#
# `contents` is DECLARED rather than discovered because a prefix_tree needs its
# path -> artifact mapping at analysis time, while what an action wrote is only knowable
# after it has run. Declaring it also turns the rule into an assertion about the generator:
# if the script stops writing one of these, the build fails here, instead of quietly
# shipping a bundle with a hole in it that only surfaces when Security tries to verify a
# certificate chain.
def _prefix_gen_dir_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + "__gen", dir = True)

    # The generator takes its output directory as argv, cmake-style, and creates it. Its
    # inputs are reached through its own location on disk (path.realpath(__file__) and
    # siblings), which buck2 cannot see, so they are declared hidden: nothing on the command
    # line names them, but changing one still rebuilds the bundle.
    cmd = cmd_args([ctx.attrs.interpreter, ctx.attrs.script, out.as_output()])
    cmd.add(ctx.attrs.args)
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    ctx.actions.run(cmd, category = "prefix_gen_dir", identifier = ctx.label.name)

    mapping = {}
    for rel in ctx.attrs.contents:
        key = rel
        if ctx.attrs.strip:
            if not key.startswith(ctx.attrs.strip):
                fail("prefix_gen_dir: %s is not under strip prefix %s" % (rel, ctx.attrs.strip))
            key = key[len(ctx.attrs.strip):].lstrip("/")
        mapping[key] = out.project(rel)

    return [
        DefaultInfo(default_output = out),
        PrefixDirInfo(files = mapping),
    ]

prefix_gen_dir = rule(
    impl = _prefix_gen_dir_impl,
    attrs = {
        # Trailing arguments after the output directory.
        "args": attrs.list(attrs.string(), default = []),
        # Every file the generator writes, relative to the output directory.
        "contents": attrs.list(attrs.string()),
        "interpreter": attrs.string(default = "python3"),
        "script": attrs.source(),
        # Inputs the script reads without being told where they are.
        "srcs": attrs.list(attrs.source(), default = []),
        # Prefix removed from each entry, so the tree is rooted where the install
        # destination expects. install(DIRECTORY .../Certificates.bundle DESTINATION x)
        # puts the bundle at x/Certificates.bundle, so the tree mapped in there must start
        # INSIDE the bundle.
        "strip": attrs.string(default = ""),
    },
)
