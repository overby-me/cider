# NixOS module for Darling — macOS compatibility layer for Linux.
#
# This module:
#   - Installs the Darling package
#   - Configures ciderd (userspace-only mode, no kernel module)
#   - Optionally sets up a persistent prefix via a systemd service
#   - Ensures required kernel features (overlayfs, user namespaces) are enabled
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.cider;
in
{
  options.programs.cider = {
    enable = lib.mkEnableOption "Darling, the macOS compatibility layer for Linux";

    package = lib.mkPackageOption pkgs "cider" { };

    prefix = {
      enable = lib.mkEnableOption "persistent Darling prefix via systemd service";

      path = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/cider";
        description = ''
          Path where the persistent Darling prefix is stored.
          This directory holds the macOS-like filesystem tree that
          Darling overlays at runtime.
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = ''
          User under which the cider-prefix service runs.
          The prefix is per-user in Darling, so this determines
          which user's prefix is initialised at boot.
        '';
      };
    };

    settings = {
      unprivilegedUserNamespaces = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to enable unprivileged user namespaces
          (`kernel.unprivileged_userns_clone`).  Required for
          ciderd to operate without a kernel module.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Install the cider package system-wide.
    environment.systemPackages = [ cfg.package ];

    # ciderd needs overlayfs and user namespaces to work
    # without its (deprecated) kernel module.
    boot.kernel.sysctl = lib.mkIf cfg.settings.unprivilegedUserNamespaces {
      "kernel.unprivileged_userns_clone" = 1;
    };

    # Ensure FUSE is available (darling-dmg uses it).
    environment.etc."fuse.conf".text = lib.mkDefault ''
      user_allow_other
    '';

    # Optional persistent prefix service.
    systemd.services.cider-prefix = lib.mkIf cfg.prefix.enable {
      description = "Initialise persistent Cider prefix";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.prefix.user;
        ExecStart = "${cfg.package}/bin/cider --prefix ${cfg.prefix.path} shell true";
        ExecStop = "${cfg.package}/bin/cider --prefix ${cfg.prefix.path} shutdown";
      };
    };

    # Create the prefix directory if the service is enabled.
    systemd.tmpfiles.rules = lib.mkIf cfg.prefix.enable [
      "d ${cfg.prefix.path} 0755 ${cfg.prefix.user} root -"
    ];
  };
}
