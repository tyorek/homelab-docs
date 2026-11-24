# Runbook — Flatten R2 to a Smart Switch, Consolidate All L3 on R1

**Goal:** R1 (RB5009 "map") becomes the single edge/L3 router again — WAN, all VLANs, DHCP,
DNS, firewall, and the DMZ. R2 (hEX) becomes a pure **L2 access switch** in the living room:
it trunks the VLANs from R1 down to the entertainment-center devices and does no routing.

**Why:** The routed/OSPF + DMZ-on-R2 design created a dual-gateway, prefix-colliding tangle
(esp. IPv6: pibox pulls R1's `2b04` prefix but routes via R2, so returns dead-end). Collapsing
to one authority removes all of that.

**Written:** 2026-07-31, at the end of the session that built the current (to-be-undone) state.

---

## ✅ STATUS: COMPLETE (verified 2026-07-31)

This migration is **done**. When re-checked live against both routers, the routed/OSPF state
this runbook was written to undo had already been reversed. Confirmed on the boxes:

- **R2 (hEX, `02:00:5E:4D:A2:68`)** is already a pure L2 VLAN switch — one bridge `backbone`,
  `ether1` = tagged trunk to R1 (VLANs 5/10/99), `ether2` = pibox trunk (5+10), `ether3` = VLAN10
  access. **No OSPF, no DHCP server, no NAT, no static L3.** Only a DHCP mgmt IP (`192.168.5.10`
  on vlan5) + default route to R1 (`192.168.5.1`). Phases 1 & 2 already satisfied.
- **R1 (map, RB5009)** is the sole L3 owner — **no OSPF**, owns all bridges, WAN on ether1
  (`203.0.113.10/25`), and **DMZ already on `10.20.0.0/25` on bridge10** (the Option-A target).
- Note: live network is largely on `192.168.x` now, not the `10.20.x` this runbook assumes — the
  `10.20.x` scheme survives only for the DMZ (`10.20.0.0/25`).

### Cleanup performed on R1 this pass (Safe Mode, committed)

Leftover session cruft that still referenced R2/OSPF and buauth's dead `10.20.10.2` address:

- **Removed** filter rules `allow OSPF from R2`, `admin to R2`, `mgmt to R2`; **removed**
  address-list `r2-networks` (`10.20.1.0/29`, `10.20.2.0/30`).
- **Repointed `10.20.10.2` → `10.20.0.9`** (live buauth, confirmed by user + `ping` 3/3 from R1) in:
  address-lists `dns-auth` & `dns-dmz`; NAT `DMZ DNS redirect primary` udp/tcp and
  `LAN DNS redirect fallback` udp/tcp (added `dst-address=!10.20.0.9` loop-guard to the primaries);
  filter `clients to buauth DNS` udp/tcp.
- `dns-fallback-check` scheduler verified present and actively running.

### Still the user's to verify (host-side, off-router)

- End-to-end: internet v4 per VLAN, IPv6 `ping -6` from pibox (single gateway now), external hit to
  `nextcloud.example.com` → NPM → backend.
- NPM proxy-host backends reachable from its home; Technitium forwarders are **IPs not hostnames**;
  split-horizon A/AAAA records no longer pointing at `10.20.10.x`; flush client DNS caches.

Everything below is the **original plan, retained for reference** — most of it is already done.

---

## 0. Ground truth you must confirm before starting

Open each router's saved `.rsc` export (made this session) and skim it — it is the exact
current config and the source of truth for anything below that says "confirm":

- R1: `pre-flatten-20260731.rsc` (on R1 flash) — 30.7 KiB
- R2: `pre-flatten-20260731.rsc` (on R2 flash) — 9.4 KiB
- Full binary restore points: `pre-flatten-20260731.backup` on each box.

**DO THIS FIRST: download all four files off the routers to your PC** (WinBox → Files → drag).
They live only on flash; a reset mid-rebuild erases them and you're back to no restore point.

### Current addressing (as of this session)

| Thing | Now (on R2) | Old / target (on R1) |
|---|---|---|
| DMZ subnet | vlan10 `10.20.10.0/28` on R2 | `10.20.0.0/25` on R1 `bridge10` |
| NAS access | vlan5 `10.20.5.0/29` on R2 | (fold into an R1 VLAN — your call) |
| buauth (Technitium filter) | `10.20.10.2` | `10.20.0.9` |
| bunode1 (Unbound) | `10.20.10.4` | `10.20.0.10` |
| bunode2 (Unbound) | `10.20.10.3` | `10.20.0.11` |
| NPM (reverse proxy, on pibox) | `10.20.10.6` | `10.20.0.2` (per R1's port-forward) |
| caddy (internal proxy) | `10.20.0.7` on R1 bridge10 (never moved) | unchanged |
| pibox NAS | eth0 `10.20.5.6` (vlan5) + br1 `10.20.10.6` (vlan10) | re-home per below |
| R1 WAN | ether1, the ISP: dynamic v4 `203.0.113.x` + PD `2001:db8:4a00:2b00::/56` (pool `wan-pd`) | unchanged |
| R1↔R2 link | R1 ether3 `10.20.2.1/30` ↔ R2 ether1 `10.20.2.2/30` (routed) | becomes an **802.1Q trunk** |

### Addressing decision — pick ONE before you start

- **Option A — full revert (matches "how it was before"):** DMZ back to `10.20.0.0/25` on R1
  `bridge10`; re-address buauth/bunodes/NPM to `10.20.0.9/.10/.11/.2`. Most host work, cleanest
  match to your docs (`enforcing-dns-egress-control-mikrotik.md`, `dmz-resolver-postmortem.md`).
- **Option B — R1 adopts current subnets (least host work):** R1 becomes the gateway/DHCP/DNS
  for `10.20.10.0/28` (DMZ) and `10.20.5.0/29` (NAS) as-is; hosts keep their IPs and only change
  **default gateway** to R1. Functionally identical DMZ, far less re-addressing.

**Recommendation:** if you don't specifically need the `10.20.0.x` numbering back, do **Option B** —
it's the same "R1 owns everything" result with a fraction of the host churn. The rest of this
runbook is written Option-B-first with Option-A notes where they differ.

---

## 1. Rollback (know it cold before touching anything)

If anything goes sideways: `/system/backup/load name=pre-flatten-20260731` on the affected box,
it reboots, you're back to the current (v4-working) state. That's why step 0 downloads them.

Work in **safe mode** (Ctrl+X in terminal, or the toolbar toggle) for every destructive change so
a session drop auto-reverts.

---

## 2. Phase 1 — R2 → dumb VLAN-aware switch

R2 should end up doing **only** L2: bridge with VLAN filtering, trunk to R1, access ports for the
living-room gear, one management IP, and a minimal input firewall. Everything else is stripped.

### 2a. What to REMOVE on R2 (all added this session)

```
/routing/ospf/interface-template/remove [find]
/routing/ospf/area/remove [find]
/routing/ospf/instance/remove [find]          # kills OSPFv2 + OSPFv3
/ip/dhcp-server/remove [find]                 # dhcp1 (vlan5), dhcp2 (vlan10)
/ip/dhcp-server/network/remove [find]
/ip/pool/remove [find]
/ip/firewall/filter/remove [find]             # DNS lockdown + IoT isolation + input fw
/ip/firewall/nat/remove [find]                # masquerade, DNS redirect, hairpin
/ip/firewall/mangle/remove [find]
/ip/firewall/address-list/remove [find]       # dmz-srv, internal, dns, dns-auth
/ipv6/firewall/filter/remove [find]
/ipv6/address/remove [find where !link-local] # the ULA :101/:105/:110
/ipv6/nd/remove [find where !default]
/ip/dns/set allow-remote-requests=no servers="" # stop being a resolver
/interface/list/member/remove [find]
/interface/list/remove [find where name!="WAN" and name!="LAN"]  # dns-clients, etc.
```
Then remove R2's routed/L3 IPs: `/ip/address/remove [find]` — but **KEEP or re-add one mgmt IP**
(see 2c) or you'll lock yourself out. Do the mgmt IP first, then clear the rest.

### 2b. VLAN switch config on R2

Confirm your VLAN IDs from the `.rsc` (this session had **VLAN 5**, **VLAN 10**, mgmt **VLAN 99**).
Physical: **R2 ether1 = uplink/trunk to R1 (R1 ether3)**; ether2–ether5 = living-room device ports.

```
# one VLAN-aware bridge
/interface/bridge/set [find name=bridge1] vlan-filtering=no   # set yes at the END, after ports/vlans
# (or make a fresh bridge; reuse bridge1)

# put all ports on the bridge
/interface/bridge/port/remove [find]
/interface/bridge/port/add bridge=bridge1 interface=ether1                 # trunk uplink to R1
/interface/bridge/port/add bridge=bridge1 interface=ether2 pvid=10         # e.g. IoT access port
/interface/bridge/port/add bridge=bridge1 interface=ether3 pvid=10
/interface/bridge/port/add bridge=bridge1 interface=ether4 pvid=5          # e.g. NAS/trusted port
/interface/bridge/port/add bridge=bridge1 interface=ether5 pvid=5
#   --> set each device port's pvid to the VLAN that device belongs to.
#   --> pibox is on BOTH vlan5 and vlan10: give its port(s) a trunk (tagged 5+10) or use two ports.

# VLAN table: everything tagged on the uplink; untagged (access) on the device ports
/interface/bridge/vlan/add bridge=bridge1 vlan-ids=5  tagged=ether1  untagged=ether4,ether5
/interface/bridge/vlan/add bridge=bridge1 vlan-ids=10 tagged=ether1  untagged=ether2,ether3
/interface/bridge/vlan/add bridge=bridge1 vlan-ids=99 tagged=ether1                   # mgmt, tagged to R1
#   (add any other VLANs R1 trunks down: 15/20/25/30 if living-room devices need them)

# turn on filtering LAST
/interface/bridge/set [find name=bridge1] vlan-filtering=yes
```
> pibox needs vlan5 **and** vlan10. Simplest: dedicate one R2 port to pibox as a **trunk**
> (`tagged=ether1,etherX` for both 5 and 10, no untagged/pvid on that port) and let pibox tag
> internally (it already runs `eth0`=vlan5 / `br1`=vlan10). Otherwise give pibox two access ports.

### 2c. R2 management IP

Keep R2 reachable on the mgmt VLAN (99) — R1 will be its gateway/DHCP:
```
/interface/vlan/add name=mgmt99 vlan-id=99 interface=bridge1
/ip/address/add address=<mgmt-ip>/24 interface=mgmt99   # or let R1's DHCP give it one
/ip/route/add gateway=<R1-mgmt-ip>                       # default via R1
```
Minimal input firewall on R2 (protect the switch mgmt): accept established/related + ICMP +
WinBox/SSH from your admin source on VLAN 99, drop the rest. (Or leave it open on mgmt only.)

**Result:** R2 forwards frames and nothing else. The R1↔R2 cable (R1 ether3 ↔ R2 ether1) is now a
tagged trunk carrying VLANs 5/10/99 (+ any others).

---

## 3. Phase 2 — R1 → sole L3 owner (reverse this session's changes + restore DMZ)

### 3a. Undo the routing/link changes I made on R1

```
/routing/ospf/interface-template/remove [find]
/routing/ospf/area/remove [find]
/routing/ospf/instance/remove [find]           # removes ospf1 (v2) and ospf-v3
/ip/address/remove [find interface=ether3]      # the 10.20.2.1/30 routed link IP
```
Convert R1 **ether3** from a routed port into the **trunk to R2** — add it to the VLAN-aware side
of R1 so VLANs 5/10/99 (and whatever else R2 needs) are **tagged on ether3**. R1 already trunks
VLANs on sfp-sfpplus1/ether5; mirror that tagging onto ether3 (see R1's `.rsc` for the exact
bridge/vlan syntax it uses — it's per-VLAN bridges with vlanXetherY sub-interfaces).

### 3b. Undo the R2-specific firewall/NAT I added on R1

```
/ip/firewall/filter/remove [find comment~"to R2"]              # admin to R2, mgmt to R2
/ip/firewall/filter/remove [find comment~"clients to buauth"]  # the buauth forward accepts
/ip/firewall/filter/remove [find comment~"OSPF from R2"]        # v4 input OSPF accept
/ipv6/firewall/filter/remove [find comment~"OSPFv3 from R2"]    # v6 input OSPFv3 accept
/ip/firewall/address-list/remove [find list=r2-networks]
/interface/list/member/remove [find list=LAN interface=ether3] # unless ether3 stays "LAN"; your call
```

### 3c. Restore the DMZ + DNS enforcement on R1

Reverse the "repoint to buauth" I did (buauth is going back onto R1's DMZ):

**Option A (revert to 10.20.0.x):**
```
/ip/firewall/address-list/set [find list=dns-auth address=10.20.10.2] address=10.20.0.9
/ip/firewall/address-list/set [find list=dns-dmz  address=10.20.10.2] address=10.20.0.9
/ip/firewall/address-list/add list=dns address=10.20.0.9
/ip/firewall/address-list/add list=dns address=10.20.0.10
/ip/firewall/address-list/add list=dns address=10.20.0.11
/ip/firewall/nat/set [find chain=dstnat to-addresses=10.20.10.2] to-addresses=10.20.0.9 dst-address=!10.20.0.9
/ip/firewall/nat/set [find comment~"NPM 80/443"] to-addresses=10.20.0.2      # NPM back on DMZ
/ip/dhcp-server/network/set [find address=10.20.0.0/25] dns-server=10.20.0.9
/system/script/edit dns-fallback-check source    # change DMZ probe server= back to 10.20.0.9
/system/scheduler/enable [find name~"dns-fallback"]   # re-enable the health-check
```
**Option B (keep 10.20.10.x, R1 owns it):** leave the DNS lists/redirects pointed at
`10.20.10.2` (buauth stays `.10.2`), but make **R1** the gateway/DHCP for `10.20.10.0/28` and
`10.20.5.0/29` — add those subnets/DHCP servers to R1 on the trunked VLANs, and **delete** the
`bridge10` `10.20.0.0/25` DMZ if you're fully moving to `10.20.10.x`. (Don't run both.)

Confirm R1 still has: WAN masquerade, the port-forward chain, the DNS-egress drops/redirects,
DHCP for every VLAN, and the CAKE/QoS you had — none of that was touched this session, but verify
against `rb5009-cake-qos-config.md`.

---

## 4. Phase 3 — Host re-homing (this is the part only you can do)

The DMZ boxes are physically on R2's switch ports; their L3 now lives on R1. On each:

- **buauth / bunode1 / bunode2 / NPM(pibox):**
  - Set **default gateway → R1's DMZ IP** (Option A: `10.20.0.1`; Option B: `10.20.10.1`).
  - Option A only: change their **IP** to `10.20.0.9 / .10 / .11 / .2`.
  - Confirm they're on the correct VLAN on R2's switch port (buauth/bunodes/NPM = vlan10/DMZ).
- **pibox:** eth0 (vlan5/NAS) and br1 (vlan10/DMZ) gateways → R1. IPv6: it will now get GUA + a
  **working** default from R1 (R1 owns the prefix), so the `2b04` collision disappears on its own.
- **Technitium (buauth) forwarders:** verify they're **IPs, not hostnames** (per your postmortem) —
  bunodes + ns1/ns2 GCP. Update if any point at old `10.20.10.x`.
- **NPM:** its proxy-host backends and the public 80/443 forward now resolve on R1's side; confirm
  each backend IP is reachable from NPM's new home. Re-run `zammad-deployment.md` sanity if needed.
- **DNS records (Technitium/split-horizon):** update any A/AAAA that point at `10.20.10.x`
  (e.g. `nextcloud.example.com`, `zammad.home.arpa`) to the new/kept DMZ IPs, then
  **flush client caches** — remember the stale-cache incident.

---

## 5. Phase 4 — Verify

1. R2 is L2 only: `/ip/route/print` on R2 shows just its mgmt default; no OSPF, no DHCP server.
2. From a device on each VLAN: gets an IP from **R1's** DHCP, gateway = R1, reaches the internet (v4).
3. **IPv6:** `ping -6 google.com` from pibox works — single gateway (R1), no prefix collision.
4. DMZ services: DNS resolves through buauth; `dig`/`curl` from a DMZ host works.
5. Public: hit a public hostname (e.g. `nextcloud.example.com`) **from outside** → NPM → backend.
6. DNS-egress lockdown still enforces (clients → buauth only) — now all on R1.
7. Firewall: nothing leaks between VLANs you didn't intend (`ISO4`/`DROP4` log-prefixes on R1).

---

## 6. What this session changed (so you know the full blast radius to undo)

On **R1**: added OSPFv2 (`ospf1`) + OSPFv3 (`ospf-v3`) instances/areas/templates; gave ether3
`10.20.2.1/30`; added ether3 to interface-list `LAN`; input accepts for OSPF/OSPFv3 on ether3;
forward accepts `admin to R2` / `mgmt to R2` / `clients to buauth DNS`; address-list `r2-networks`;
repointed the DMZ resolver `10.20.0.9 → 10.20.10.2` across `dns-auth`/`dns-dmz`/dstnat redirects/
`bridge10` DHCP; pruned `10.20.0.x` from the `dns` list; changed the `public: NPM 80/443` forward
`10.20.0.2 → 10.20.10.6`; **disabled the `dns-fallback-check` scheduler**; set R1's LAN v2 template
passive (via GUI — leave it, it's harmless). *The `dns-fallback-check` script's DMZ probe was left
pointing at `10.20.0.9` and never got auto-fixed — that's fine for Option A.*

On **R2** (all to be wiped in Phase 1): OSPFv2+OSPFv3; DHCP for vlan5/vlan10; DNS lockdown
(redirect + hairpin + drops); IoT isolation (dmz-srv/internal lists, vlan10→internal drop);
input+forward IPv6 firewall; ULA `fd12:3456:789a:101/105/110` + RA; masquerade.

---

## 7. Notes / gotchas

- **Do R2 first, then R1.** While R2 still routes, R1's reversion won't cut anything; once R2 is a
  switch, R1's trunk on ether3 carries the VLANs.
- **The single cable is the only R1↔R2 link** — it must be a tagged trunk after this. Native/untagged
  on it can be your mgmt VLAN or left unused; don't leave a routed /30 on it.
- **IPv6 "just works" after consolidation:** the whole v6 saga was the dual-gateway/prefix collision.
  One gateway (R1, owner of the `wan-pd` prefix) = symmetric routing, no more dead-ends.
- Keep `use-ip-firewall` OFF on R2's bridge (you don't need L3 filtering on a dumb switch — R1 does it).
- If you'd rather rebuild R2 from a clean slate: `/system/reset-configuration no-defaults=yes
  skip-backup=no` then paste the Phase-1 switch config. (skip-backup=no writes `auto-before-reset.backup`.)
