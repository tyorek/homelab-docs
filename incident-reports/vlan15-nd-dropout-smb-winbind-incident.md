# Incident Write-Up: SMB/winbind Outage — Dropped `nd` Advertisement → Lost IPv6 Default Route → Unreachable AD Forwarders

**Presenting host:** `nas` (domain-joined to `home.arpa` via winbind; SMB shares)
**Actual fault host:** `primenodetls` (192.168.15.9) — LAN authoritative resolver (Technitium), **unprivileged LXC** on Proxmox, VLAN 15
**Fault location:** `R1` (RB5009) — `/ipv6 nd` was not advertising on `bridge15`
**Domain:** `home.arpa` (NetBIOS `HOMELAB`); DCs `dc01` 192.168.20.7 / `dc02` 192.168.20.6 on VLAN 20 (GUA prefix `…2b02`)
**Date:** 2026-08-21
**Severity:** Service outage — SMB shares unavailable to clients via winbind
**Trigger:** Copper→fiber SFP+ swap (same cage) on the Proxmox uplink `enp5s0`

---

## Summary

Replacing a copper 10G transceiver with fiber on the Proxmox uplink appeared to break SMB
access to a winbind-joined NAS. The optic was a red herring. The real fault was a **missing
`/ipv6 nd` advertisement on `bridge15`** (VLAN 15): the RB5009 was sending no Router
Advertisements on that VLAN, so `primenodetls` had **no IPv6 default route** and could not
reach anything off its own subnet over IPv6 — including the domain controllers on VLAN 20.

Technitium's `home.arpa` conditional forwarder carried six forwarders — four IPv6
(dc01/dc02 GUA + ULA) and two IPv4. With no v6 route, the four v6 forwarders returned an
instant `NetworkUnreachable` socket error, and concurrent forwarding surfaced that error as
**SERVFAIL for the entire zone**, even though the two IPv4 forwarders (192.168.20.6/.7) were
perfectly reachable. AD name resolution died; winbind/SMB followed.

The condition almost certainly predated the optic swap by ~three weeks. The `nd` entry was
most likely dropped during the **R2→R1 flatten (2026-07-31)**; the IPv6 firewall parity scan
the next day audited `filter`/`nat`/`raw` but not `nd`/RA, so it could not have caught it.
The break stayed invisible because the resilience layers absorbed it (see "Why it stayed
masked"). The transceiver flap merely expired the last stale route and forced a fresh
resolution that finally exposed the foundation.

---

## Impact

- SMB shares on the winbind-joined `nas` unreachable — clients failed all DNS-dependent auth.
- `home.arpa` resolution returned SERVFAIL from `primenodetls`; every other zone
  resolved normally.
- No firewall drops, no service crash, no logged error on the router — a silent foundation
  fault behind healthy-looking automation.

---

## Root Cause Analysis

Two independent faults, both of which had to be cleared:

### Cause 1 (primary) — `bridge15` missing from `/ipv6 nd`
- The RB5009 advertised RAs on other VLANs but **not** on `bridge15`. No RA → no advertised
  router lifetime → no IPv6 default route on VLAN 15 hosts.
- `primenodetls` could SLAAC its on-link addresses but had **no gateway**:
  ```
  2001:db8:4a00:2b05::/64 dev eth0 proto ra …      # on-link prefix, present
  fd12:3456:789a:15::/64   dev eth0 proto ra …      # on-link ULA, present
  fe80::/64                dev eth0 proto kernel …   # link-local
  # (no default route)
  ```
- Effect: any off-subnet IPv6 (VLAN 20 DCs, cloud resolvers) was `NetworkUnreachable`.

### Cause 2 (latent second blocker) — forwarding on + `accept_ra=1`
- `primenodetls` had IPv6 forwarding enabled with `accept_ra=1`. A forwarding host ignores
  RA-provided default routes unless `accept_ra=2`. So even once RAs resumed, the default
  route would not have installed until this was corrected — a second bug that would have
  masked the fix for the first.

### Why the AD zone specifically failed
- Technitium's `home.arpa` conditional forwarder had 6 FWD records: dc01/dc02 **GUA**
  (`…2b02…`), dc01/dc02 **ULA** (`fd9a…20…`), and dc01/dc02 **v4** (192.168.20.7/.6).
- All six queried concurrently. The four v6 targets returned an **instant** `NetworkUnreachable`
  (no route), which beat the working v4 answers, and Technitium returned SERVFAIL for the zone.
- `EDE 23 (Network Error): NetworkUnreachable` + `EDE 13 (Cached Error)` — the failure was
  then negatively cached and replayed until flushed.

---

## Why it stayed masked (the real lesson)

Off-subnet IPv6 from VLAN 15 was broken for ~3 weeks, yet nothing looked wrong, because every
resilience layer quietly absorbed it:

- **Per-family health-check daemon.** The Technitium forwarder daemon "makes an unreachable v6
  address a non-event" — it silently per-family-drops dead upstreams. Dead cloud v6 resolvers
  were dropped without a peep; general DNS never hiccuped.
- **On-link upstreams need no gateway.** Recursion via the on-link unbounds (`.15.10/.15.11`,
  same subnet) worked over v4 and on-link v6 regardless of the missing default route.
- **The one unmasked dependency.** The AD conditional forwarder is a static Technitium zone —
  *not* managed by the per-family daemon — so it was the only off-subnet v6 dependency without
  masking. It was the sole canary, and even it coasted on cache until the optic flap forced a
  fresh resolution.

Self-healing that does not **report what it healed** is indistinguishable from nothing being
wrong. The automation was good enough to hide its own broken foundation.

---

## Diagnostic Path (and the red herrings it burned through)

1. **winbind trust** — `wbinfo -t` **succeeded** (cached secure channel). Sent us away from DNS.
2. **Link/MTU** — interface name and MAC unchanged (same NIC, swapped optic); jumbo frames
   passed — but only on a **same-subnet** ping, which never crossed the router. Non-diagnostic.
3. **"No IPs changed"** — true for IPv4 (static); the **IPv6 default route is dynamic** and was
   the thing that changed. This is where the investigation kept stalling.
4. **Resolver reachability** — `dig` proved the query reached Technitium (0 ms) but came back
   `SERVFAIL / NetworkUnreachable`: the fault was **upstream of the resolver**, not the client.
5. **Same-namespace proof** — the resolver (`dotnet` pid) shared the LXC's routing table; shell
   reached `192.168.20.7` over **v4** fine but got `NetworkUnreachable` over **v6** (`dig`/`nc`,
   not `ping` — unprivileged LXC lacks `CAP_NET_RAW`). Technitium was choosing the dead v6 leg.
6. **Config inspection** — the zone's six forwarders, four of them v6, made the mechanism plain.
7. **Route inspection** — `ip -6 route` showed on-link prefixes but **no default route** →
   pointed at RA/`nd`. Found `bridge15` absent from `/ipv6 nd` on R1.

---

## Resolution

### Fix 1 — Advertise on `bridge15` (router side, primary)
Add `bridge15` to `/ipv6 nd` on R1, matching the other VLANs' entry (non-zero router lifetime,
policy-correct `advertise-dns`/`dns=` per the egress-control design).

### Fix 2 — Accept the RA default route (host side)
On `primenodetls`, `net.ipv6.conf.eth0.accept_ra=2` (forwarding host), persisted in
`/etc/sysctl.d/99-ipv6-accept-ra.conf`. The interface then solicited an RA and installed:
```
default nhid … via fe80::7a9a:18ff:febb:c0d3 dev eth0 proto ra metric 1024 expires 1616sec
```

### Verify — walk it back up the stack
```
# v6 off-subnet now works:
dig @2001:db8:4a00:2b02:10e4:7831:6112:392f dc01.home.arpa   # NOERROR → 192.168.20.7
# resolver serves the zone again (after cache flush):
dig fresh$RANDOM.home.arpa @192.168.15.9                       # NXDOMAIN, not SERVFAIL
# winbind/idmap healthy on the NAS:
sudo systemctl restart winbind smbd
wbinfo -t && getent passwd 'HOMELAB\labadmin'                   # trust OK + uid 11104
```
Shares restored.

### Interim bandaid (applied, then superseded)
Before the root cause was found, the four v6 forwarders were disabled in Technitium to stop the
SERVFAIL. After Fix 1/2, the **ULA** v6 forwarders (dc01/dc02 `fd9a…20…`) were re-enabled; the
**GUA** forwarders (`…2b02…`) were left disabled — they sit inside the ISP-delegated prefix and
are the re-delegation risk the parity scan already flagged. v4 + stable ULA is the resilient set.

---

## Causal Chain

```
R2→R1 flatten (2026-07-31) drops bridge15 from /ipv6 nd
        │
        ▼
VLAN 15 receives no RAs ──► primenodetls has no IPv6 default route
        │                              │
        │                              ▼
        │                   off-subnet v6 unreachable (VLAN 20 DCs, cloud resolvers)
        │                              │
        │            ┌─────────────────┼───────────────────────────┐
        │            ▼                 ▼                            ▼
        │   cloud v6 upstreams   on-link unbounds            AD conditional fwd
        │   dropped by daemon    unaffected (on-link)        (unmanaged) → v6 FWDs
        │   (MASKED)             (MASKED)                     NetworkUnreachable
        │                                                            │
        ▼                                                            ▼
[3 weeks: everything looks fine]                    concurrent-forward returns SERVFAIL
        │                                                            │
        ▼                                                            ▼
optic swap flaps uplink ──► last stale route expires ──► fresh resolution forced
                                                                     │
                                                                     ▼
                                              home.arpa SERVFAIL → winbind/SMB down
                                                                     │
                      [Fix 1: add bridge15 to nd] + [Fix 2: accept_ra=2]
                                                                     ▼
                                              v6 default route restored → shares back
```

`wbinfo -t` passed on cached connectivity the entire time — the red herring that kept the
diagnosis pointed away from DNS.

---

## Lessons / Hardening

- **Resilience that doesn't report is a mask.** Per-family failover, caches, and on-link
  fallbacks each hid a foundational v6 break for three weeks. Anything that silently "heals"
  a fault must log that it did — turn the mask into a signal.
- **`nd`/RA is not covered by a firewall parity audit.** The parity scan (2026-08-01) checked
  `filter`/`nat`/`raw` but not `nd`; the regression it missed was one line away. Audit RA
  advertisement as its own invariant.
- **Config flattens drop things silently.** The R2→R1 consolidation removed the `bridge15`
  `nd` entry with no error. Diff `/ipv6 nd` against the full bridge list after any flatten.
- **A forwarding host needs `accept_ra=2`.** `accept_ra=1` + forwarding gives on-link v6 but no
  RA default route — a second, independent blocker that masks the first fix. (Same family of bug
  as the bunode `accept_ra=0` incident.)
- **Concurrent forwarders fail to their fastest error.** An instant `NetworkUnreachable` from a
  dead v6 leg beats a working v4 answer and SERVFAILs the whole zone. Don't leave unreachable
  forwarders configured; per-family-drop or remove them.
- **GUA forwarders inside a delegated prefix are fragile.** Prefer v4 + **ULA** for internal
  infrastructure targets; keep GUA off for anything that must survive a re-delegation.
- **`wbinfo -t` passing ≠ DNS healthy.** It verifies a cached secure channel, not live name
  resolution. Check fresh resolution (`getent`, an uncached `dig`) before trusting the auth path.
- **In an unprivileged LXC, diagnose with `dig`/`nc`, not `ping`** (`CAP_NET_RAW` absent), and
  remember route fixes may belong at the Proxmox host, not inside the container.

## Open Items (recommended monitors)

- **Alert on a missing IPv6 default route** on each resolver / domain-joined host (carried over
  from the pibox write-up — now demonstrated necessary).
- **Config-drift check on R1**: every bridge that should advertise is present in `/ipv6 nd` with
  a non-zero router lifetime.
- **Make the Technitium health-check daemon log every family it drops** — the silent per-family
  drop is exactly what masked this.
- Persist `accept_ra=2` (done) and confirm it survives an LXC reboot.

*Written up 2026-08-21 from a live troubleshooting session.*
