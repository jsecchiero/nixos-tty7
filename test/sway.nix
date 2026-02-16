{ config, pkgs, lib, ... }: {

  imports = [ ../nixos/default.nix ];

  # Sway window manager for Wayland desktop
  programs.sway = {
    enable = true;
  };

  # Autologin on tty7 — override the getty@tty7 service from default.nix
  # to add --autologin nixos so the test doesn't need an interactive login.
  systemd.services."getty@tty7" = {
    serviceConfig = {
      ExecStart = lib.mkForce [
        ""  # clear the default
        "${pkgs.util-linux}/bin/agetty --autologin nixos --noclear tty7 linux"
      ];
    };
  };

  # Auto-start sway on tty7 after autologin.
  # This runs in the login shell profile — when the user is on tty7
  # and no Wayland session is active, source the env and exec sway.
  environment.etc."profile.local".text = ''
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty7" ]; then
      exec sway
    fi
  '';
}
