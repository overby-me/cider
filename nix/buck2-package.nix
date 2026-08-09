# The buck2-built Darling as an installable package.
#
# The prefix that //buck/prefix:cider_prefix produces is already a complete Darling
# install -- bin/cider, bin/ciderd, and libexec/cider with everything under it.
# What it lacks is the two paths the daemon reads from the environment, which the cmake
# build bakes in and this port deliberately does not: a prefix with an absolute path
# compiled into it is not a prefix that can be moved.
#
# So this adds ONE file: bin/cider-buck2, which sets them and execs the real launcher.
# Not makeWrapper, and not a wrapper over bin/cider itself: the launcher re-execs
# /proc/self/exe to enter its user namespace, and with a shell wrapper in that position
# /proc/self/exe is the shell, not the launcher.
{
  pkgs,
  # A prefix_tree output -- nix build .#cider-buck2-prefix, then
  # result/cider_prefix__prefix.
  prefix,
}:
pkgs.runCommand "cider-buck2" {
  meta = {
    description = "Cider, built by the buck2 port (system component scope)";
    mainProgram = "cider-buck2";
  };
} ''
  mkdir -p "$out"
  cp -a ${prefix}/. "$out"/
  chmod -R u+w "$out"

  cat > "$out/bin/cider-buck2" <<EOF
  #!${pkgs.runtimeShell}
  # The daemon takes both from the environment (linux/server/src/container.rs), and the
  # launcher passes its environment through to it.
  export DSERVER_LIBEXEC_PATH="$out/libexec/cider"
  export DSERVER_MLDR_PATH="$out/libexec/cider/usr/libexec/cider/mldr"
  exec "$out/bin/cider" "\$@"
  EOF
  sed -i 's/^  //' "$out/bin/cider-buck2"
  chmod +x "$out/bin/cider-buck2"
''
