#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# set-wifi.sh - OPTIONAL: bake Wi-Fi credentials into a COPY of rootfs.ext4 before flashing.
# Run as root in WSL.  Nothing is stored in the repo; the credentials end up only in the
# netplan file (mode 600) inside the personalised copy of the root filesystem.
#   usage (as root, or "sudo -E"; start the line with a SPACE or run "unset HISTFILE" first so the passphrase stays out of the shell history):
#     SSID='my net' PSK='my passphrase' [REGDOM=GR] set-wifi.sh /path/rootfs.ext4 /path/rootfs-wifi.ext4
# Afterwards re-compress:  gzip -9 -n -k rootfs-wifi.ext4   and flash that file instead of rootfs.ext4.gz
set -euo pipefail
IN=${1:?input rootfs.ext4}; OUT=${2:?output rootfs-wifi.ext4}
: "${SSID:?set SSID}" "${PSK:?set PSK}"; REGDOM=${REGDOM:-}
cp --sparse=always "$IN" "$OUT"
M=$(mktemp -d); mount -o loop "$OUT" "$M"; trap 'umount "$M"; rmdir "$M"' EXIT
mkdir -p "$M/etc/netplan"
umask 077
yq() { printf "%s" "$1" | sed "s/'/''/g"; }     # YAML single-quoted scalar: only ' needs doubling
cat > "$M/etc/netplan/20-dq10-wifi.yaml" <<EOT
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: true
      ${REGDOM:+regulatory-domain: '$(yq "$REGDOM")'}
      access-points:
        '$(yq "$SSID")':
          password: '$(yq "$PSK")'
EOT
chmod 600 "$M/etc/netplan/20-dq10-wifi.yaml"
echo "wrote $M/etc/netplan/20-dq10-wifi.yaml (mode 600) into $OUT"
