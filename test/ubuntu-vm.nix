{ pkgs, nixosSystem, nixosSystemBase }:

let
  ubuntuCloudImage = pkgs.fetchurl {
    url = "https://cloud-images.ubuntu.com/releases/24.04/release-20241004/ubuntu-24.04-server-cloudimg-amd64.img";
    hash = "sha256-+tEB1QsGsmWQzzBUI0n56dMEGteSnjvDUxyB7Cfyx4g=";
  };

  # Build NixOS rootfs from the flake's configurations
  # nixosSystem = sway config (for headless test)
  # nixosSystemBase = minimal config (for interactive test)
  nixosToplevel = nixosSystem.config.system.build.toplevel;
  nixosToplevelBase = nixosSystemBase.config.system.build.toplevel;

  # Build a rootfs disk image from a NixOS toplevel closure
  mkRootfsDisk = name: toplevel: pkgs.runCommand name {
    nativeBuildInputs = [ pkgs.e2fsprogs pkgs.fakeroot pkgs.rsync ];
  } ''
    echo "Creating ext4 disk image with NixOS rootfs from flake configuration..."
    echo "NixOS toplevel: ${toplevel}"

    mkdir -p rootfs_content/{nix/store,sbin,etc,run,proc,sys,dev,tmp,var,root}

    # Create /nix/var hierarchy required by nix-daemon
    mkdir -p rootfs_content/nix/var/nix/{daemon-socket,db,gcroots/auto,gcroots/per-user,profiles/per-user,temproots,userpool,builds}
    mkdir -p rootfs_content/nix/var/log/nix/drvs

    # Copy the entire Nix store closure for the NixOS system
    echo "Copying Nix store closure (this may take a while)..."
    closureInfo="${pkgs.closureInfo { rootPaths = [ toplevel ]; }}"

    while IFS= read -r storePath; do
      if [ -e "$storePath" ]; then
        mkdir -p "rootfs_content$(dirname $storePath)"
        cp -a "$storePath" "rootfs_content$storePath"
      fi
    done < "$closureInfo/store-paths"

    echo "Setting up /sbin/init symlink..."
    ln -sf "${toplevel}/init" rootfs_content/sbin/init

    touch rootfs_content/etc/NIXOS
    mkdir -p rootfs_content/etc/nixos
    mkdir -p rootfs_content/var/lib/nixos

    echo 'NAME=NixOS' > rootfs_content/etc/os-release
    echo 'ID=nixos' >> rootfs_content/etc/os-release

    echo "Creating ext4 image from rootfs..."
    ${pkgs.fakeroot}/bin/fakeroot ${pkgs.e2fsprogs}/bin/mke2fs \
      -L NIXOS_ROOTFS \
      -d rootfs_content \
      -t ext4 \
      -q \
      rootfs.img 10G

    mkdir -p $out
    mv rootfs.img $out/nixos-rootfs.img
    echo "Done! Created $out/nixos-rootfs.img"
  '';

  # Rootfs with sway (for headless test)
  nixosRootfsDisk = mkRootfsDisk "nixos-rootfs-disk-sway" nixosToplevel;

  # Rootfs base config only (for interactive test)
  nixosRootfsDiskBase = mkRootfsDisk "nixos-rootfs-disk-base" nixosToplevelBase;

  # Cloud-init config to install LXC on first boot (for building the base image)
  cloudInitInstallLxc = pkgs.writeText "user-data" ''
    #cloud-config
    user: ubuntu
    password: ubuntu
    chpasswd:
      expire: false
    ssh_pwauth: true
    package_update: true
    packages:
      - lxc
      - curl
      - xz-utils
    runcmd:
      - touch /var/lib/cloud/instance/lxc-installed
      - echo "LXC_INSTALLED" > /etc/lxc-ready
      - sync
      - poweroff
  '';

  cloudInitMetaData = pkgs.writeText "meta-data" ''
    instance-id: ubuntu-lxc-build
    local-hostname: ubuntu-lxc
  '';

  cloudInitBuildIso = pkgs.runCommand "cloud-init-build.iso" {
    nativeBuildInputs = [ pkgs.cdrkit ];
  } ''
    mkdir -p iso
    cp ${cloudInitInstallLxc} iso/user-data
    cp ${cloudInitMetaData} iso/meta-data
    genisoimage -output $out -volid cidata -joliet -rock iso/
  '';

  # Source files from the repo
  installScript = ../install;
  lxcContainerConf = ../host/lxc-container.conf;
  mountHook = ../host/mount-hook.sh;
  lxcWaitDevicesService = ../host/lxc-wait-devices.service;
  # ── Sway-on-tty7 polling for headless test ──────────────────────────────────
  # The sway NixOS config (test/sway.nix) bakes in autologin on tty7,
  # auto-exec sway. No runtime injection needed.
  # This script just polls for the sway process to appear after container
  # start/restart.
  swayTestSetupScript = pkgs.writeScript "sway-test-setup" ''
    #!/bin/bash
    echo "Waiting for sway to start on tty7 (config baked into NixOS rootfs)..."

    SWAY_STARTED=0
    for i in $(seq 1 45); do
      if lxc-attach -n nixos -- /run/current-system/sw/bin/pgrep -u nixos sway 2>/dev/null; then
        echo "  Sway started after ''${i}s"
        SWAY_STARTED=1
        break
      fi
      sleep 1
    done
    export SWAY_STARTED
  '';

  # ── Cloud-init for headless test ──────────────────────────────────────────
  # Runs install with local overrides, then validates the container works.
  cloudInitTestUserData = pkgs.writeText "test-user-data" ''
    #cloud-config
    user: ubuntu
    password: ubuntu
    chpasswd:
      expire: false
    ssh_pwauth: true
    write_files:
      - path: /root/run-test.sh
        permissions: '0755'
        content: |
          #!/bin/bash
           # Headless test runner - exercises install and validates the result
          exec > /dev/ttyS0 2>&1
          set -euo pipefail
          trap 'echo "ERROR: Script failed at line $LINENO (exit code $?)"; echo "TEST_FAILED" > /mnt/shared/result.txt 2>/dev/null; sync; poweroff' ERR

          echo "=== Ubuntu TTY7 ==="
          echo "Started at $(date)"
          echo ""

           # Mount shared disk with test files and install
          echo "Mounting shared disk..."
          mkdir -p /mnt/shared
          MOUNTED=0
          for i in $(seq 1 30); do
            if [ -e /dev/disk/by-label/SHARED ]; then
              mount /dev/disk/by-label/SHARED /mnt/shared && MOUNTED=1 && break
            elif [ -b /dev/vdb ]; then
              mount /dev/vdb /mnt/shared && MOUNTED=1 && break
            fi
            sleep 1
          done
          if [ "$MOUNTED" -ne 1 ]; then
            echo "ERROR: Failed to mount shared disk"
            lsblk
            echo "TEST_FAILED" > /tmp/result.txt
            poweroff
          fi
          echo "Shared disk contents:"
          ls -la /mnt/shared/

           # ── Run the real install ──
           # This is the exact script users run in production, with env var
           # overrides to use local files instead of downloading.
           echo ""
           echo "=== Running install ==="
           cp /mnt/shared/install /root/install
           chmod +x /root/install

           export NIXLXC_SKIP_APT=1
           export NIXLXC_SKIP_SYSTEMD=1
           export NIXLXC_SKIP_NIXOS_REBUILD=1
           export NIXLXC_LOCAL_FILES=/mnt/shared

           /root/install

          # ── Verification tests ──
          echo ""
          echo "=== Verification Tests ==="

          # Wait for container services to fully start
          echo "Waiting for NixOS multi-user.target..."
          for i in $(seq 1 60); do
            if lxc-attach -n nixos -- /run/current-system/sw/bin/systemctl is-active multi-user.target 2>/dev/null; then
              echo "  multi-user.target reached after ''${i}s"
              break
            fi
            sleep 1
          done

          echo "[Test 1] Container is running..."
          STATE=$(lxc-info -n nixos -s | awk '{print $2}')
          if [ "$STATE" != "RUNNING" ]; then
            echo "FAIL: Container state is $STATE (expected RUNNING)"
            echo "TEST_FAILED" > /mnt/shared/result.txt
            sync; poweroff
          fi
          echo "  PASS: Container is RUNNING"

          echo "[Test 2] Container exec works..."
          lxc-attach -n nixos -- /run/current-system/sw/bin/echo "Hello from NixOS container"
          echo "  PASS: Container exec works"

          echo "[Test 3] Nix is available..."
          lxc-attach -n nixos -- /run/current-system/sw/bin/nix --version
          echo "  PASS: Nix works"

          echo "[Test 4] Nix daemon works (as user nixos)..."
          NIXOS_UID=$(lxc-attach -n nixos -- /bin/sh -c 'id -u nixos' 2>/dev/null || echo "1000")
          NIXOS_GID=$(lxc-attach -n nixos -- /bin/sh -c 'id -g nixos' 2>/dev/null || echo "100")
          for i in $(seq 1 30); do
            if lxc-attach -n nixos --uid "$NIXOS_UID" --gid "$NIXOS_GID" -- /run/current-system/sw/bin/nix store ping 2>/dev/null; then
              break
            fi
            sleep 1
          done
          lxc-attach -n nixos --uid "$NIXOS_UID" --gid "$NIXOS_GID" -- /run/current-system/sw/bin/nix store ping
          echo "  PASS: Nix daemon accessible as user nixos"

          echo "[Test 5] Nix sandbox works (as user nixos)..."
          set +e
          NIX_BUILD_OUTPUT=$(lxc-attach -n nixos --uid "$NIXOS_UID" --gid "$NIXOS_GID" -- /run/current-system/sw/bin/nix-build -E 'derivation { name = "sandbox-test"; system = "x86_64-linux"; builder = "/bin/sh"; args = ["-c" "echo ok > $out"]; }' --no-out-link 2>&1)
          NIX_BUILD_RC=$?
          set -e
          if [ "$NIX_BUILD_RC" -ne 0 ]; then
            echo "  FAIL: Nix sandboxed build failed (exit code $NIX_BUILD_RC)"
            echo "  nix-build output:"
            echo "  $NIX_BUILD_OUTPUT"
            echo "TEST_FAILED" > /mnt/shared/result.txt
            sync; poweroff; exit 1
          fi
          echo "  PASS: Nix sandboxed build works"

          echo "[Test 6] getty@tty7 is active..."
          for i in $(seq 1 15); do
            if lxc-attach -n nixos -- /run/current-system/sw/bin/systemctl is-active getty@tty7.service 2>/dev/null; then
              break
            fi
            sleep 1
          done
          lxc-attach -n nixos -- /run/current-system/sw/bin/systemctl is-active getty@tty7.service
          echo "  PASS: getty@tty7 is active"

          echo "[Test 7] Container lifecycle (stop/start)..."
          lxc-stop -n nixos
          STATE=$(lxc-info -n nixos -s | awk '{print $2}')
          [ "$STATE" = "STOPPED" ] || { echo "FAIL: Expected STOPPED, got $STATE"; echo "TEST_FAILED" > /mnt/shared/result.txt; sync; poweroff; }
          lxc-start -n nixos
          sleep 3
          for i in $(seq 1 60); do
            lxc-attach -n nixos -- /run/current-system/sw/bin/true 2>/dev/null && break
            sleep 1
          done
          lxc-attach -n nixos -- /run/current-system/sw/bin/true
          echo "  PASS: Container stop/start works"

          echo "[Test 8] Sway running on tty7..."
          # Wait for multi-user.target after container restart (Test 7 restarted it)
          for i in $(seq 1 60); do
            if lxc-attach -n nixos -- /run/current-system/sw/bin/systemctl is-active multi-user.target 2>/dev/null; then
              break
            fi
            sleep 1
          done

          # Autologin + sway auto-start are baked into the NixOS rootfs
          # (test/sway.nix). Just wait for the sway process to appear.
          source /mnt/shared/sway-test-setup

          if [ "$SWAY_STARTED" -eq 1 ]; then
            echo "  PASS: Sway is running on tty7"
          else
            echo "  FAIL: Sway process not found after 45s"
            echo "  Collecting diagnostics..."
            set +e
            DIAG=/mnt/shared/sway-debug.txt
            echo "=== Sway Debug Info ===" > "$DIAG"
            echo "--- getty@tty7 status ---" >> "$DIAG"
            lxc-attach -n nixos -- /bin/sh -c '/run/current-system/sw/bin/systemctl status getty@tty7.service 2>&1' >> "$DIAG" 2>&1
            echo "--- seatd status ---" >> "$DIAG"
            lxc-attach -n nixos -- /bin/sh -c '/run/current-system/sw/bin/systemctl status seatd.service 2>&1' >> "$DIAG" 2>&1
            echo "--- nixos user processes ---" >> "$DIAG"
            lxc-attach -n nixos -- /bin/sh -c '/run/current-system/sw/bin/ps -u nixos -f 2>&1 || echo "none"' >> "$DIAG" 2>&1
            echo "--- getty@tty7 journal ---" >> "$DIAG"
            lxc-attach -n nixos -- /bin/sh -c '/run/current-system/sw/bin/journalctl -u getty@tty7.service --no-pager -n 30 2>&1' >> "$DIAG" 2>&1
            echo "--- seatd journal ---" >> "$DIAG"
            lxc-attach -n nixos -- /bin/sh -c '/run/current-system/sw/bin/journalctl -u seatd.service --no-pager -n 20 2>&1' >> "$DIAG" 2>&1
            sync
            echo "  --- Sway debug dump ---"
            cat "$DIAG"
            echo "  --- End debug dump ---"
            set -e
            echo "TEST_FAILED" > /mnt/shared/result.txt
            sync; poweroff; exit 1
          fi

          echo ""
          echo "========================================"
          echo "ALL TESTS PASSED!"
          echo "========================================"

          echo "TEST_SUCCESS" > /mnt/shared/result.txt
          sync
          poweroff

    runcmd:
      # Disable login via ttyS0 serial console
      - systemctl mask serial-getty@ttyS0.service
      - systemctl stop serial-getty@ttyS0.service || true
      - systemd-run --unit=setup-test --no-block /root/run-test.sh
  '';

  cloudInitTestMetaData = pkgs.writeText "test-meta-data" ''
    instance-id: ubuntu-lxc-test-run
    local-hostname: ubuntu-test
  '';

  cloudInitTestIso = pkgs.runCommand "cloud-init-test.iso" {
    nativeBuildInputs = [ pkgs.cdrkit ];
  } ''
    mkdir -p iso
    cp ${cloudInitTestUserData} iso/user-data
    cp ${cloudInitTestMetaData} iso/meta-data
    genisoimage -output $out -volid cidata -joliet -rock iso/
  '';

  # ── Cloud-init for interactive test ─────────────────────────────────────────
  # Runs install with local overrides, switches to tty7 login prompt, stays running.
  # Unlike the headless test, NO autologin or sway-env injection is applied.
  # The user can log in manually as nixos/nixos and sway will start via loginShellInit.
  cloudInitInteractiveUserData = pkgs.writeText "interactive-user-data" ''
    #cloud-config
    user: ubuntu
    password: ubuntu
    chpasswd:
      expire: false
    ssh_pwauth: true
    write_files:
      # Allow SSH password login
      - path: /etc/ssh/sshd_config.d/50-cloud-init.conf
        content: |
          PasswordAuthentication yes
      - path: /root/setup-nixos.sh
        permissions: '0755'
        content: |
          #!/bin/bash
           # Interactive setup - runs install, switches to tty7
          LOG=/root/setup-nixos.log
          exec > >(tee "$LOG" > /dev/ttyS0) 2>&1
          set -euo pipefail
          trap 'echo "ERROR: Script failed at line $LINENO (exit code $?)" | tee -a "$LOG"' ERR

          echo "=== NixOS LXC Container Setup (Interactive Mode) ==="
          echo "Started at $(date)"
          echo ""

          # Mount shared disk
          echo "Mounting shared disk..."
          mkdir -p /mnt/shared
          MOUNTED=0
          for i in $(seq 1 30); do
            if [ -e /dev/disk/by-label/SHARED ]; then
              mount /dev/disk/by-label/SHARED /mnt/shared && MOUNTED=1 && break
            elif [ -b /dev/vdb ]; then
              mount /dev/vdb /mnt/shared && MOUNTED=1 && break
            fi
            sleep 1
          done
          if [ "$MOUNTED" -ne 1 ]; then
            echo "ERROR: Failed to mount shared disk after 30s"
            lsblk
            exit 1
          fi
          echo "  Shared disk mounted"

           # Run the real install with test overrides
           echo ""
           echo "=== Running install ==="
           cp /mnt/shared/install /root/install
           chmod +x /root/install

           export NIXLXC_SKIP_APT=1
           export NIXLXC_SKIP_SYSTEMD=1
           export NIXLXC_SKIP_NIXOS_REBUILD=1
           export NIXLXC_LOCAL_FILES=/mnt/shared

           /root/install

          # Wait for container to be fully ready
          echo "Waiting for NixOS multi-user.target..."
          for i in $(seq 1 60); do
            if lxc-attach -n nixos -- /run/current-system/sw/bin/systemctl is-active multi-user.target 2>/dev/null; then
              echo "  multi-user.target reached after ''${i}s"
              break
            fi
            sleep 1
          done

          # Switch to tty7 so the NixOS login prompt is visible in QEMU window
          chvt 7

          echo ""
          echo "========================================"
          echo "NixOS Container is RUNNING!"
          echo "tty7 shows the NixOS login prompt."
          echo "Log in as: nixos / nixos"
          echo "========================================"
          echo ""
          echo "Access NixOS container:"
          echo "  sudo lxc-attach -n nixos"
          echo "  In QEMU window: tty7 has NixOS login"
          echo ""
          echo "SSH into Ubuntu host:"
          echo "  sshpass -p ubuntu ssh -p 2222 ubuntu@localhost"
          echo ""
          echo "View this log:"
          echo "  sudo cat /root/setup-nixos.log"
          echo ""
          echo "Finished at $(date)"

    runcmd:
      # Disable login via ttyS0 serial console
      - systemctl mask serial-getty@ttyS0.service
      - systemctl stop serial-getty@ttyS0.service || true
      - systemd-run --unit=nixos-setup --no-block /root/setup-nixos.sh
  '';

  cloudInitInteractiveMetaData = pkgs.writeText "interactive-meta-data" ''
    instance-id: ubuntu-lxc-interactive
    local-hostname: ubuntu-interactive
  '';

  cloudInitInteractiveIso = pkgs.runCommand "cloud-init-interactive.iso" {
    nativeBuildInputs = [ pkgs.cdrkit ];
  } ''
    mkdir -p iso
    cp ${cloudInitInteractiveUserData} iso/user-data
    cp ${cloudInitInteractiveMetaData} iso/meta-data
    genisoimage -output $out -volid cidata -joliet -rock iso/
  '';

  # ── Pre-built Ubuntu image with LXC installed ──────────────────────────────
  ubuntuLxcImageSimple = pkgs.runCommand "ubuntu-lxc-image-simple" {
    nativeBuildInputs = [ pkgs.qemu_test ];
    requiredSystemFeatures = [ "kvm" ];
    __noChroot = true;
  } ''
    echo "=== Building Ubuntu + LXC image ==="

    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    qemu-img create -f qcow2 -b ${ubuntuCloudImage} -F qcow2 ubuntu-lxc.qcow2 20G

    echo "Booting Ubuntu to install LXC..."

    timeout 600 qemu-system-x86_64 \
      -machine accel=kvm -cpu host -m 2048 -smp 2 \
      -drive file=ubuntu-lxc.qcow2,format=qcow2,if=virtio \
      -cdrom ${cloudInitBuildIso} \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
      -nographic -serial mon:stdio 2>&1 | tee build.log || true

    if grep -q "Power down\|reboot: Power down" build.log; then
      echo "Build completed"
    else
      echo "Build may have failed:"
      tail -50 build.log
      exit 1
    fi

    mkdir -p $out
    cp ubuntu-lxc.qcow2 $out/
    cp build.log $out/
  '';

  # ── Shared disk builder (used by both test modes) ──────────────────────────
  # Creates a FAT disk with install and all config files
  mkSharedDisk = extraCmds: ''
    dd if=/dev/zero of=shared.img bs=1M count=256 status=none
    ${pkgs.dosfstools}/bin/mkfs.vfat -n SHARED shared.img > /dev/null
    ${pkgs.mtools}/bin/mcopy -i shared.img ${installScript} ::install
    ${pkgs.mtools}/bin/mcopy -i shared.img ${mountHook} ::mount-hook.sh
    ${pkgs.mtools}/bin/mcopy -i shared.img ${lxcContainerConf} ::lxc-container.conf
    ${pkgs.mtools}/bin/mcopy -i shared.img ${lxcWaitDevicesService} ::lxc-wait-devices.service
    ${pkgs.mtools}/bin/mcopy -i shared.img ${swayTestSetupScript} ::sway-test-setup
    ${extraCmds}
  '';

  # ── Headless test runner ───────────────────────────────────────────────────
  testUbuntu = pkgs.writeShellScriptBin "test-ubuntu" ''
    set -euo pipefail

    UBUNTU_IMAGE="''${1:-${ubuntuLxcImageSimple}/ubuntu-lxc.qcow2}"
    NIXOS_ROOTFS_DISK="${nixosRootfsDisk}/nixos-rootfs.img"

    if [ ! -f "$UBUNTU_IMAGE" ]; then
      echo "Error: Ubuntu image not found at $UBUNTU_IMAGE"
      echo "Build it first with: nix build .#ubuntu-lxc-image --option sandbox false"
      exit 1
    fi

    echo "=== Ubuntu TTY7 ==="
    echo "Testing: install (the real script)"
    echo "Ubuntu image: $UBUNTU_IMAGE"
    echo "NixOS rootfs disk: $NIXOS_ROOTFS_DISK"
    echo ""

    WORKDIR=$(mktemp -d)
    cleanup() {
      # Kill QEMU if still running
      if [ -f "$WORKDIR/qemu.pid" ]; then
        kill "$(cat "$WORKDIR/qemu.pid")" 2>/dev/null || true
      fi
      # Stop tail
      [ -n "''${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null || true
      rm -rf "$WORKDIR"
    }
    trap cleanup EXIT
    TAIL_PID=""
    cd "$WORKDIR"

    ${pkgs.qemu_test}/bin/qemu-img create -f qcow2 -b "$UBUNTU_IMAGE" -F qcow2 test.qcow2 20G
    ${pkgs.qemu_test}/bin/qemu-img create -f qcow2 -b "$NIXOS_ROOTFS_DISK" -F raw rootfs-overlay.qcow2 10G

    echo "Preparing shared disk..."
    ${mkSharedDisk ''
      echo "PENDING" > result.txt
      ${pkgs.mtools}/bin/mcopy -i shared.img result.txt ::result.txt
    ''}

    echo "Starting test VM..."
    echo ""

    # Run QEMU with serial output to a file and tail it for live output.
    # Using -serial file:... avoids all TTY/stdio mux issues that cause
    # hangs in some terminal environments.
    touch serial.log
    ${pkgs.qemu_test}/bin/qemu-system-x86_64 \
      -machine accel=kvm -cpu host -m 4096 -smp 2 \
      -drive file=test.qcow2,format=qcow2,if=virtio \
      -cdrom ${cloudInitTestIso} \
      -drive file=shared.img,format=raw,if=virtio \
      -drive file=rootfs-overlay.qcow2,format=qcow2,if=virtio \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
      -device virtio-gpu-pci \
      -display none -serial file:serial.log -monitor none \
      -daemonize -pidfile qemu.pid

    QEMU_PID=$(cat qemu.pid)
    echo "QEMU started (PID $QEMU_PID), waiting for test to complete..."
    echo ""

    # Stream serial output in background
    tail -f serial.log &
    TAIL_PID=$!

    # Wait for QEMU to exit (VM powers off), early result, or timeout
    DEADLINE=$((SECONDS + 600))
    while kill -0 "$QEMU_PID" 2>/dev/null; do
      if [ $SECONDS -ge $DEADLINE ]; then
        echo ""
        echo "TIMEOUT: Killing QEMU after 600s"
        kill "$QEMU_PID" 2>/dev/null || true
        break
      fi
      # Early exit: detect success or failure from serial output
      if grep -q "ALL TESTS PASSED" serial.log 2>/dev/null; then
        echo "Detected test success, stopping VM..."
        kill "$QEMU_PID" 2>/dev/null || true
        break
      fi
      if grep -q "TEST_FAILED" serial.log 2>/dev/null; then
        echo "Detected test failure, stopping VM..."
        kill "$QEMU_PID" 2>/dev/null || true
        break
      fi
      sleep 2
    done

    # Let tail catch up, then stop it
    sleep 1
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true

    echo ""
    echo "=== Checking results ==="

    # Check result from serial output (the test script writes TEST_SUCCESS
    # to the shared disk AND prints ALL TESTS PASSED to serial)
    if grep -q "ALL TESTS PASSED" serial.log 2>/dev/null; then
      echo ""
      echo "ALL TESTS PASSED"
      echo "  install executed successfully"
      echo "  NixOS container started and is functional"
      exit 0
    else
      echo ""
      echo "TESTS FAILED"
      echo ""
      echo "Last 100 lines of serial output:"
      tail -100 serial.log
      exit 1
    fi
  '';

  # ── Interactive test runner ────────────────────────────────────────────────
  testInteractive = pkgs.writeShellScriptBin "test-ubuntu-interactive" ''
    set -euo pipefail

    UBUNTU_IMAGE="''${1:-${ubuntuLxcImageSimple}/ubuntu-lxc.qcow2}"
    NIXOS_ROOTFS_DISK="${nixosRootfsDiskBase}/nixos-rootfs.img"

    if [ ! -f "$UBUNTU_IMAGE" ]; then
      echo "Error: Ubuntu image not found at $UBUNTU_IMAGE"
      echo "Build it first with: nix build .#ubuntu-lxc-image --option sandbox false"
      exit 1
    fi

    echo "=== Ubuntu TTY7 Test (Interactive) ==="
    echo "Ubuntu image: $UBUNTU_IMAGE"
    echo "NixOS rootfs disk: $NIXOS_ROOTFS_DISK"
    echo ""

    WORKDIR=$(mktemp -d)
    echo "Working directory: $WORKDIR"
    echo "Note: Directory will NOT be cleaned up automatically"
    cd "$WORKDIR"

    ${pkgs.qemu_test}/bin/qemu-img create -f qcow2 -b "$UBUNTU_IMAGE" -F qcow2 test.qcow2 20G
    ${pkgs.qemu_test}/bin/qemu-img create -f qcow2 -b "$NIXOS_ROOTFS_DISK" -F raw rootfs-overlay.qcow2 10G

    echo "Preparing shared disk..."
    ${mkSharedDisk ""}

    echo ""
    echo "Starting interactive VM..."
    echo ""
    echo "=========================================="
    echo "CREDENTIALS: ubuntu / ubuntu"
    echo "SSH: sshpass -p ubuntu ssh -p 2222 ubuntu@localhost"
    echo "=========================================="
    echo ""
    echo "The NixOS container will be set up AUTOMATICALLY using install."
    echo ""
    echo "In the GUI window:"
    echo "  - tty7 shows the NixOS login prompt"
    echo "  - Log in as: nixos / nixos"
    echo "  - Switch VTs with Ctrl+Alt+F1..F7"
    echo ""
    echo "Useful commands:"
    echo "  sudo lxc-ls -f              # Check container status"
    echo "  sudo lxc-attach -n nixos    # Enter NixOS container"
    echo "  sudo journalctl -u nixos-setup -f  # Watch install progress"
    echo "=========================================="
    echo ""

    ${pkgs.qemu}/bin/qemu-system-x86_64 \
      -machine accel=kvm -cpu host -m 4096 -smp 2 \
      -drive file=test.qcow2,format=qcow2,if=virtio \
      -cdrom ${cloudInitInteractiveIso} \
      -drive file=shared.img,format=raw,if=virtio \
      -drive file=rootfs-overlay.qcow2,format=qcow2,if=virtio \
      -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \
      -vga virtio \
      -display gtk -serial mon:stdio
  '';

in {
  inherit ubuntuLxcImageSimple;
  inherit testUbuntu testInteractive;
}
