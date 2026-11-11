#!/usr/bin/env bash
# vm-create.sh - create an Ubuntu 24.04 VM on the br0 bridge with cloud-init.
#
# Usage (run as root, because the SSH key is kept in /root/ankit):
#   sudo ./vm-create.sh NAME IP DNS_IP RAM_MB VCPUS DISK_GB
# Example:
#   sudo ./vm-create.sh dc1 192.168.10.10 192.168.10.1 3072 2 40
#
# The SSH key pair is kept in /root/ankit:
#   /root/ankit/id_ed25519      (private key - use it to log in to the VMs)
#   /root/ankit/id_ed25519.pub  (public key  - injected into every VM)
# It is generated automatically the first time if it does not exist.
#
# The VM user's password defaults to Optimus@12345 (change it after first login).
#
# Optional overrides: KEY_DIR, DOMAIN, GATEWAY, PREFIX, VM_USER, VM_PASSWORD, PASSWORD_HASH

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Run this script with sudo (the key lives in /root/ankit)."
[ "$#" -eq 6 ] || die "Usage: $0 NAME IP DNS_IP RAM_MB VCPUS DISK_GB"

NAME=$1; IP=$2; DNS=$3; RAM=$4; CPUS=$5; DISK=$6
DOMAIN=${DOMAIN:-ad.ankinfo.online}
GATEWAY=${GATEWAY:-192.168.10.1}
PREFIX=${PREFIX:-24}
VM_USER=${VM_USER:-admin}
IMG=/var/lib/libvirt/images
BASE=$IMG/noble-server-cloudimg-amd64.img
BRIDGE=br0

# ------------------------------------------------------------- SSH key setup
KEY_DIR=${KEY_DIR:-/root/ankit}
KEY_FILE=$KEY_DIR/id_ed25519
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
if [ ! -f "$KEY_FILE" ]; then
  echo "Generating SSH key pair in $KEY_DIR"
  ssh-keygen -t ed25519 -N "" -C "ankit@$(hostname)" -f "$KEY_FILE"
fi
[ -f "$KEY_FILE.pub" ] || ssh-keygen -y -f "$KEY_FILE" > "$KEY_FILE.pub"
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"

export SSH_PUBKEY_FILE=$KEY_FILE.pub
PUBKEY=$(cat "$SSH_PUBKEY_FILE")

# ---------------------------------------------------------- password hash
# Default VM login password. Override with VM_PASSWORD=... or PASSWORD_HASH=...
VM_PASSWORD=${VM_PASSWORD:-Optimus@12345}
if [ -z "${PASSWORD_HASH:-}" ]; then
  if command -v mkpasswd > /dev/null; then
    PASSWORD_HASH=$(printf '%s' "$VM_PASSWORD" | mkpasswd --method=SHA-512 --stdin)
  else
    PASSWORD_HASH=$(openssl passwd -6 -stdin <<< "$VM_PASSWORD")
  fi
fi
[ -n "$PASSWORD_HASH" ] || die "Could not create the password hash."
export PASSWORD_HASH
HASH=$PASSWORD_HASH

# ----------------------------------------------------------- pre-checks
[ -f "$BASE" ] || die "Base image $BASE not found."
ip link show "$BRIDGE" > /dev/null 2>&1 || die "Bridge $BRIDGE not found. Run kvm-setup.sh first."
virsh dominfo "$NAME" > /dev/null 2>&1 && die "A VM named $NAME already exists."
[ -e "$IMG/$NAME.qcow2" ] && die "$IMG/$NAME.qcow2 already exists."

OSV=ubuntu24.04
osinfo-query os short-id="$OSV" 2> /dev/null | grep -q "$OSV" || OSV=ubuntu22.04

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------- cloud-init
cat > "$WORK/user-data" <<EOF
#cloud-config
preserve_hostname: true
manage_etc_hosts: false
users:
  - name: $VM_USER
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) ALL
    lock_passwd: false
    passwd: '$HASH'
    ssh_authorized_keys:
      - $PUBKEY
write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: 'network: {config: disabled}'
runcmd:
  - hostnamectl set-hostname $NAME.$DOMAIN
  - echo '$IP $NAME.$DOMAIN $NAME' >> /etc/hosts
EOF

cat > "$WORK/network-config" <<EOF
version: 2
ethernets:
  nic0:
    match:
      name: 'en*'
    addresses: [$IP/$PREFIX]
    routes:
      - to: default
        via: $GATEWAY
    nameservers:
      addresses: [$DNS]
      search: [$DOMAIN]
EOF

cat > "$WORK/meta-data" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF

# ------------------------------------------------------------- create VM
qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$IMG/$NAME.qcow2" "${DISK}G"
cloud-localds --network-config="$WORK/network-config" \
  "$IMG/$NAME-seed.img" "$WORK/user-data" "$WORK/meta-data"

virt-install --name "$NAME" --memory "$RAM" --vcpus "$CPUS" --os-variant "$OSV" \
  --import \
  --disk path="$IMG/$NAME.qcow2",format=qcow2 \
  --disk path="$IMG/$NAME-seed.img",device=cdrom \
  --network bridge="$BRIDGE",model=virtio \
  --graphics none --noautoconsole

virsh autostart "$NAME"

echo
echo "VM $NAME created. Wait about two minutes, then log in with:"
echo "  sudo ssh -i $KEY_FILE $VM_USER@$IP"
