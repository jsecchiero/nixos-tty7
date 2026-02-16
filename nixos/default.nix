# Minimal NixOS configuration for LXC container with device passthrough
{ config, pkgs, lib, ... }: {

  system.stateVersion = "25.11";

  # Container mode
  boot.isContainer = true;

  # nspawn/LXC compatibility - update /sbin/init symlink on activation
  system.build.installBootLoader = pkgs.writeScript "install-sbin-init.sh" ''
    #!${pkgs.runtimeShell}
    ${pkgs.coreutils}/bin/ln -fs "$1/init" /sbin/init
  '';

  system.activationScripts.installInitScript = lib.mkForce ''
    ${pkgs.coreutils}/bin/ln -fs $systemConfig/init /sbin/init
  '';

  # User configuration
  users.users.nixos = {
    isNormalUser = true;
    description = "NixOS user";
    extraGroups = [ "wheel" "video" "render" "input" "tty" "seat" "audio" ];
    initialPassword = "nixos";
  };

  # Enable seatd for Wayland seat management
  services.seatd.enable = true;

  # Enable graphics
  hardware.graphics.enable = true;

  # Getty on tty7 for direct VT access
  systemd.services."getty@tty7" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-user-sessions.service" "seatd.service" ];
    requires = [ "seatd.service" ];
    serviceConfig = {
      ExecStart = [
        ""  # clear the default
        "${pkgs.util-linux}/bin/agetty --noclear tty7 linux"
      ];
      Type = "idle";
      Restart = "always";
      RestartSec = 0;
      TTYPath = "/dev/tty7";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      StandardInput = "tty";
      StandardOutput = "tty";
    };
  };

  # Namespace permission workaround for nspawn/LXC
  # The || true ensures nix-daemon still starts if the remount is denied.
  # https://github.com/NixOS/nixpkgs/issues/405256
  systemd.services.nix-daemon = {
    preStart = "${pkgs.util-linux}/bin/mount proc -t proc /proc || true";
  };

  # Trigger udev to rescan devices at boot (needed for LXC bind-mounted devices)
  systemd.services.udev-trigger-devices = {
    description = "Trigger udev for bind-mounted devices in LXC container";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udevd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${pkgs.systemd}/bin/udevadm trigger --subsystem-match=input"
        "${pkgs.systemd}/bin/udevadm trigger --subsystem-match=sound"
        "${pkgs.systemd}/bin/udevadm trigger --subsystem-match=drm"
      ];
      RemainAfterExit = true;
    };
  };

  # Disable networkd
  systemd.services.systemd-networkd.enable = false;
  systemd.sockets.systemd-networkd.enable = false;

  # Disable systemd-resolved (container uses host's resolv.conf)
  services.resolved.enable = false;

  # DNS configuration - use common public DNS servers
  environment.etc."resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 8.8.8.8
  '';

  # System packages
  # git is required for nixos-rebuild to fetch flake sources
  environment.systemPackages = [ pkgs.git ];

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
