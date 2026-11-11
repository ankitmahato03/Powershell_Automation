#!/usr/bin/env bash
# setup-kvm-host.sh
#
# Prepares an Ubuntu Server 24.04 machine as a KVM host:
#   1. installs KVM, libvirt and helper tools
#   2. checks hardware virtualisation support
#   3. creates a LAN bridge (br0) so VMs get their own IP addresses
#   4. downloads the Ubuntu 24.04 cloud image
#   5. installs the "create-vm" helper command
#   6. makes VMs start with the host and shut down cleanly
#
# Run it on the HOST (the physical machine), not inside a VM:
#   chmod +x setup-kvm-host.sh
#   sudo ./setup-kvm-host.sh
#
# By default the bridge reuses the NIC's current IP, gateway and DNS.
# Run it from the local console, or inside tmux/screen if you use SSH.
# Override the detected values for your network like this:
#   sudo env HOST_IP=192.168.1.5 GATEWAY=192.168.1.1 DNS=192.168.1.1 ./setup-kvm-host.sh

set -euo pipefail

BRIDGE=br0
NIC=${NIC:-$(ip -o route show default | awk '{print $5; exit}')}

# Default to the NIC's CURRENT address, gateway and DNS so the host keeps the
# same IP after the bridge is created (prevents losing SSH / network access).
CUR_CIDR=$( [ -n "$NIC" ] && ip -o -4 addr show dev "$NIC" 2> /dev/null | awk '{print $4; exit}' || true)
CUR_GW=$(ip -o route show default 2> /dev/null | awk '{print $3; exit}' || true)
CUR_DNS=$( [ -n "$NIC" ] && resolvectl dns "$NIC" 2> /dev/null | awk '{print $4; exit}' || true)

HOST_IP=${HOST_IP:-${CUR_CIDR%/*}}
PREFIX=${PREFIX:-${CUR_CIDR#*/}}
GATEWAY=${GATEWAY:-$CUR_GW}
DNS=${DNS:-${CUR_DNS:-$GATEWAY}}
IMG_DIR=/var/lib/libvirt/images
IMG_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
IMG_FILE=$IMG_DIR/noble-server-cloudimg-amd64.img

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Run this script with sudo."
[ -n "$NIC" ] || die "Could not detect the network interface. Re-run with NIC=<name>."

# ---------------------------------------------------------------- 1. packages
say "Installing KVM, libvirt and tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients \
  bridge-utils virtinst libosinfo-bin \
  cloud-image-utils cpu-checker whois wget

# ------------------------------------------------- 2. hardware virtualisation
say "Checking hardware virtualisation"
kvm-ok || die "KVM acceleration is not available. Enable Intel VT-x or AMD-V in the BIOS, then run this script again."

# ----------------------------------------------------- 3. services and groups
say "Enabling libvirt and adding your user to the libvirt and kvm groups"
systemctl enable libvirtd
systemctl restart libvirtd
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  usermod -aG libvirt,kvm "$SUDO_USER"
  echo "Added $SUDO_USER to the libvirt and kvm groups (log out and back in to apply)."
fi

say "Making VMs start with the host and shut down cleanly"
sed -i 's/^#\?ON_SHUTDOWN=.*/ON_SHUTDOWN=shutdown/' /etc/default/libvirt-guests
grep -q '^ON_SHUTDOWN=' /etc/default/libvirt-guests || echo 'ON_SHUTDOWN=shutdown' >> /etc/default/libvirt-guests
systemctl enable --now libvirt-guests

# ----------------------------------------------------------------- 4. bridge
say "Creating the $BRIDGE network bridge on $NIC"
if ip link show "$BRIDGE" > /dev/null 2>&1; then
  echo "$BRIDGE already exists; skipping."
else
  if [ -d "/sys/class/net/$NIC/wireless" ]; then
    die "$NIC is a Wi-Fi interface, which cannot be bridged. Use a wired connection."
  fi

  [ -n "$HOST_IP" ] && [ -n "$PREFIX" ] && [ -n "$GATEWAY" ] && [ -n "$DNS" ] || \
    die "Could not detect the network settings of $NIC. Re-run with HOST_IP=, PREFIX=, GATEWAY= and DNS= set."

  if systemctl is-active --quiet NetworkManager; then
    echo "WARNING: NetworkManager is running. This script configures the bridge with systemd-networkd."
    echo "         On Ubuntu Desktop, create the bridge with nmcli instead, or disable NetworkManager first."
  fi

  echo "Bridge settings:"
  echo "  NIC      : $NIC"
  echo "  Bridge   : $BRIDGE"
  echo "  Host IP  : $HOST_IP/$PREFIX   (current: ${CUR_CIDR:-none})"
  echo "  Gateway  : $GATEWAY"
  echo "  DNS      : $DNS"
  if [ -t 0 ]; then
    read -r -p "Continue with these settings? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted. Re-run with NIC=, HOST_IP=, PREFIX=, GATEWAY=, DNS= to change them."
  fi

  BACKUP=/root/netplan-backup-$(date +%F-%H%M%S)
  mkdir -p "$BACKUP"
  shopt -s nullglob
  for f in /etc/netplan/*.yaml; do
    mv "$f" "$BACKUP/"
  done
  shopt -u nullglob

  restore_network() {
    echo "Restoring the previous network settings from $BACKUP."
    rm -f /etc/netplan/01-bridge.yaml
    shopt -s nullglob
    for f in "$BACKUP"/*.yaml; do mv "$f" /etc/netplan/; done
    shopt -u nullglob
    ip link set "$BRIDGE" down 2> /dev/null || true
    ip link delete "$BRIDGE" type bridge 2> /dev/null || true
    netplan apply || true
  }

  cat > /etc/netplan/01-bridge.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $NIC: {}
  bridges:
    $BRIDGE:
      interfaces: [$NIC]
      addresses: [$HOST_IP/$PREFIX]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS]
      parameters:
        stp: false
        forward-delay: 0
EOF
  chmod 600 /etc/netplan/01-bridge.yaml

  # Validate the YAML before touching the live network.
  if ! netplan generate; then
    restore_network
    die "The generated netplan config is invalid (see the error above). The bridge was not set up."
  fi

  APPLIED=no
  if [ -t 0 ]; then
    echo "Applying with 'netplan try'. Press ENTER to confirm when asked."
    echo "If you are connected over SSH and the connection drops, wait 2 minutes: the old settings come back."
    if netplan try --timeout 120; then
      APPLIED=yes
    else
      echo "'netplan try' failed or was not confirmed (some netplan versions refuse to try bridge changes)."
    fi
  fi

  # Fallback: apply directly, then roll back automatically if the gateway is unreachable.
  if [ "$APPLIED" = no ]; then
    echo "Applying with 'netplan apply' and checking connectivity..."
    netplan apply || true
    for _ in $(seq 1 15); do
      ip -4 addr show dev "$BRIDGE" 2> /dev/null | grep -q "$HOST_IP/" && ping -c1 -W2 "$GATEWAY" > /dev/null 2>&1 && { APPLIED=yes; break; }
      sleep 2
    done
  fi

  if [ "$APPLIED" = no ] || ! ip -4 addr show dev "$BRIDGE" 2> /dev/null | grep -q "$HOST_IP/"; then
    restore_network
    die "The bridge was not set up: $BRIDGE did not come up with $HOST_IP or the gateway $GATEWAY was unreachable."
  fi

  echo "$BRIDGE is up with $HOST_IP/$PREFIX."
  bridge link 2> /dev/null | grep "$BRIDGE" || true
fi

# ---------------------------------------------------------- 5. cloud image
say "Downloading the Ubuntu 24.04 cloud image"
mkdir -p "$IMG_DIR"
if [ -f "$IMG_FILE" ]; then
  echo "$IMG_FILE already exists; skipping."
else
  wget -O "$IMG_FILE" "$IMG_URL"
fi

# ------------------------------------------------------ 6. create-vm helper
say "Installing the create-vm helper to /usr/local/bin/create-vm"
cat > /usr/local/bin/create-vm <<'VMSCRIPT'
#!/usr/bin/env bash
# Usage: create-vm NAME IP DNS_IP RAM_MB VCPUS DISK_GB
# Needs: SSH_PUBKEY_FILE (path to your public key) and PASSWORD_HASH (from mkpasswd) in the environment.
# Run it as your normal user, not with sudo.
set -euo pipefail

[ "$#" -eq 6 ] || { echo "Usage: create-vm NAME IP DNS_IP RAM_MB VCPUS DISK_GB"; exit 1; }

NAME=$1; IP=$2; DNS=$3; RAM=$4; CPUS=$5; DISK=$6
DOMAIN=${DOMAIN:-ad.ankinfo.online}
GATEWAY=${GATEWAY:-192.168.10.1}
IMG=/var/lib/libvirt/images
BASE=$IMG/noble-server-cloudimg-amd64.img
PUBKEY=$(cat "${SSH_PUBKEY_FILE:?set SSH_PUBKEY_FILE}")
HASH=${PASSWORD_HASH:?set PASSWORD_HASH}

[ -f "$BASE" ] || { echo "Base image $BASE not found."; exit 1; }
ip link show br0 > /dev/null 2>&1 || { echo "Bridge br0 not found."; exit 1; }

OSV=ubuntu24.04
osinfo-query os short-id="$OSV" 2> /dev/null | grep -q "$OSV" || OSV=ubuntu22.04

WORK=$(mktemp -d)

cat > "$WORK/user-data" <<EOF
#cloud-config
preserve_hostname: true
manage_etc_hosts: false
users:
  - name: admin
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
    addresses: [$IP/24]
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

sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$IMG/$NAME.qcow2" "${DISK}G"
sudo cloud-localds --network-config="$WORK/network-config" "$IMG/$NAME-seed.img" "$WORK/user-data" "$WORK/meta-data"
sudo virt-install --name "$NAME" --memory "$RAM" --vcpus "$CPUS" --os-variant "$OSV" \
  --import \
  --disk path="$IMG/$NAME.qcow2",format=qcow2 \
  --disk path="$IMG/$NAME-seed.img",device=cdrom \
  --network bridge=br0,model=virtio \
  --graphics none --noautoconsole
sudo virsh autostart "$NAME"
rm -rf "$WORK"

echo "VM $NAME created. Wait about two minutes, then: ssh admin@$IP"
VMSCRIPT
chmod +x /usr/local/bin/create-vm

# --------------------------------------------------------------------- done
say "KVM host setup finished"
cat <<EOF

Next steps:
  1. Log out and back in so the libvirt group applies.
  2. Create your SSH key if you do not have one:   ssh-keygen -t ed25519
  3. Prepare the VM settings:
       export SSH_PUBKEY_FILE=\$HOME/.ssh/id_ed25519.pub
       export PASSWORD_HASH=\$(mkpasswd --method=SHA-512)
  4. Create the domain controller VM:
       create-vm dc1 192.168.10.10 $DNS 3072 2 40
  5. After the domain controller works, create the Landscape VM:
       create-vm landscape 192.168.10.20 192.168.10.10 8192 2 100
EOF
