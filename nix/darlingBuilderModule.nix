# NixOS module: Darling-based x86_64-darwin remote builder
#
# This module sets up a Darling instance as a Nix remote builder for
# x86_64-darwin, allowing a Linux host to build Darwin packages without
# Apple hardware.  It manages:
#
#   - SSH key generation for the Nix daemon ↔ Darling sshd connection
#   - Darling prefix initialisation (Nix install, sshd setup)
#   - A systemd service running sshd inside the Darling prefix
#   - Registration as a `nix.buildMachines` entry
#   - Optional /nix/store sharing between host and Darling prefix
#
# Usage (in a NixOS configuration):
#
#   {
#     imports = [ ./path/to/darling-nix/nix/darlingBuilderModule.nix ];
#
#     services.darling-builder = {
#       enable = true;
#       maxJobs = 4;
#       shareStore = true;
#     };
#   }
#
# After `nixos-rebuild switch`:
#
#   nix build nixpkgs#hello --system x86_64-darwin
#
# See: PLAN.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.darling-builder;

  # Helper: script that initialises the Darling prefix for builder use.
  # Idempotent — safe to run on every service start.
  prefixInitScript = pkgs.writeShellScript "darling-builder-init" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ cfg.package pkgs.coreutils pkgs.openssh ]}:$PATH"

    DPREFIX="${cfg.prefixPath}"
    export DPREFIX

    echo "[darling-builder] Initialising prefix at $DPREFIX ..."

    # First run creates the prefix (may take a while)
    darling --prefix "$DPREFIX" shell true

    # ── SSH setup ────────────────────────────────────────────────────
    # Generate host keys inside the prefix if missing
    darling --prefix "$DPREFIX" shell \
      bash -c 'test -f /etc/ssh/ssh_host_ed25519_key || ssh-keygen -A'

    # Write a minimal sshd_config
    darling --prefix "$DPREFIX" shell bash -c 'cat > /etc/ssh/sshd_config << EOF
Port ${toString cfg.port}
ListenAddress 127.0.0.1
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
UsePrivilegeSeparation no
Subsystem sftp /usr/libexec/sftp-server
AcceptEnv NIX_REMOTE NIX_PATH NIX_SSL_CERT_FILE
EOF
'

    # Install the public key
    darling --prefix "$DPREFIX" shell mkdir -p /var/root/.ssh
    cat "${cfg.sshKeyPath}.pub" | \
      darling --prefix "$DPREFIX" shell tee /var/root/.ssh/authorized_keys > /dev/null
    darling --prefix "$DPREFIX" shell chmod 700 /var/root/.ssh
    darling --prefix "$DPREFIX" shell chmod 600 /var/root/.ssh/authorized_keys

    # ── Nix configuration ────────────────────────────────────────────
    darling --prefix "$DPREFIX" shell mkdir -p /etc/nix

    darling --prefix "$DPREFIX" shell bash -c 'cat > /etc/nix/nix.conf << EOF
# Managed by NixOS darling-builder module — do not edit
build-users-group =
sandbox = false
experimental-features = nix-command flakes
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
EOF
'

    # ── Shared store (optional) ──────────────────────────────────────
    ${lib.optionalString cfg.shareStore ''
      # Darling exposes the host root at /Volumes/SystemRoot inside the
      # prefix, so /Volumes/SystemRoot/nix is the host's /nix.
      # We symlink /nix -> /Volumes/SystemRoot/nix to share the store
      # and avoid expensive SSH-based copying.
      darling --prefix "$DPREFIX" shell bash -c '
        if [ ! -L /nix ] && [ ! -d /nix/store ]; then
          rm -rf /nix 2>/dev/null || true
          ln -sf /Volumes/SystemRoot/nix /nix
        elif [ -L /nix ]; then
          # Already a symlink — make sure it points to the right place
          target=$(readlink /nix)
          if [ "$target" != "/Volumes/SystemRoot/nix" ]; then
            rm /nix
            ln -sf /Volumes/SystemRoot/nix /nix
          fi
        fi
      '
    ''}

    # ── Directory Services stubs (for multi-user Nix if needed) ──────
    # Verify the stubs are installed (they ship with our Darling package)
    for tool in dseditgroup sysadminctl dscl; do
      if ! darling --prefix "$DPREFIX" shell test -x "/usr/sbin/$tool"; then
        echo "[darling-builder] WARNING: /usr/sbin/$tool not found in prefix"
      fi
    done

    # Verify sandbox-exec stub
    if ! darling --prefix "$DPREFIX" shell test -x /usr/bin/sandbox-exec; then
      echo "[darling-builder] WARNING: /usr/bin/sandbox-exec not found in prefix"
    fi

    # ── Ensure /var/empty exists (home dir for build users) ──────────
    darling --prefix "$DPREFIX" shell mkdir -p /var/empty
    darling --prefix "$DPREFIX" shell chmod 555 /var/empty

    # ── sshd privilege-separation directory ───────────────────────────
    darling --prefix "$DPREFIX" shell mkdir -p /var/empty/sshd
    darling --prefix "$DPREFIX" shell chmod 755 /var/empty/sshd

    echo "[darling-builder] Prefix initialisation complete."
  '';

  # Connectivity test script — useful for manual debugging
  connectivityTestScript = pkgs.writeShellScript "darling-builder-test" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.openssh pkgs.coreutils ]}:$PATH"

    echo "Testing SSH connectivity to Darling builder ..."
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "${cfg.sshKeyPath}" \
        -p ${toString cfg.port} \
        root@127.0.0.1 \
        echo "SSH connection OK"

    echo "Testing Nix inside Darling builder ..."
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "${cfg.sshKeyPath}" \
        -p ${toString cfg.port} \
        root@127.0.0.1 \
        'source /Users/root/.nix-profile/etc/profile.d/nix.sh 2>/dev/null || true; nix --version'

    echo "Testing nix store ping ..."
    nix store ping --store "ssh://root@127.0.0.1?ssh-key=${cfg.sshKeyPath}" \
        --option ssh-port ${toString cfg.port} \
      && echo "nix store ping OK" \
      || echo "nix store ping FAILED (this may be expected if Nix is not yet installed in the prefix)"

    echo ""
    echo "Darling builder connectivity test complete."
  '';
in
{
  options.services.darling-builder = {
    enable = lib.mkEnableOption "Darling-based x86_64-darwin remote Nix builder";

    package = lib.mkPackageOption pkgs "darling" { };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = ''
        SSH port for the sshd instance running inside the Darling prefix.
        Uses 2222 by default to avoid conflict with the host's sshd on port 22.
      '';
    };

    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Maximum number of concurrent builds the Darling builder will run.
        Set this based on available CPU cores; Darwin builds inside Darling
        are slower than native, so a conservative value is recommended.
      '';
    };

    speedFactor = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = ''
        Speed factor for this builder relative to others.  Lower values
        mean Nix will prefer faster (native) builders when available.
        Use 1 for a Darling-only setup, or a low value (1-5) when real
        macOS builders are also configured.
      '';
    };

    shareStore = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to share the host's /nix/store with the Darling prefix
        via a symlink through /Volumes/SystemRoot/nix.  This avoids the
        expensive step of copying store paths over SSH and makes build
        outputs immediately available on the host.

        When disabled, Nix will use SSH-based store path transfer, which
        is slower but simpler and avoids any store database conflicts.
      '';
    };

    sshKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix/darling-builder-key";
      description = ''
        Path to the SSH ed25519 private key used by the host's Nix daemon
        to connect to the sshd running inside Darling.  The corresponding
        public key (.pub) is installed into the Darling prefix's
        authorized_keys.

        The key is auto-generated on first activation if it doesn't exist.
      '';
    };

    prefixPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/darling-builder";
      description = ''
        Path to the Darling prefix used by the builder.  This is a
        separate prefix from the default (~/.darling) to avoid
        interference with interactive Darling usage.
      '';
    };

    supportedFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of supported features to advertise for this builder.
        Derivations can require specific features (e.g. "big-parallel")
        and will only be scheduled on builders that support them.
      '';
    };

    mandatoryFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of mandatory features for this builder.  Only derivations
        that explicitly require ALL of these features will be scheduled
        on this builder.  Usually left empty.
      '';
    };

    installNix = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to automatically install Nix inside the Darling prefix
        during service startup.  Requires network access to download the
        Nix installer.  If false (default), you must install Nix manually
        using scripts/install-nix-in-darling.nu before enabling the builder.

        NOTE: This is a slow operation on first run (downloads ~50MB) and
        is best done manually.  Set to true only for automated/CI setups.
      '';
    };

    nixVersion = lib.mkOption {
      type = lib.types.str;
      default = "2.24.12";
      description = ''
        Version of Nix to install inside the Darling prefix when
        `installNix` is true.  Must match a release on
        https://releases.nixos.org/nix/.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure the base Darling program is available
    programs.darling.enable = true;
    programs.darling.package = cfg.package;

    # ── SSH key generation ───────────────────────────────────────────
    # Generate the ed25519 keypair on system activation if it doesn't
    # already exist.  The key is owned by root with mode 600.
    system.activationScripts.darling-builder-keys = lib.stringAfter [ "users" ] ''
      if [ ! -f "${cfg.sshKeyPath}" ]; then
        echo "[darling-builder] Generating SSH keypair at ${cfg.sshKeyPath} ..."
        mkdir -p "$(dirname "${cfg.sshKeyPath}")"
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f "${cfg.sshKeyPath}" -C "darling-builder@$(hostname)"
        chown root:root "${cfg.sshKeyPath}" "${cfg.sshKeyPath}.pub"
        chmod 600 "${cfg.sshKeyPath}"
        chmod 644 "${cfg.sshKeyPath}.pub"
      fi
    '';

    # ── Prefix directory ─────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d ${cfg.prefixPath} 0755 root root -"
    ];

    # ── Darling builder service ──────────────────────────────────────
    # This service:
    #   1. Initialises the Darling prefix (idempotent)
    #   2. Optionally installs Nix
    #   3. Starts sshd inside the prefix (foreground, Type=simple)
    #
    # sshd runs in the foreground (-D) so systemd can manage its lifecycle.
    systemd.services.darling-builder = {
      description = "Darling x86_64-darwin Nix remote builder";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "nss-lookup.target" ];

      path = [ cfg.package pkgs.coreutils pkgs.openssh pkgs.curl ];

      environment = {
        DPREFIX = cfg.prefixPath;
        HOME = "/root";
      };

      serviceConfig = {
        Type = "simple";

        # Initialise the prefix before starting sshd
        ExecStartPre = [
          "+${prefixInitScript}"
        ] ++ lib.optional cfg.installNix
          "+${pkgs.writeShellScript "darling-builder-install-nix" ''
            set -euo pipefail
            export PATH="${lib.makeBinPath [ cfg.package pkgs.coreutils pkgs.curl pkgs.gnutar pkgs.xz ]}:$PATH"
            export DPREFIX="${cfg.prefixPath}"

            # Skip if Nix is already installed
            if darling --prefix "$DPREFIX" shell test -x /nix/var/nix/profiles/default/bin/nix 2>/dev/null; then
              echo "[darling-builder] Nix is already installed, skipping."
              exit 0
            fi

            # Download and install Nix
            nix_version="${cfg.nixVersion}"
            installer_name="nix-''${nix_version}-x86_64-darwin"
            installer_url="https://releases.nixos.org/nix/nix-''${nix_version}/''${installer_name}.tar.xz"

            tmpdir=$(mktemp -d)
            trap "rm -rf $tmpdir" EXIT

            echo "[darling-builder] Downloading Nix $nix_version ..."
            curl -fsSL -o "$tmpdir/nix-installer.tar.xz" "$installer_url"

            echo "[darling-builder] Extracting ..."
            mkdir -p "$tmpdir/extract"
            tar -xf "$tmpdir/nix-installer.tar.xz" -C "$tmpdir/extract"

            installer_dir=$(find "$tmpdir/extract" -maxdepth 1 -type d -name 'nix-*' | head -1)
            if [ -z "$installer_dir" ]; then
              echo "[darling-builder] ERROR: Could not find extracted installer directory"
              exit 1
            fi

            # Patch: force single-user / no-daemon mode
            sed -i 's/INSTALL_MODE=daemon/INSTALL_MODE=no-daemon/g' "$installer_dir/install"

            # Copy into the Darling prefix
            prefix_tmp="$DPREFIX/private/tmp/nix-installer"
            mkdir -p "$prefix_tmp"
            cp -a "$installer_dir/"* "$prefix_tmp/"
            chmod +x "$prefix_tmp/install"

            echo "[darling-builder] Running Nix installer inside Darling ..."
            darling --prefix "$DPREFIX" shell env \
              NIX_INSTALLER_NO_MODIFY_PROFILE=0 \
              bash /tmp/nix-installer/install --no-daemon

            rm -rf "$prefix_tmp"
            echo "[darling-builder] Nix installation complete."
          ''}";

        ExecStart = "${cfg.package}/bin/darling --prefix ${cfg.prefixPath} shell /usr/sbin/sshd -D -f /etc/ssh/sshd_config";

        # Stop sshd cleanly, then shut down the Darling prefix
        ExecStopPost = "-${cfg.package}/bin/darling --prefix ${cfg.prefixPath} shutdown";

        Restart = "on-failure";
        RestartSec = 10;

        # Give the prefix init plenty of time (first run is slow)
        TimeoutStartSec = "10min";
        TimeoutStopSec = "30s";

        # Security hardening (the service runs as root because Darling
        # needs namespace capabilities, but we restrict what it can do)
        NoNewPrivileges = false; # Darling needs to create namespaces
        ProtectSystem = "full";
        ProtectHome = "read-only";
        ReadWritePaths = [
          cfg.prefixPath
          "/nix"
        ];
      };
    };

    # ── Register as a Nix remote builder ─────────────────────────────
    nix.buildMachines = [
      {
        hostName = "127.0.0.1";
        port = cfg.port;
        systems = [ "x86_64-darwin" ];
        sshUser = "root";
        sshKey = cfg.sshKeyPath;
        maxJobs = cfg.maxJobs;
        speedFactor = cfg.speedFactor;
        supportedFeatures = cfg.supportedFeatures;
        mandatoryFeatures = cfg.mandatoryFeatures;
      }
    ];

    nix.distributedBuilds = true;

    # Trust the builder's SSH host key automatically on first connection
    # to avoid interactive prompts when the Nix daemon connects.
    nix.settings.trusted-users = [ "root" ];

    # ── Convenience: connectivity test script ────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "darling-builder-test" ''
        exec ${connectivityTestScript} "$@"
      '')
    ];
  };
}
