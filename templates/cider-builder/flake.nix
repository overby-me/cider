{
  description = "NixOS configuration with a Darling-based x86_64-darwin builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    cider-nix = {
      url = "github:nixie-dev/cider-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      cider-nix,
      ...
    }:
    {
      # ── NixOS system configuration ───────────────────────────────────
      #
      # Replace "myhost" with your machine's hostname.
      # Adjust the module list and options to fit your setup.
      #
      # Build with:
      #   sudo nixos-rebuild switch --flake .#myhost
      #
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          # Your existing hardware and system configuration:
          # ./hardware-configuration.nix
          # ./configuration.nix

          # Base Darling support — provides `programs.cider`
          cider-nix.nixosModules.nixos

          # Darling builder service — provides `services.cider-builder`
          cider-nix.nixosModules.cider-builder

          # ── Builder settings ────────────────────────────────────────
          {
            services.cider-builder = {
              # Enable the builder service.  After `nixos-rebuild switch`,
              # a systemd service will:
              #   1. Initialise a Darling prefix
              #   2. Install Nix inside the prefix
              #   3. Start sshd so the host Nix daemon can connect
              #   4. Register as a `nix.buildMachines` entry
              enable = true;

              # Maximum number of concurrent build jobs.
              # A safe default is half your CPU core count.
              maxJobs = 4;

              # Share /nix/store between the host and the Darling prefix
              # via /Volumes/SystemRoot.  This avoids copying store paths
              # over SSH and makes build results instantly available.
              # Disable this if you encounter permission or database issues.
              shareStore = true;

              # SSH port for the builder (inside the Darling prefix).
              # Uses 2222 by default to avoid conflicting with the host's sshd.
              # port = 2222;

              # Nix speed factor — lower means Nix will prefer other builders
              # when available.  Set higher if this is your only Darwin builder.
              # speedFactor = 1;

              # Path to the SSH private key used by the Nix daemon to connect
              # to the Darling builder.  Generated automatically on first boot.
              # sshKeyPath = "/etc/nix/cider-builder-key";

              # Path to the Darling prefix directory.
              # prefixPath = "/var/lib/cider-builder";

              # Automatically install Nix inside the Darling prefix on first boot.
              # installNix = true;

              # Nix version to install inside Darling.
              # nixVersion = "2.24.10";
            };
          }
        ];
      };
    };
}
