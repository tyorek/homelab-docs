#!/bin/sh
# 2026-11-21: enforce the DMZ (br1) / VLAN 5 (eth1) split on pibox.
#  - Nothing is routed in from or out to the VLAN 5 leg: not containers, not guests, not a DMZ
#    host using pibox as a router. pibox's own SMB/NFS/Kerberos/DNS traffic on eth1 is host
#    traffic (INPUT/OUTPUT) and is not affected.
#  - NPM's published ports (80/81/443) do not answer on the VLAN 5 leg (v4 DNAT and v6 docker-proxy).
#  - New connections from the Docker networks use table 110 (default via br1), so every NPM
#    backend goes through fw-edge and its DMZ rules (1030-1036). DMZ-local peers stay on-link.
# Lives in its own nftables table so OMV firewall applies and Docker restarts never touch it.
# If the table-110 rule is ever missing, container traffic to VLAN 5 is dropped (fails closed).
# Rollback: systemctl disable --now pibox-isolation; nft delete table inet pibox_isolation;
#   ip rule del priority 139; ip rule del priority 140
set -e
nft -f - <<'NFT'
table inet pibox_isolation
delete table inet pibox_isolation
table inet pibox_isolation {
  chain forward {
    type filter hook forward priority -5; policy accept;
    iifname { "eth1", "enp1s0u1" } limit rate 6/minute burst 10 packets log prefix "pibox-iso fwd-in: " level info
    iifname { "eth1", "enp1s0u1" } counter drop comment "nothing is routed in from VLAN 5"
    oifname { "eth1", "enp1s0u1" } limit rate 6/minute burst 10 packets log prefix "pibox-iso fwd-out: " level info
    oifname { "eth1", "enp1s0u1" } counter drop comment "nothing is routed out to VLAN 5"
  }
  chain input {
    type filter hook input priority -5; policy accept;
    iifname { "eth1", "enp1s0u1" } tcp dport { 80, 81, 443 } limit rate 6/minute burst 10 packets log prefix "pibox-iso npm-port: " level info
    iifname { "eth1", "enp1s0u1" } tcp dport { 80, 81, 443 } counter drop comment "NPM ports are DMZ-only"
  }
}
NFT
ip rule show | grep -q 'from 172.16.0.0/12 to 10.20.0.0/25 lookup main' || ip rule add from 172.16.0.0/12 to 10.20.0.0/25 table main priority 139
ip rule show | grep -q 'from 172.16.0.0/12 lookup 110' || ip rule add from 172.16.0.0/12 table 110 priority 140
