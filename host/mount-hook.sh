#!/bin/bash
# Mount hook script for NixOS LXC container
# Fixes device permissions to match NixOS group IDs
#
# NixOS group IDs:
#   video  = 26
#   render = 303
#   input  = 174
#   audio  = 17

set -e

# Fix DRI device permissions (GPU)
if [ -d "$LXC_ROOTFS_MOUNT/dev/dri" ]; then
    for dev in "$LXC_ROOTFS_MOUNT"/dev/dri/card*; do
        [ -e "$dev" ] && chown root:26 "$dev" && chmod 660 "$dev"
    done
    for dev in "$LXC_ROOTFS_MOUNT"/dev/dri/renderD*; do
        [ -e "$dev" ] && chown root:303 "$dev" && chmod 660 "$dev"
    done
fi

# Fix input device permissions (keyboard, mouse, touchpad)
if [ -d "$LXC_ROOTFS_MOUNT/dev/input" ]; then
    for dev in "$LXC_ROOTFS_MOUNT"/dev/input/event* "$LXC_ROOTFS_MOUNT"/dev/input/mouse* "$LXC_ROOTFS_MOUNT"/dev/input/mice; do
        [ -e "$dev" ] && chown root:174 "$dev" && chmod 660 "$dev"
    done
    if [ -d "$LXC_ROOTFS_MOUNT/dev/input/by-path" ]; then
        chown root:174 "$LXC_ROOTFS_MOUNT/dev/input/by-path"
        chmod 770 "$LXC_ROOTFS_MOUNT/dev/input/by-path"
        for dev in "$LXC_ROOTFS_MOUNT"/dev/input/by-path/*; do
            [ -e "$dev" ] && chown root:174 "$dev"
        done
    fi
    if [ -d "$LXC_ROOTFS_MOUNT/dev/input/by-id" ]; then
        chown root:174 "$LXC_ROOTFS_MOUNT/dev/input/by-id"
        chmod 770 "$LXC_ROOTFS_MOUNT/dev/input/by-id"
        for dev in "$LXC_ROOTFS_MOUNT"/dev/input/by-id/*; do
            [ -e "$dev" ] && chown root:174 "$dev"
        done
    fi
fi

# Fix sound device permissions (ALSA)
if [ -d "$LXC_ROOTFS_MOUNT/dev/snd" ]; then
    for dev in "$LXC_ROOTFS_MOUNT"/dev/snd/*; do
        [ -e "$dev" ] && chown root:17 "$dev" && chmod 660 "$dev"
    done
fi

# Fix video device permissions (webcam)
for dev in "$LXC_ROOTFS_MOUNT"/dev/video*; do
    [ -e "$dev" ] && chown root:26 "$dev" && chmod 660 "$dev"
done

# Fix framebuffer permissions
if [ -e "$LXC_ROOTFS_MOUNT/dev/fb0" ]; then
    chown root:26 "$LXC_ROOTFS_MOUNT/dev/fb0"
    chmod 660 "$LXC_ROOTFS_MOUNT/dev/fb0"
fi

exit 0
