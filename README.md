# NixOS-TTY7

Run NixOS inside an LXC container with full hardware passthrough, taking place of the host TTY7.

⚠️ This project is currently a POC. It is used daily, but no extensive testing has been done. ⚠️

## Run

```bash
curl -fsSL https://raw.githubusercontent.com/jsecchiero/nixos-tty7/main/install | sudo bash
```

`Ctrl+Alt+F7` to see the NixOS console.  
The default login is:
- **Username:** `nixos`
- **Password:** `nixos`

## NixOS Configuration

The [initial NixOS configuration](nixos/default.nix) makes the whole thing work.  
Consider integrating it with a custom configuration.

## Compatibility

Currently works on:
| Works | Host OS | NixOS Version |
|------|---------|---------------|
| ✅  | Ubuntu Server 24.04 | 25.11 |

## Customizations

### External flake

The `NIXOS_FLAKE` environment variable can be used to specify an external flake instead of the [default one](nixos/default.nix).

### Add files to the NixOS container

The NixOS container lives inside the `/var/lib/machines/nixos` directory. Any files can be placed there directly.

### Run commands in the NixOS container directly from the host (without going to tty7)

```bash
lxc-attach -n nixos -- /run/current-system/sw/bin/nix shell nixpkgs#git nixpkgs#openssh -c \
  nixos-rebuild switch --flake "git+ssh://git@github.com/username/nix-repo.git#nixos-host" --refresh
```

## Development

### Headless test

Runs all tests automatically in a QEMU VM and reports results:

```bash
nix run .#test-ubuntu --option sandbox false
```

### Interactive test

Boots the VM with a GUI window for manual testing. After setup completes, switch to tty7 to see the NixOS console:

```bash
nix run .#test-ubuntu-interactive --option sandbox false
```

Or connect via SSH:

```bash
# credentials are `ubuntu / ubuntu`
ssh ubuntu@127.1 -p 2222
```
