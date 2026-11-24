# VLAN5 Jumbo-Frame MTU Black-Hole — Diagnosis & Resolution

| | |
|---|---|
| **Date** | 2026-08-27 |
| **System** | RB5009 (RouterOS 7), `bridge5` / VLAN5, 10G LAN |
| **Symptom class** | Intermittent bulk-transfer stalls; TV streaming black-screen; random in-game "insta-death" (The Division 2); "connected but no data" |
| **Root cause** | Mixed-MTU L2 segment with the bridge L2MTU pinned low by one member port |
| **Status** | Resolved and confirmed by symptom disappearance; load-test baseline still recommended |

---

## Summary

`bridge5` carried three ports on VLAN5: `ether3`, `ether5`, and `sfp-sfpplus1`. Jumbo frames (MTU 9000 / L2MTU 9214) were enabled on the PC (`ether5`) and the Proxmox host (`sfp-sfpplus1`), and on the NICs of both end hosts. `ether3` — feeding a hEX S whose switch chip caps at 2500 MTU — was left at the 1500 default.

Because a bridge derives its L2MTU from the **minimum** L2MTU of all member ports, the low `ether3` value pinned `bridge5`'s L2MTU low for the entire bridge. That silently black-holed every oversized frame crossing `bridge5` — not just to/from `ether3`, but between the two jumbo hosts as well. Raising L2MTU on the members lifted the bridge L2MTU; explicitly setting the bridge IP MTU lifted `actual-mtu` to 9014. The fault cleared.

---

## Key mechanism (the part that's easy to get wrong)

**Bridges do not fragment.** Fragmentation is strictly an L3/IP operation. When a frame exceeds the egress port's L2MTU, it is dropped cleanly — not fragmented, not error-counted. Its CRC is valid; it's simply too big. That is why:

- **No FCS/CRC errors appear.** Counters stay pristine while traffic dies by size. Clean counters do *not* exonerate MTU — they are exactly what an MTU black-hole looks like.
- **Small traffic always works.** ARP, broadcasts, TCP handshakes, app UI, DNS — all small, all cross fine. This masks the problem and makes it read as "intermittent" when it is actually deterministic on frame size.
- **Same-subnet peers get no warning.** Host-to-host traffic on one VLAN never touches a router, so there's no device in the path to emit an ICMP "fragmentation needed" / ICMPv6 Packet-Too-Big. The sender just retransmits large frames into the void and the flow stalls.

### Two affected paths, governed by different values

**PC ↔ Proxmox (same subnet, pure L2 switching).** Governed by **L2MTU**, not the bridge's IP `actual-mtu`. While `ether3` pinned the bridge L2MTU low, jumbo frames between the two jumbo hosts were dropped bridge-wide. This is the path that produced the streaming black-screen and bulk-transfer hangs.

**Host ↔ RB5009's own IP (router-terminated / inter-VLAN).** Governed by the **bridge IP MTU** (`actual-mtu`). With that at 1500, MSS asymmetry bit: Proxmox advertised ~8960 MSS, the router ~1460. The router, honoring the host's large MSS, tried to send large segments out a 1500-MTU interface → IPv4 fragmentation (ugly, fails under DF or filtered PTB) or IPv6 black-holing if the PTB path is broken.

Both concrete symptoms below live on **path #1** — the same-subnet L2 switch path — not on any internet-facing connection.

### Observed symptoms and how they map to the fault

**TV streaming black-screen (bedroom).** Clean fingerprint of the L2 black-hole: handshake, app UI, thumbnails, and the loading spinner are all small (work), while the actual video segments are large TCP payloads filled to the advertised MSS (dropped). Result: connected, authenticated, UI responsive — but black screen when playback starts.

**The Division 2 — random "insta-death" mid-fight.** This is *not* the game's connection to the Ubisoft servers. That path was never the affected one: the game's real-time traffic is UDP and tiny (well under any MTU ceiling), and any TCP it opens to the internet gets its MSS clamped by the remote server's ~1460 advertisement, so those segments stay ≤1500 and cross the 1500 path fine. The internet gaming traffic was inert to this fault.

The affected connection is the **storage path**, and it is pure path #1. The game's files live on a VHDX on an SMB share on the NAS VM running on Proxmox. So every asset the game reads traverses:

```
PC (ether5)  →  SMB / TCP 445  →  NAS VM (sfp-sfpplus1)   — all across bridge5, same subnet
```

SMB is bulk transfer. With jumbo negotiated end-to-end, its data segments fill to ~8960 MSS and ride ~9000-byte frames — exactly the frames `bridge5` was silently dropping. Small SMB ops (metadata, directory enumeration, small/cached reads) stayed under the ceiling and worked, which is why the game launched and navigated menus normally. Large sequential reads — streaming textures, geometry, loading a new zone during combat — hit the black-hole.

Failure sequence:

1. Game issues a synchronous asset read mid-fight → large SMB data segments sent PC→NAS VM.
2. Those ~9000-byte frames are dropped cleanly at the bridge (oversized, valid CRC, no error counter, no ICMP).
3. TCP has no PMTUD signal on a same-subnet L2 black-hole — nothing emits "too big" — so it retransmits the same large segment, loses it again, and backs off exponentially.
4. The read hangs for hundreds of ms to seconds; the client thread blocked on that I/O freezes.
5. The server keeps running — enemies keep shooting the frozen character. When the client unblocks, the death has already happened → "random insta-death out of nowhere."

It presents as a server desync but the root is local storage I/O starving. It correlated with action rather than idle standing-around because idle = no new asset streaming = no large SMB reads = nothing to drop.

---

## RouterOS behavior notes

- **Bridge L2MTU is read-only** and computed as the minimum L2MTU across members. You cannot set it on the bridge directly — raise it on the member interfaces and the bridge follows.
- **Bridge MTU (L3/IP) is settable**, but only up to the current bridge L2MTU. If it won't accept a large value, a member's L2MTU is still capping it.
- **Raising L2MTU does not pull `actual-mtu` up.** You must set the IP MTU explicitly; `auto` resolves to 1500 regardless of available L2MTU headroom.

### Commands used

```
# raise L2MTU on members (per interface, not on the bridge)
/interface ethernet set ether5 l2mtu=9214
/interface ethernet set sfp-sfpplus1 l2mtu=9214
/interface ethernet set ether3 l2mtu=9214

# then lift the bridge IP MTU into the new headroom
/interface bridge set bridge5 mtu=9000

# verify
/interface bridge print detail          ;# check actual-mtu and l2mtu
```

**Result:** `bridge5` `l2mtu` rose, and once member IP MTUs were consistent, `actual-mtu` came up to 9014.

---

## Confirmation method

Size-dependent DF-ping isolates MTU as the single variable — no counter will ever show this fault, so ping is the definitive test:

```
# from Proxmox, same destination, small vs large
ping -M do -s 1472 <pc-ip> -c 3     # small — should pass
ping -M do -s 8972 <pc-ip> -c 3     # large (9000 - 28 overhead) — failed before, passes after
```

From RouterOS:

```
/ping <host-ip> size=8972 do-not-fragment count=5
```

**Small passes + large fails = MTU black-hole by definition. Both pass = resolved.**

To confirm the exact path the game depends on, exercise a large sequential SMB read off the share (or `iperf3` PC↔NAS-VM) and confirm it sustains full 10G with clean member counters. Before the fix that transfer would stall hard; running flat-out now proves the same I/O path the game streams assets over is healthy.

---

## Remaining risk — the `ether3` landmine (downstream, still latent)

The cap is **not** on the RB5009 side of `ether3` — that port was raised to L2MTU 9214 along with the other members, which is what let `bridge5` come up to 9014. The remaining ceiling is strictly **downstream, on the hEX S switch chip**, which caps at 2500 MTU. Everything in that segment is reachable right now, and expected to stay that way, because ordinary traffic to those hosts (ARP, broadcasts, handshakes, normal app data) stays under 2500. The latent failure is narrow: the first time a jumbo host sends a large unicast frame — filled past 2500 — straight at a host that sits behind the hEX S, that frame will be dropped. It would reproduce the exact black-screen failure, but only for that one path, so it would look like a brand-new mystery rather than a return of this one.

Mixed MTU on a single L2 broadcast domain works right up until it doesn't. Normally the options would be, cleanest first:

1. **Keep genuinely-jumbo hosts off the shared VLAN5 broadcast domain** (separate them so the jumbo path never shares an L2 segment with the 2500-capped gear), or
2. **Hold the entire VLAN to 2500** so every member agrees on a common MTU.

As a general rule: do not leave a segment where different members disagree on MTU with no L3 device between them to mediate.

**Resolution here (decided 2026-08-27):** neither of the above is being implemented. The hEX S — the sole source of the 2500 cap — is being pulled out entirely in a planned home-network upgrade the next day (2026-08-28). Once it's gone, no member of VLAN5 caps below jumbo and the mixed-MTU condition ends by removal, not reconfiguration. The landmine stays latent until then; the only way to trip it in the interim is a large unicast (>2500) aimed at a host behind the hEX S, which normal traffic doesn't produce.

---

## PHY theory — closed

The parallel "flaky 10GBASE-T / thermal" theory on the Proxmox link is separable from MTU, and the evidence separated it: 5 days uptime with zero FCS/CRC errors, no RX drops, no link flaps. A marginal PHY or heat-stressed transceiver would show climbing error counters over that window. Physical layer is clean.

**Caveat:** uptime ≠ sustained-jumbo-load clean. If the fault only ever surfaced under bulk transfer, idle days didn't exercise it. Before fully closing, run real load across the 10G path (`iperf3` or a large PC↔Proxmox transfer) and watch member RX error/drop counters during it. Clean counters under jumbo load is what closes both theories at once.

---

## Follow-ups

- [ ] Capture the pre-reboot error-counter baseline while everything is healthy — gives a known-good reference so future counter climb can be told apart from another MTU issue instantly.
- [ ] Run the `iperf3` / bulk-transfer jumbo-load test and confirm counters stay clean under load.
- [x] ~~Decide and implement the `ether3` mixed-MTU resolution (separate jumbo hosts, or cap VLAN5 at 2500) before it bites.~~ **Resolved by removal:** the hEX S is being pulled out in the 2026-08-28 network upgrade, which eliminates the 2500 cap entirely.
- [ ] After the 2026-08-28 upgrade, confirm no jumbo-capped device remains on VLAN5 and re-run the large DF-ping across the reworked segment to verify end-to-end 9000 MTU.
