for _v in $(env | sed -n 's/^\(NIX_\(CFLAGS\|LDFLAGS\)[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$_v"
done
export TMPDIR="$NIX_BUILD_TOP/tmp" BUCK_SCRATCH_PATH="$NIX_BUILD_TOP/scratch"
mkdir -p "$TMPDIR" "$BUCK_SCRATCH_PATH"

# This target's own actions, in the order buck2 ran them, which is a topological one:
# buck2 only runs an action once its inputs exist. Independent ones run CONCURRENTLY,
# bounded by NIX_BUILD_CORES the way any other builder is -- so balance this with
# `--cores` alongside `--max-jobs`, since 6 jobs each allowed 22 cores is 132 compiles.
_max=${NIX_BUILD_CORES:-1}
if [ "$_max" -lt 1 ]; then _max=1; fi
_running=0
# Checked EXPLICITLY, not left to set -e: a background job's failure does not abort the
# shell, and an unnoticed one here means a target quietly missing an object and a link
# error somewhere else entirely.
_reap() {
  if ! wait -n; then
    echo "buck2 lower: an action of %(label)s failed" >&2
    exit 1
  fi
  _running=$((_running - 1))
}
_spawn() {
  "$@" &
  _running=$((_running + 1))
  while [ "$_running" -ge "$_max" ]; do _reap; done
}
_drain() { while [ "$_running" -gt 0 ]; do _reap; done; }

# #66: THE ACTION SCRIPT IS READ, NOT COMPUTED HERE. It used to be a concatMapStrings
# over every action, escaping every argv element and running replaceStrings over each
# for the placeholders: per-argv work across 208,515 entries, in the EVALUATOR, on
# every invocation. scripts/buck-graph-to-specs.py now renders it inside the graph
# derivation, which already runs, and this reads the result.
#
# WHY IT IS EMBEDDED RATHER THAN SOURCED, which is the whole design question here and
# was got wrong first. Sourcing ${graph.specs}/<name>.sh looks better -- the drv stays
# tiny -- but graph.specs is ONE store path covering ALL 1,474 scripts, so changing a
# single action moves it and every target's build command with it. That is a universal
# rebuild on any BUCK edit, which is #37 again and undoes what #50, #53 and #55 bought.
# Embedding the text keeps the granularity exactly where it was: a target's drv changes
# only when ITS OWN script changes. The drv is no bigger than before either, because
# this is the same text the old concatMapStrings produced.
#
# THE CONTEXT COMES OFF for the same reason it does on graph.json above: keeping it
# would make every target depend on graph.specs and reintroduce the cascade the
# embedding exists to avoid. Nothing is lost, since the text is self-contained.
#
# THE PLACEHOLDERS STAY AS SHELL VARIABLES rather than being substituted. The script
# says ${CIDER_PH_CLANG} where the argv said @CLANG@, so the graph stays portable, the
# text names no store path, and this consumer fills them from its OWN inputs with the
# same values `fill` used. A clang bump therefore does not rewrite 8,704 command lines.
# (Escaped above because a # does NOT start a comment inside a Nix indented string: the
# whole block is one string, so a bare dollar-brace here is Nix antiquotation.)
