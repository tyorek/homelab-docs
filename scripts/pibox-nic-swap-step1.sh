#!/usr/bin/env bash
# pibox NIC role swap, step 1: back up netplan and stage the new config.
# Does NOT apply anything. OMV's files stay in place until step 3.
#   VLAN 5 storage -> enp1s0u1 (USB Realtek, MTU 9000)
#   br1 / DMZ      -> eth0 (onboard bcmgenet, MTU 1500)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

BACKUP=/root/netplan-backup/$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP"
cp -a /etc/netplan/*.yaml "$BACKUP/"
echo "Backed up current netplan files to $BACKUP"

cat > /etc/netplan/50-pibox.yaml <<'YAML'
network:
  version: 2
  ethernets:
    eth0:                         # onboard (1500 max), now the DMZ bridge port
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      mtu: 1500
    enp1s0u1:                     # USB Realtek (9194 max), now VLAN 5 storage
      dhcp4: true
      mtu: 9000
  bridges:
    br1:
      interfaces: [eth0]
      macaddress: 02:00:5e:6b:55:70   # keeps 10.20.0.2 and the IPv6 addresses
      dhcp4: true
      mtu: 1500
YAML
chmod 600 /etc/netplan/50-pibox.yaml
echo "Staged /etc/netplan/50-pibox.yaml (not applied)."

# Park it inactive until step 3 so a reboot or netplan apply before then
# doesn't merge it with OMV's files.
mv /etc/netplan/50-pibox.yaml /root/netplan-backup/50-pibox.yaml.staged
echo "Parked as /root/netplan-backup/50-pibox.yaml.staged"
echo
echo "Step 2 (router), right before step 3:"
echo '  /ip dhcp-server lease make-static [find address=192.168.5.5]'
echo '  /ip dhcp-server lease set [find address=192.168.5.5] mac-address=02:00:5e:be:56:86 comment="pibox VLAN5 (USB NIC, jumbo)"'
echo
echo "Step 3 (pibox console):"
echo "  sudo mkdir -p /root/netplan-backup/active-removed"
echo "  sudo mv /etc/netplan/20-openmediavault-eth0.yaml /etc/netplan/60-openmediavault-br1.yaml /root/netplan-backup/active-removed/"
echo "  sudo cp /root/netplan-backup/50-pibox.yaml.staged /etc/netplan/50-pibox.yaml && sudo chmod 600 /etc/netplan/50-pibox.yaml"
echo "  # swap the two Ethernet cables at the Pi"
echo "  sudo netplan try"
