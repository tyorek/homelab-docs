# iot-vlan25-firewall.rsc
# IoT VLAN 25 isolation -- bridge25, 192.168.25.0/25, v6 2001:db8:4a00:2b03::/64 + fd12:3456:789a:25::/64
#
# ############################################################################################
# STATUS: COMPLETE -- 2026-10-26. All household IoT now lives on VLAN 25.
# This file is the as-built record (router + AG01 + AG02 + AG03 + Asus EBP15). Re-running the
# `add` lines would duplicate rules -- use it as reference / for rebuild, not as a paste script.
# ############################################################################################
#
# ---- FINAL POLICY (what VLAN 25 devices can and cannot do) ----
# CAN:    reach the internet (v4 + v6); resolve DNS via the local authoritative resolvers only
#         (dns-auth 192.168.15.9 / 10.20.0.9 and dns-auth6), port 53 udp/tcp; get DHCP from the RB5009.
# CANNOT: reach any other VLAN; be reached from any other VLAN (incl. admin desktop, NPM/caddy, VLAN 20);
#         reach the RB5009 itself (IP, MAC-winbox/telnet, MNDP/CDP/LLDP, RoMON) beyond DHCP + v6 ND;
#         reach any switch's management -- no switch CPU is a member of VLAN 25 and none has a VLAN 25 IP.
# Existing DNS policy / fallback gate / DNAT redirect still apply (VLAN 25 is in lan-clients), so
# DoT 853 and hardcoded public DNS are blocked/redirected. Pre-existing "G9 block internet" (192.168.25.5)
# still wins at the top of the forward chain.
#
# ---- WHERE VLAN 25 LIVES (L2 path) ----
# RB5009: bridge25 = vlan25sfpplus (sfp-sfpplus1 -> AG01) + vlan25cap (bridgecap/ether4 -> cAP, WiFi-IoT SSID)
#                    + vlan25ether3 (ether3 -> Asus port 1). Gateway 192.168.25.1, DHCP server dhcp6.
# AG01 (CRS305 99.4): tagged sfp1 (RB5009) + sfp3 (AG02). CPU removed.
# AG02 (CRS305 99.5): tagged sfp1 (AG01), untagged/PVID25 sfp3 (access). CPU removed.
# Asus EBP15 (192.168.1.50): tagged p1 (RB5009 ether3) + p2 (AG03), untagged/PVID25 p4 + p5 (access).
# AG03 (hEX 99.6): tagged ether1 (Asus p2), untagged/PVID25 ether3 (access). CPU not a member.
# cAP: CAPsMAN-managed; VLAN 25 rides back to the router's bridgecap -- no change needed.
#
# ---- BACKUPS TAKEN (on each device) ----
# RB5009: backup-pre-iot25-lockdown.rsc, backup-pre-redundant-cleanup.rsc, backup-pre-vlan25-ether3.rsc
# AG01 / AG02: backup-pre-iot25-fabric.rsc   AG03: backup-pre-iot25-fabric.rsc, backup-pre-vlan20-port-moves.rsc
#
# ---- EXPECTED IN THE NEXT mikrotik-audit DIFF / DAILY DIGEST (all intentional, approved 2026-10-26) ----
# RB5009: +7 IoT25 v4 filter rules, +10 IoT25 v6 filter rules; -13 redundant forward rules; mgmt-client
#   list renamed mgmt-clients + rule 21 excludes 99.3; new interface lists IOT / MGMT-L2 / DISCOVERY;
#   mac-server + mac-winbox -> MGMT-L2; discovery -> DISCOVERY; RoMON forbid on vlan25sfpplus/vlan25cap/
#   vlan25ether3; vlan25ether3 added to bridge25; comments added to the two proxy rules.
# AG01 / AG02: vlan25 interface + its DHCP client disabled; bridge removed from VLAN 25 tagged list;
#   192.168.25.2 / .6 leases gone from the router.
# AG03: new VLAN 25 (tag ether1, untag ether3) and VLAN 20 (tag bridge+ether1, untag ether4) entries;
#   ether3 PVID 10->25, ether4 PVID 10->20; VLAN 10 untagged now ether2 only.
# None of the above should be triaged as unauthorized change.
#
# ---- REMAINING FOLLOW-UPS (not part of this change) ----
# - Asus management still on VLAN 1, untagged on ports 1-3 -> leaks into AG03 VLAN 5 / port-3 device.
#   Fix: move Asus mgmt to VLAN 99, verify reachability, then strip VLAN 1 from ports 2-3.
# - AG01/AG02/AG03: no firewall; ftp/telnet/ssh/www/winbox/api unrestricted -> restrict to mgmt VLAN 99.
# - Switches still install an ECMP default route per DHCP-client VLAN.
# - VLAN 20 DHCP pool is a /28 (14 hosts) -- ether4 on AG03 is now a VLAN 20 access port.
#
# ============================================================================================
# CHANGE LOG / AS-BUILT DETAIL (chronological)
# ============================================================================================
#
# ==== 2026-10-26 (1): router -- IoT25 filter rules (Safe Mode, committed) ====
/ip firewall filter
add chain=input action=accept in-interface=bridge25 protocol=udp dst-port=67 comment="IoT25: DHCP to router" place-before=[find comment="input: icmp"]
add chain=input action=drop in-interface=bridge25 comment="IoT25: no router access" place-before=[find comment="input: icmp"]
add chain=forward action=drop in-interface-list=!WAN out-interface=bridge25 comment="IoT25: other VLANs -> IoT blocked" place-before=[find comment="forward: admin desktop to all vlans"]
add chain=forward action=accept in-interface=bridge25 out-interface-list=WAN comment="IoT25: internet" place-before=[find comment="forward: dns udp"]
add chain=forward action=accept in-interface=bridge25 dst-address-list=dns-auth protocol=udp dst-port=53 comment="IoT25: local DNS udp" place-before=[find comment="forward: dns udp"]
add chain=forward action=accept in-interface=bridge25 dst-address-list=dns-auth protocol=tcp dst-port=53 comment="IoT25: local DNS tcp" place-before=[find comment="forward: dns udp"]
add chain=forward action=drop in-interface=bridge25 log=yes log-prefix=ISO25 comment="IoT25: drop all else (inter-VLAN)" place-before=[find comment="forward: dns udp"]

/ipv6 firewall filter
add chain=input action=accept in-interface=bridge25 protocol=icmpv6 icmp-options=133:0 comment="IoT25 v6: ND router solicit" place-before=[find comment="input: icmpv6"]
add chain=input action=accept in-interface=bridge25 protocol=icmpv6 icmp-options=135:0 comment="IoT25 v6: ND neighbor solicit" place-before=[find comment="input: icmpv6"]
add chain=input action=accept in-interface=bridge25 protocol=icmpv6 icmp-options=136:0 comment="IoT25 v6: ND neighbor advert" place-before=[find comment="input: icmpv6"]
add chain=input action=drop in-interface=bridge25 comment="IoT25 v6: no router access" place-before=[find comment="input: icmpv6"]
add chain=forward action=drop in-interface-list=!WAN out-interface=bridge25 comment="IoT25 v6: other VLANs -> IoT blocked" place-before=[find comment="forward: icmpv6"]
add chain=forward action=drop in-interface=bridge25 out-interface-list=!WAN protocol=icmpv6 comment="IoT25 v6: no ICMPv6 to other VLANs" place-before=[find comment="forward: icmpv6"]
add chain=forward action=accept in-interface=bridge25 out-interface-list=WAN comment="IoT25 v6: internet" place-before=[find comment="forward: dns6 udp"]
add chain=forward action=accept in-interface=bridge25 dst-address-list=dns-auth6 protocol=udp dst-port=53 comment="IoT25 v6: local DNS udp" place-before=[find comment="forward: dns6 udp"]
add chain=forward action=accept in-interface=bridge25 dst-address-list=dns-auth6 protocol=tcp dst-port=53 comment="IoT25 v6: local DNS tcp" place-before=[find comment="forward: dns6 udp"]
add chain=forward action=drop in-interface=bridge25 log=yes log-prefix=ISO25-6 comment="IoT25 v6: drop all else (inter-VLAN)" place-before=[find comment="forward: dns6 udp"]

# ---- PLACEMENT (verified with plain `print terse` after apply) ----
# v4 input:  after "input: drop invalid", before "input: icmp" (so IoT can't ping/NTP/CAPWAP the router)
# v4 fwd:    inbound block right after "forward: drop invalid" (above admin-desktop/proxy accepts);
#            egress block AFTER the DNS policy + fallback-gate drops and BEFORE "forward: dns udp" /
#            "forward: infra vlan20 in" (the latter previously let VLAN 25 reach all of VLAN 20).
# v6 fwd:    inbound block + ICMPv6 inter-VLAN drop above "forward: icmpv6" (which accepts all ICMPv6);
#            egress block after DNS policy/fallback drops, before "forward: dns6 udp".
# The pre-existing "G9 block internet" rule (192.168.25.5 -> WAN drop) stays at the top and still wins.
#
# ---- VERIFIED 2026-10-26 (live counters, ~2 min) ----
# IoT25 local DNS udp: 91 pkts accepted (G9 queries -> 10.20.0.9, DNAT'd to 15.9, answered)
# IoT25 no router access: 30 pkts dropped; v6 ND NS/NA accepted; v6 internet accepted
# IoT25 internet (v4): 0 -- only active host at the time was the G9, which is internet-blocked upstream.
# Re-check `/ip firewall filter print stats where comment~"IoT25"` once TVs/consoles are on.
#
# ---- ROLLBACK ----
# /ip firewall filter remove [find comment~"^IoT25"]
# /ipv6 firewall filter remove [find comment~"^IoT25"]
#
# ---- FOLLOW-UPS NOTED ----
# - AG01 (192.168.25.2) and AG02 (192.168.25.6) hold DHCP addresses on VLAN 25. IoT hosts reach
#   those L2-local, so the router firewall can't protect them -- drop the switches' VLAN 25 IP/DHCP client.
# - FIXED 2026-10-26: forward rule referenced src-address-list=mgmt-clients but the list was named
#   mgmt-client, so the rule matched nothing. Renamed the list to mgmt-clients (192.168.99.0/28) and
#   excluded the agent LXC so its egress lockdown (lower in the chain) isn't bypassed:
#     /ip firewall address-list set [find list=mgmt-client] list=mgmt-clients
#     /ip firewall filter set <rule> src-address=!192.168.99.3 comment="forward: mgmt vlan99 to all vlans (excl. agent LXC)"
#   Rule sits below "IoT25: other VLANs -> IoT blocked", so VLAN 25 stays isolated from VLAN 99 too.

# ==== 2026-10-26 (2): redundant-rule cleanup + L2 lockdown of the router from VLAN 25 ====
# Applied in Safe Mode, committed. Router backup: backup-pre-redundant-cleanup.rsc
#
# Removed 13 forward rules shadowed by earlier accepts (all showed 0 hits after counter reset):
#   shadowed by "forward: mgmt vlan99 to all vlans (excl. agent LXC)":
#     homepage: Unbound probes tcp/udp, homepage: Technitium API, homepage: pibox OMV,
#     kuma: pibox SMB + OMV, forward: proxmox mgmt to wazuh manager
#   shadowed by local-proxy / "public proxy " accepts:
#     forward: caddy to internal backends, forward: npm to internal backends
#   shadowed by "forward: dns udp/tcp" (no WireGuard/non-LAN sources exist):
#     clients to buauth DNS udp/tcp, agent: DNS udp/tcp
#   no-op (agent 99.3 -> Proxmox 99.2 is same subnet, never routed): agent: Proxmox API
# Commented the two previously comment-less proxy rules.
# NAT rule "homepage: Unbound probes skip the resolver redirect" KEPT (still needed).
#
# L2 / management-plane lockdown (router only; VLAN 25 forwarding untouched):
/interface list add name=IOT comment="IoT VLAN 25 interfaces"
/interface list member add list=IOT interface=bridge25
/interface list member add list=IOT interface=vlan25cap
/interface list member add list=IOT interface=vlan25sfpplus
/interface list add name=MGMT-L2 include=LAN exclude=IOT comment="MAC-winbox/MAC-telnet: LAN minus IoT"
/interface list add name=DISCOVERY include=all exclude=IOT,WAN comment="neighbor discovery: everything except IoT and WAN"
/tool mac-server set allowed-interface-list=MGMT-L2
/tool mac-server mac-winbox set allowed-interface-list=MGMT-L2
/ip neighbor discovery-settings set discover-interface-list=DISCOVERY
/tool romon port add interface=vlan25sfpplus forbid=yes comment="IoT: no RoMON"
/tool romon port add interface=vlan25cap forbid=yes comment="IoT: no RoMON"
# (RoMON rejects bridge interfaces as ports -- forbidding the two VLAN 25 ingress vlan interfaces covers it.)
# Side effect: discovery no longer advertises on WAN (ether1) either.

# ==== 2026-10-26 (3): fabric -- AG01 (CRS305, 192.168.99.4) removed from VLAN 25 as a host ====
# VLAN 25 is still SWITCHED (sfp-sfpplus1 = uplink to RB5009, sfp-sfpplus3 = to AG02); only the
# switch CPU's membership + L3 presence on VLAN 25 was removed. Applied in Safe Mode, committed.
# Switch backup: backup-pre-iot25-fabric.rsc
/ip dhcp-client set [find interface=vlan25] disabled=yes comment="IoT25: switch has no L3 presence on VLAN 25"
/interface vlan set [find name=vlan25] disabled=yes comment="IoT25: CPU not on VLAN 25 -- VLAN still switched sfp1<->sfp3"
/interface bridge vlan set [find vlan-ids=25] tagged=sfp-sfpplus1,sfp-sfpplus3 comment="IoT25: trunk only, CPU (bridge) removed"
# Result: 192.168.25.2 + its fe80 link-local gone; MAC-winbox/MNDP/RoMON can't see VLAN 25 frames since the
# CPU port isn't a member. Verified: VLAN 25 hosts re-learned on sfp3 (AG02 side) and sfp1 (router side).
# Revert: tagged=AG01_bridge,sfp-sfpplus1,sfp-sfpplus3 and re-enable vlan25 + client5.
#
# AG01 findings OUTSIDE this change (not touched):
# - No firewall at all; ftp/telnet/ssh/www/winbox/api/api-ssl enabled with no address restriction
#   (reachable from every VLAN the switch still has an IP on: 5, 10, 15, 20, 99).
# - DHCP clients on every VLAN each install a default route (5 ECMP defaults remain).

# ==== 2026-10-26 (4): fabric -- AG02 (CRS305, 192.168.99.5) removed from VLAN 25 as a host ====
# VLAN 25 still SWITCHED: sfp-sfpplus1 tagged (uplink to AG01), sfp-sfpplus3 untagged access port (PVID 25,
# where 192.168.25.7/.8 live). Only the CPU membership + L3 presence removed. Safe Mode, committed.
# Switch backup: backup-pre-iot25-fabric.rsc
/ip dhcp-client set [find interface=vlan25] disabled=yes comment="IoT25: switch has no L3 presence on VLAN 25"
/interface vlan set [find name=vlan25] disabled=yes comment="IoT25: CPU not on VLAN 25 -- VLAN still switched sfp1(tagged)<->sfp3(access)"
/interface bridge vlan set [find vlan-ids=25] tagged=sfp-sfpplus1 untagged=sfp-sfpplus3 comment="IoT25: trunk/access only, CPU (bridge) removed"
# Verified: 192.168.25.6 + fe80 on vlan25 gone; current-tagged=sfp1, current-untagged=sfp3; access-port hosts
# 02:00:5e:96:8a:38 / 02:00:5e:ef:4b:78 re-learned on sfp3 and router MAC on sfp1 after the change.
# Revert: tagged=AG02_bridge,sfp-sfpplus1 untagged=sfp-sfpplus3 and re-enable vlan25 + client3.
# Same out-of-scope findings as AG01: no firewall, all services unrestricted, ECMP default per VLAN DHCP client.

# ==== cAP (cAPGi-5HaxD2HaxD, 10.20.0.6) -- no change needed ====
# CAPsMAN-managed; VLAN 25 (WiFi-IoT SSID) is tagged back over ether4 into the router's bridgecap ->
# vlan25cap -> bridge25. The cAP's own management is untagged on ether4 (bridgecap pvid=10, VLAN 10)
# and it holds no VLAN 25 lease/neighbor entry. Every VLAN 25 path to a CPU therefore terminates on the
# RB5009, which is covered by: IoT25 input drops (v4/v6), vlan25cap in the IOT list (excluded from
# MAC-server/MAC-winbox via MGMT-L2 and from discovery), and RoMON forbid on vlan25cap.

# ==== 2026-10-26 (5): VLAN 25 extended to AG03 (RB750Gr3 hEX, 192.168.99.6) via router ether3 + Asus ====
# AG03 (Safe Mode, committed; switch backup backup-pre-iot25-fabric.rsc). Uplink only for now, per the admin.
/interface bridge vlan add bridge=AG03_Bridge vlan-ids=25 tagged=ether1 comment="IoT25: trunk only, CPU (bridge) intentionally NOT a member; add access ports here"
# No vlan25 interface / DHCP client / IP created on AG03 -- same posture as AG01/AG02.
# To add an access port later:  /interface bridge vlan set [find vlan-ids=25] untagged=etherX
#                               /interface bridge port set [find interface=etherX] pvid=25
#
# Router (Safe Mode, committed; backup backup-pre-vlan25-ether3.rsc). vlan25ether3 (ether3, vid 25, mtu 9014)
# already existed (created by the admin) with no bridge port/IP; attached it:
/interface bridge port add bridge=bridge25 interface=vlan25ether3 comment="IoT25: trunk via Asus to AG03"
/interface list member add list=IOT interface=vlan25ether3
/tool romon port add interface=vlan25ether3 forbid=yes comment="IoT: no RoMON"
# IoT25 filter rules match in-interface=bridge25, so traffic arriving via ether3 is covered automatically;
# vlan25ether3 in IOT keeps it out of MAC-server/MAC-winbox (MGMT-L2) and neighbor discovery (DISCOVERY).
#
# STILL REQUIRED (manual, Asus web GUI): tag VLAN 25 on the Asus port facing RB5009 ether3 AND the port
# facing AG03 ether1, or VLAN 25 frames won't cross the Asus. The Asus itself should NOT get a VLAN 25 IP.

# ==== 2026-10-26 (6): Asus ExpertWiFi EBP15 (192.168.1.50, web GUI) -- VLAN 25 path to AG03 ====
# Port map: 1 = RB5009 ether3 (trunk), 2 = AG03 ether1 (trunk), 3 = VLAN 5 access, 4-5 = IoT access.
# Before:  VLAN10 member 1-2,4-5 (tag 1-2, untag 4-5, PVID 4-5) ; no VLAN 25
# After (verified in GUI table):
#   VLAN 1   member 1-5  untagged 1-5        PVID 1     (unchanged -- switch mgmt VLAN)
#   VLAN 5   member 1-3  tagged 1, untag 2-3 PVID 2-3   (unchanged)
#   VLAN 10  member 1-2  tagged 1-2                     (ports 4-5 removed)
#   VLAN 20  member 1,5  tagged 1,5                     (unchanged -- see open item)
#   VLAN 25 "IoT" member 1-2,4-5  tagged 1-2, untagged 4-5, PVID 4-5
#   VLAN 99  member 1-2  tagged 1-2                     (unchanged)
# No separate save step exists on this model (Tools = Upgrade/Backup-Restore/Reset/Reboot); edits apply live.
# Management stayed on VLAN 1 -- the Asus has no VLAN 25 address.
#
# Open items from this step were all resolved in (7)/(8): port 5 removed from VLAN 20, ports 4-5 removed
# from VLAN 1, and end-to-end VLAN 25 confirmed (router + IoT MACs learned on AG03 ether1 in VID 25).

# ==== 2026-10-26 (7): Asus follow-up ====
# VLAN 20: was member 1,5 tagged -> now member 1-2 tagged (port 5 removed per the admin, port 2 = AG03 trunk added).
# VLAN 1 cleanup ATTEMPTED (ports 1-3 untagged w/ PVID 1 on port 1, ports 4-5 non-member) -> did not take
#   -> it DID apply; the management session dropped during the save. Verified after re-login:
#   VLAN 1 = member 1-3, untagged 1-3, PVID 1. Ports 4-5 are now members of VLAN 25 only.
# Why VLAN 1 untagged on every port is a real problem (evidence: AG03 learned the Asus mgmt MAC
#   02:00:5e:18:85:e7 on ether1 in VID 5): VLAN 1 egresses UNTAGGED on port 2 alongside untagged VLAN 5, so
#   the Asus mgmt VLAN leaks one-way into AG03's VLAN 5 (and likewise to the VLAN 5 device on port 3). On
#   ports 4-5 IoT devices receive VLAN 1 broadcasts, but their ingress lands in VLAN 25 (PVID), so they can't
#   reach 192.168.1.50 untagged.
# Proper fix (not done -- lockout risk, IP Settings page wouldn't load): move Asus management to VLAN 99
#   (give it a 192.168.99.x address), confirm reachability from mgmt, THEN disable/strip VLAN 1.
# Final Asus table (verified 12:39):
#   VLAN 1  1-3 untagged, PVID 1 | VLAN 5 tag 1, untag 2-3, PVID 2-3 | VLAN 10 tag 1-2 | VLAN 20 tag 1-2
#   VLAN 25 "IoT" tag 1-2, untag 4-5, PVID 4-5 | VLAN 99 tag 1-2
# NOTE: AG03 has no VLAN 20 bridge entry yet -- VLAN 20 frames arriving on AG03 ether1 are dropped until added.

# ==== 2026-10-26 (8): AG03 port moves (Safe Mode, committed; backup backup-pre-vlan20-port-moves.rsc) ====
/interface bridge vlan set [find vlan-ids=10] untagged=ether2
/interface bridge vlan set [find vlan-ids=25] untagged=ether3 comment="IoT25: ether1 trunk, ether3 access; CPU (bridge) intentionally NOT a member"
/interface bridge vlan add bridge=AG03_Bridge vlan-ids=20 tagged=AG03_Bridge,ether1 untagged=ether4 comment="VLAN20: ether1 trunk, ether4 untagged (PVID 20)"
/interface bridge port set [find interface=ether3] pvid=25
/interface bridge port set [find interface=ether4] pvid=20
# ether4 was untagged VLAN 10 (PVID 10) + tagged 5/99; untagged moved to VLAN 20 and PVID set to 20 so the port
# isn't untagged in two VLANs. Tagged 5/99 left as-is on ether4.
# Verified after apply: VLAN 20 host 02:00:5e:ad:40:0d learned on ether4, DCs/router learned on ether1;
# VLAN 25 router + G9 MACs learned on ether1 => VLAN 25 path RB5009 ether3 -> Asus p1/p2 -> AG03 ether1 confirmed.
# AG03 VLAN table now: 5 tag bridge,ether4 untag ether1 | 10 tag bridge,ether1 untag ether2 |
#   20 tag bridge,ether1 untag ether4 | 25 tag ether1 untag ether3 (no CPU) | 99 tag bridge,ether4,ether1 | 1 tag bridge
