# The buck2-built Darling as an installable package.
#
# The prefix that //buck/prefix:cider_prefix produces is already a complete Darling
# install -- bin/cider, bin/ciderd, and libexec/cider with everything under it.
# What it lacks is the two paths the daemon reads from the environment, which the cmake
# build bakes in and this port deliberately does not: a prefix with an absolute path
# compiled into it is not a prefix that can be moved.
#
# So this adds ONE file, and the USER FACING NAME IS `cider`, which is the whole point of
# doing it this way round. The real launcher is renamed to bin/cider-launcher and a small
# script takes its place at bin/cider, sets the two variables and execs it.
#
# THE OBVIOUS ARRANGEMENT DOES NOT WORK, which is why this one exists. The launcher re-execs
# /proc/self/exe to enter its user namespace, so a shell wrapper cannot sit at the path the
# launcher runs from: /proc/self/exe would be the shell. Renaming the launcher instead keeps
# that re-exec pointing at a real binary, because after the exec the running process IS the
# launcher, wherever it lives. Nothing in src/linux/launcher or src/linux/server hardcodes bin/cider
# (checked: both read /proc/self/exe), so the rename is invisible to the runtime.
#
# THE PREFIX TREE IS NOT TOUCHED. //buck/prefix still installs the launcher as bin/cider, and
# scripts/checks/* run against THAT tree with the variables set themselves. The rename lives
# here, in the packaging, where the moved-prefix problem lives.
{
  pkgs,
  # A prefix_tree output -- nix build .#cider-buck2-prefix, then
  # result/cider_prefix__prefix.
  prefix,
  # TWO PACKAGES CALL THIS, over the full prefix and the minimal one, and until the release
  # prep both derivations were named "cider-buck2". A user who installed the minimal build saw
  # the same name in their profile as one who installed the full build, with no way to tell
  # which they had.
  name ? "cider",
}:
pkgs.runCommand name {
  meta = {
    description = "Cider, built by the buck2 port (system component scope)";
    mainProgram = "cider";
  };
} ''
  mkdir -p "$out"
  cp -a ${prefix}/. "$out"/
  chmod -R u+w "$out"

  mv "$out/bin/cider" "$out/bin/cider-launcher"

  cat > "$out/bin/cider" <<EOF
  #!${pkgs.runtimeShell}
  # The daemon takes both from the environment (src/linux/server/src/container.rs), and the
  # launcher passes its environment through to it.
  export DSERVER_LIBEXEC_PATH="$out/libexec/cider"
  export DSERVER_MLDR_PATH="$out/libexec/cider/usr/libexec/cider/mldr"
  exec "$out/bin/cider-launcher" "\$@"
  EOF
  sed -i 's/^  //' "$out/bin/cider"
  chmod +x "$out/bin/cider"
''
