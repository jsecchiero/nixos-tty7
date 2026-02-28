{
  description = "NixOS TTY7";

  inputs = {
    # Tooling, test infrastructure, dev shell
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # NixOS 25.11 for the LXC container configuration (used by nixos-rebuild)
    nixpkgs-container.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, nixpkgs-container }:
    let
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      forEachSystem = f:
        builtins.foldl' (acc: system: acc // (f system)) {} supportedSystems;

      # Map host system to the Linux system for the NixOS container
      # (Darwin hosts target the same CPU arch but linux)
      linuxSystem = system: builtins.replaceStrings [ "darwin" ] [ "linux" ] system;

      # Per-system attrs: host pkgs + Linux NixOS container + test infrastructure
      systemAttrs = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          containerSystem = linuxSystem system;

          # NixOS system for LXC container using nixpkgs-container (25.11)
          # Base config — minimal, no window manager
          nixosSystem = nixpkgs-container.lib.nixosSystem {
            system = containerSystem;
            modules = [ ./nixos ];
          };

          # NixOS system with sway — used by headless test to verify sway on tty7
          nixosSystemSway = nixpkgs-container.lib.nixosSystem {
            system = containerSystem;
            modules = [ ./test/sway.nix ];
          };

          # Ubuntu VM test infrastructure
          ubuntuVm = import ./test/ubuntu-vm.nix {
            inherit pkgs;
            nixosSystem = nixosSystemSway;       # headless test: sway rootfs
            nixosSystemBase = nixosSystem;        # interactive test: base rootfs
          };
        in
        { inherit pkgs nixosSystem nixosSystemSway ubuntuVm; };
    in
    {
      # NixOS module for importing into other flakes (system-agnostic)
      nixosModules.default = import ./nixos;

      # NixOS configurations for LXC containers (uses nixpkgs-container / 25.11)
      # These are Linux-only since NixOS only runs on Linux
      nixosConfigurations = {
        nixos = (systemAttrs "x86_64-linux").nixosSystem;
        nixos-x86_64-linux = (systemAttrs "x86_64-linux").nixosSystem;
        nixos-aarch64-linux = (systemAttrs "aarch64-linux").nixosSystem;
      };

      # Development shell
      devShells = forEachSystem (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          ${system}.default = pkgs.mkShell {
            packages = with pkgs; [
              qemu
              cloud-utils
              curl
              jq
              mtools
              dosfstools
            ];
          };
        });

      # Packages
      packages = forEachSystem (system:
        let attrs = systemAttrs system;
        in {
          ${system} = {
            default = attrs.pkgs.writeShellScriptBin "nixos-lxc-install" (builtins.readFile ./install);

            # Test runners
            test-ubuntu = attrs.ubuntuVm.testUbuntu;
            test-ubuntu-interactive = attrs.ubuntuVm.testInteractive;
            test-ubuntu-clean = attrs.ubuntuVm.testClean;
          };
        });
    };
}
