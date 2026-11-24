# RB5009 QoS fixes: IPv6 fasttrack, per-class upload, log split

**Date:** 2026-10-16 (late evening)
**Router:** RTR-HOMELAB-CN-1, RB5009UG+S+, RouterOS 7.23.5
**Note:** the 192.168.5.14 static DHCP lease is stale (VM gone) and can be removed.
**Trigger:** game disconnects when son's PC (Wi-Fi, WiFi-Main) comes online
**Rollback file on router:** `pre-qos-split-2026-10-16.rsc` (full `/export` taken before any change)

## What the audit found

**1. IPv6 fasttrack was enabled (root-cause candidate).**
`/ipv6 firewall filter` rule `forward: fasttrack6` was active, and
`ipv6-fasttrack-active: yes` with ~1.13 billion packets / ~1.37 TB fasttracked.
The `cake-download` global tree had seen only ~637 GB. Fasttracked packets skip
`parent=global` queue trees, so most real-world download traffic (Steam, Windows
Update, Xbox, CDNs, all IPv6-preferring) was not shaped at all. This is
Gotcha #3 in `rb5009-cake-qos-config.md`; the rule was disabled in July and
later came back on. A cold-boot update burst on son's PC therefore hit the
modem/CMTS buffer unshaped.

**2. Upload saturates regularly.** ether1 tx-queue-drop was 6.13M of ~508M tx
packets (~1.2%) over 29 days. CAKE only drops when the 38M cap is full.

**3. Topology changed since the July tuning.** ether5 is down; VLAN traffic now
comes in over `sfp-sfpplus1` (only-hardware-queue by design). The per-port
`cake-down` queues on ether2-7 are no longer on the desktop/Wi-Fi path, so
download is shaped by the global tree alone (July test #3 config: grade B, +35 ms).

**4. Log flooded.** 903 of 1000 memory-log lines were `AGENT-DROP`: agent box
192.168.99.3 attempting SMTP (tcp/25) to Microsoft mail servers every few
seconds. The buffer covered only ~2 hours, so drop events weren't retained.

**Ruled out:** UPnP (disabled, no dynamic NAT), conntrack exhaustion (160 of
966k), WAN link problems (0 link-downs, 0 rx errors, DHCP bound, single v6
default route), IPv4 fasttrack (disabled, 0 packets).

**Noted, not changed:**
- "Living-Room" device (Wi-Fi MAC ...F5:F3) joins and drops WiFi-Main every ~6 min all evening.
- pibox (VLAN5 + DMZ) and nas show the IPv6 Router flag (likely Docker/forwarding). Check the
  gaming VM for extra `::/0` routes with `route print -6`.
- vlan5sfp tx-drop ~4.9k, matching sfp-sfpplus1 tx-queue-drop.

## Changes made

```
# 1. IPv6 fasttrack off (global tree now sees v6 download)
/ipv6 firewall filter disable [find comment="forward: fasttrack6"]

# 2. Logging: firewall messages get their own buffer, main log enlarged
/system logging action add name=fwmemory target=memory memory-lines=2000
/system logging action set [find name=memory] memory-lines=5000
/system logging set 0 topics=info,!firewall
/system logging add topics=firewall action=fwmemory

# 3. Upload rebuilt as HTB classes (replaces cake-up on the ether1 interface queue)
/queue type add name=cake-up-class kind=cake cake-diffserv=diffserv4 \
    cake-flowmode=dual-srchost cake-nat=yes cake-ack-filter=filter cake-rtt=100ms

# mangle, same four rules in /ip and /ipv6 (order matters: later rules overwrite)
add chain=forward out-interface=ether1 action=mark-packet new-packet-mark=up-other passthrough=yes comment="qos-up: default class"
add chain=forward out-interface=ether1 in-interface=bridge30 action=mark-packet new-packet-mark=up-wifi passthrough=yes comment="qos-up: WiFi-Main wifi class"
add chain=forward out-interface=ether1 src-mac-address=02:00:5e:03:3d:db action=mark-packet new-packet-mark=up-game passthrough=yes comment="qos-up: admin workstation 5.9 (game class)"
add chain=forward out-interface=ether1 src-mac-address=02:00:5E:31:13:ED action=mark-packet new-packet-mark=up-game passthrough=yes comment="qos-up: laptop DESKTOP-K49Q9G5 (game class)"

/queue tree
add name=cake-upload parent=global max-limit=38M comment="qos-up: parent, replaces ether1 interface queue"
add name=up-game  parent=cake-upload packet-mark=up-game  limit-at=12M max-limit=38M priority=1 queue=cake-up-class
add name=up-wifi  parent=cake-upload packet-mark=up-wifi  limit-at=14M max-limit=38M priority=4 queue=cake-up-class
add name=up-other parent=cake-upload packet-mark=up-other limit-at=8M  max-limit=38M priority=6 queue=cake-up-class

/queue interface set [find interface=ether1] queue=only-hardware-queue
```

### Follow-up (2026-10-17, ~00:15): DNS priority class + Jellyfin cleanup

```
# upstream DNS gets its own top-priority class (same rules in /ip and /ipv6)
add chain=forward out-interface=ether1 protocol=udp dst-port=53,853 action=mark-packet new-packet-mark=up-dns passthrough=yes comment="qos-up: resolver upstream DNS udp"
add chain=forward out-interface=ether1 protocol=tcp dst-port=53,853 action=mark-packet new-packet-mark=up-dns passthrough=yes comment="qos-up: resolver upstream DNS tcp/DoT"

/queue tree add name=up-dns parent=cake-upload packet-mark=up-dns limit-at=2M max-limit=38M \
    priority=1 queue=cake-up-class comment="qos-up: resolver upstream DNS/DoT"

# rule 27 was mislabeled "clients to jellyfin reverse proxy"; it is the only rule letting LAN
# clients reach NPM on pibox (10.20.0.2:80,443), which still fronts Nextcloud, Homepage and sup.
/ip firewall filter set [find comment="forward: clients to jellyfin reverse proxy"] \
    comment="forward: clients to NPM reverse proxy (pibox: nextcloud, homepage, sup)"
```

Why port-based: the DNS egress policy (dst-nat redirect + forward drops for lan-clients and DMZ)
means only the resolvers can send 53/853 to the internet, so this covers every current resolver
(Technitium + Unbound, VLAN 15 and DMZ) and any future one, including one on a new VLAN.
Verified: DoT (tcp/853) packets landing in up-dns over both IPv4 and IPv6; UDP 53 count is
zero, which confirms the resolvers forward upstream over TLS only.
Class guarantees now total 12 + 14 + 8 + 2 = 36M, under the 38M parent.

Jellyfin search covered /ip and /ipv6 firewall filter, nat, mangle, raw and address-lists, plus
/ip dns static and DHCP leases. Rule 27 was the only hit. Anything outside the router (Technitium
records, NPM proxy host on pibox, Homepage tiles, Uptime Kuma monitors) was not checked.

Game class = the primary admin workstation (192.168.5.9, MAC 02:00:5e:03:3d:db,
VLAN 5, `admin` address-list entry "the admin desktop") plus the admin's laptop DESKTOP-K49Q9G5
(Wi-Fi MAC 02:00:5E:31:13:ED, WiFi-Guest SSID, 192.168.20.3). The laptop matches on its Wi-Fi
MAC only; if it is ever docked on Ethernet, that NIC's MAC needs its own rule. A rule for the old gaming VM
(192.168.5.14, 02:00:5E:37:BF:B5, last seen ~4 weeks ago; that VM no longer exists) was
added at first and then removed the same night.

Design: each class is guaranteed its `limit-at` (12+14+8 = 34M, under the 38M parent)
and can borrow to the full 38M when the others are idle. Priority decides who borrows
first. The gaming class keeps its 12M floor no matter how many flows son's PC opens.
Marks are set in the forward chain, before srcnat, so they survive masquerade. MAC
matching covers both IPv4 and IPv6 (including Windows temporary v6 addresses).
`cake-bandwidth` is intentionally unset on the leaf type; only HTB `max-limit` binds
inside a tree (Gotcha #1).

Verified right after the change: traffic counting in `cake-upload` and `up-other`; IPv4 and
IPv6 mangle counters incrementing for the default and WiFi-Main Wi-Fi classes; internet working.

## Still to do

- Safe Mode committed by the admin shortly after midnight; the laptop rule was added after that and is permanent.
- Existing IPv6 connections keep their fasttrack flag until they close. New ones are shaped.
- Fix the SMTP attempts on the agent box (cron MAILTO / Webmin / postfix). Firewall logs are
  now isolated in `fwmemory`, so they no longer push out the main log.
- Re-run Waveform several times (best of 3) to confirm download is under control now that
  IPv6 is shaped; retune the tree's `max-limit` if needed (change both values together).
- If son's PC gets a fixed Wi-Fi MAC, give it its own class instead of sharing up-wifi.

## Rollback

Full: `/import pre-qos-split-2026-10-16.rsc` is NOT a clean rollback on a live config; revert
piecewise instead:
```
/queue interface set [find interface=ether1] queue=cake-up
/queue tree remove [find parent=cake-upload]
/queue tree remove [find name=cake-upload]
/ip firewall mangle remove [find comment~"qos-up"]
/ipv6 firewall mangle remove [find comment~"qos-up"]
/queue type remove [find name=cake-up-class]
/ipv6 firewall filter enable [find comment="forward: fasttrack6"]   # not recommended
```
