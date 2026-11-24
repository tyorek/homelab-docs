#!/usr/bin/env bash
# pibox routing cleanup (after the NIC swap).
#   br1 / DMZ (eth0 port)  -> the ONLY default route (DHCP from 10.20.0.1)
#   enp1s0u1 / VLAN 5      -> no gateway/DNS/routes from DHCP; own table 200
#                             so anything addressed to 192.168.5.5 answers from VLAN 5
#   DCs 192.168.20.7/.6    -> host routes via VLAN 5 (domain traffic stays on the data side)
#   IPv6 on VLAN 5         -> RA off (stops a second IPv6 default route; link-local kept)
# Writes /etc/netplan/50-pibox.yaml and validates it. Does NOT apply.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }

F=/etc/netplan/50-pibox.yaml
[[ -f $F ]] || { echo "$F not found - is the NIC swap config in place?" >&2; exit 1; }

BACKUP=/root/netplan-backup/$(date +%Y%m%d-%H%M%S)-pre-routing
mkdir -p "$BACKUP"
cp -a /etc/netplan/*.yaml "$BACKUP/"
echo "Backed up current netplan files to $BACKUP"

NEW=$(mktemp)
cat > "$NEW" <<'YAML'
network:
  version: 2
  ethernets:
    eth0:                         # onboard (1500 max), DMZ bridge port
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      mtu: 1500
    enp1s0u1:                     # USB Realtek, VLAN 5 storage (jumbo)
      dhcp4: true
      mtu: 9000
      accept-ra: false            # no second IPv6 default route via VLAN 5
      dhcp4-overrides:
        use-routes: false         # no default gateway / DHCP routes from VLAN 5
        use-dns: false            # no DNS servers or DNS host routes from VLAN 5
      dhcp6-overrides:            # networkd requires these to match dhcp4
        use-routes: false
        use-dns: false
      routes:
        - to: 192.168.5.0/28      # table 200: replies from 192.168.5.5 leave via VLAN 5
          scope: link
          table: 200
        - to: default
          via: 192.168.5.1
          on-link: true
          table: 200
        - to: 192.168.20.7/32     # dc01 - domain traffic stays on the data side
          via: 192.168.5.1
        - to: 192.168.20.6/32     # dc02
          via: 192.168.5.1
      routing-policy:
        - from: 192.168.5.5
          table: 200
          priority: 200
  bridges:
    br1:
      interfaces: [eth0]
      macaddress: 02:00:5e:6b:55:70   # keeps 10.20.0.2 and the DMZ IPv6 addresses
      dhcp4: true                     # provides the only default route + DNS
      mtu: 1500
YAML

echo
echo "===== Changes to $F ====="
diff -u "$F" "$NEW" || true
echo "=========================="
read -r -p "Write this to $F? [y/N] " ans
[[ ${ans,,} == y ]] || { echo "Aborted, nothing changed."; rm -f "$NEW"; exit 0; }

install -m 600 "$NEW" "$F"
rm -f "$NEW"
netplan generate && echo "GENERATE_OK - config written and valid (not applied yet)"
echo
echo "Next, at the console:"
echo "  tmux new -s net"
echo "  sudo netplan try        # then check before pressing Enter:"
echo "    ip route              # ONE default: via 10.20.0.1 dev br1"
echo "    ip rule               # 200: from 192.168.5.5 lookup 200"
echo "    ip route show table 200"
echo "    ip route get 10.20.0.9            # dev br1"
echo "    ip route get 1.1.1.1 from 192.168.5.5   # dev enp1s0u1"
echo "Rollback: sudo cp $BACKUP/50-pibox.yaml $F && sudo netplan apply"
