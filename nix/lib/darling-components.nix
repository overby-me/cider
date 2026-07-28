# darling-components (#26): generate one darling-component derivation per subproject
# in the DAG, each wired to its dependency components' deltas. The DAG comes from
# component-dag.py over the ninja graph (built once, read back via IFD). Returns
# an attrset { <name> = <drv>; ... } plus:
#   all  -- a symlinkJoin forcing every component to build (assembly input / CI)
#   dag  -- the components.json derivation (inspection)
#
# HONEST SCOPE: this is a COLD-PARALLEL build (build base once, then components in
# parallel), NOT an incrementally-isolated one. Leaf components reuse base cleanly;
# non-leaf components currently REBUILD their dependency (see darling-component.nix:
# ninja distrusts the mtime-1, un-logged overlaid delta). And every component still
# depends on base's whole source, so any source edit rehashes base + all components.
# For input-isolated incremental builds use nix-ninja per-edge (.#darling-ninja, #39).
#
# Because component-dag.py condenses cycles into SCC super-components, the graph is
# acyclic and the recursive `comps` attrset resolves as a fixpoint.
{
  pkgs,
  overby,
  graph ? import ./darling-graph.nix { inherit pkgs overby; },
  base ? import ./darling-base.nix { inherit pkgs; },
}:
let
  inherit (pkgs) lib;

  dagDrv = pkgs.runCommand "darling-component-dag"
    { nativeBuildInputs = [ pkgs.python3 ]; }
    ''
      python3 ${./component-dag.py} ${graph}/graph.json $out
    '';
  data = builtins.fromJSON (builtins.readFile dagDrv);

  # Recursive attrset: a component's deps map to the sibling derivations. Acyclic
  # (SCC-condensed), so this fixpoint terminates.
  comps = lib.listToAttrs (map (c: {
    name = c.name;
    value = import ./darling-component.nix {
      inherit pkgs base;
      name = c.name;
      # 0 SCCs at the cli scope, so each super-component has a single target; take
      # the head. (Multi-target SCCs would need darling-component `targets` support.)
      target = builtins.head c.targets;
      deps = map (dn: comps.${dn}) c.deps;
    };
  }) data.components);
in
comps
// {
  all = pkgs.symlinkJoin {
    name = "darling-all-components";
    paths = lib.attrValues comps;
  };
  dag = dagDrv;
}
