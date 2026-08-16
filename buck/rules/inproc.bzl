# The artifacts buck2 makes IN-PROCESS, declared so they can be materialised without
# building anything.
#
# The Nix endpoint has to carry these as data: a written runner script, a symlinked
# dependency farm. No recorded argv can recreate them, so buck/bxl/materialize.bxl ensures
# them before the graph is dumped.
#
# It used to reach them by ensuring every node DEFAULT OUTPUT, which worked only because
# that compiled and linked the whole closure as a side effect. Removing it made the graph
# derivation three times faster and silently dropped 18 staged artifacts and 11 farms, all
# of them Rust, because a written runner is returned in no provider at all. Hence this: a
# rule that makes an in-process artifact says so, rather than being discovered by accident.
InProcInfo = provider(fields = ["artifacts"])
