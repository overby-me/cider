# A BUNDLED PIN, PATCHED, AS A STORE PATH.
#
# A MANIFEST pin reaches the build already patched: cider-src.nix applies vendor/patches/<name>
# while materialising it, and ciderBuck2Graph.nix then copies the result out of pinPaths. A
# BUNDLED pin has no manifest entry, so it never went through that step, and both consumers
# copied vendor/pins/<name> RAW. That silently reverted the entire series, 37 patches for
# cocotron, and an unpatched pin builds clean and reports as a match: nothing downstream can
# tell. See task #224, and scripts/buck-src.nu, which does the same for a local materialisation.
#
# Produced as a store path rather than patched in the consumers, because that is how a manifest
# pin already arrives: the consumers stay a copy or a symlink and neither needs patch on PATH.
{pkgs}: {
  name,
  pin,
  patchDir,
}: let
  raw = builtins.path {
    name = "cider-bundled-${name}-unpatched";
    path = pin;
  };
in
  if !(builtins.pathExists patchDir)
  then raw
  else
    pkgs.runCommand "cider-bundled-${name}" {
      nativeBuildInputs = [pkgs.gnupatch pkgs.coreutils pkgs.findutils];
    } ''
      cp -a ${raw} $out
      chmod -R u+w $out
      for f in ${builtins.path {
        name = "cider-patches-${name}";
        path = patchDir;
      }}/*.patch; do
        # --forward, NOT --force: hunks are ALREADY PRESENT in vendor/pins/cocotron, and --force
        # puts a second copy of each one in. --forward skips them instead.
        #
        # EXIT 1 IS NOT A USABLE SIGNAL HERE and this guard is weaker than it looks: patch exits 1
        # both for a hunk it skipped as already applied and for one that genuinely FAILED, and
        # this pin produces some of each (3 of the latter, measured). So only 2 and above, a
        # malformed patch or a missing target file, stops the build. What actually establishes
        # that the series is right is a CONTENT comparison against the tree we compile:
        # scripts/checks/buck-bundled-patch-record-check.nu is that authority, and this output was
        # diffed against vendor/src/cocotron directly.
        rc=0
        patch -p1 --forward -s -d $out -i "$f" || rc=$?
        if [ "$rc" -ge 2 ]; then
          echo "cider-bundled-${name}: $(basename "$f") did not apply, exit $rc" >&2
          exit 1
        fi
      done
      # The skipped hunks leave these behind, and they would ship inside the pin.
      find $out -name '*.rej' -delete
      find $out -name '*.orig' -delete
    ''
