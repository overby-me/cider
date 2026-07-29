# Make a source file addressable as a target, so another package can use it.
#
# Buck2 requires a rule's `srcs` to live in that rule's own package, so a file
# shared across packages (a generator script, mig.sh) needs a target to cross the
# boundary. This is the same `export_file` the prelude provides.

def _export_file_impl(ctx):
    return [
        DefaultInfo(default_output = ctx.attrs.src),
        RunInfo(args = cmd_args(ctx.attrs.src)),
    ]

export_file = rule(
    impl = _export_file_impl,
    attrs = {
        "src": attrs.source(),
    },
)
