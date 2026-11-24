# MikroTik CAKE / Bufferbloat Tuning Log

**Date:** 2026-07-23
**Router:** RB5009UG+S+ (arm64), RouterOS 7.23.2, identity `map`
**Managed via:** WinBox (`C:\Users\labadmin\Desktop\winbox.exe`)
**ISP:** the ISP — 940 Mbps down / 40 Mbps up (DOCSIS / cable)

---

## Goal

Waveform bufferbloat test scored **Grade A** but the **"Low Latency Gaming"** row still showed a ⚠️. Wanted to know if the CAKE ("cake cache") config could be tuned to clear that flag.

## Network topology (the key detail)

- **WAN:** `ether1` — DHCP client "Wan", bound, public IP. Upload leaves here.
- **Gaming desktop:** wired → managed switch (port on **VLAN 5**) → router **ether5** (VLAN 5 tagged).
- So the desktop's download traffic **egresses the router on ether5**, and its upload aggregates out **ether1**.

This topology is why the per-port `cake-down` queue on ether5 matters — it sits directly on the desktop's egress path.

---

## Starting (baseline) config — this turned out to be the best

**Queue types**

| Type | kind | bandwidth | rtt | diffserv | flowmode | nat | wash | ack-filter |
|------|------|-----------|-----|----------|----------|-----|------|------------|
| `cake-up` | cake | 38 M | 100ms | diffserv4 | dual-srchost | yes | no | filter |
| `cake-down` | cake | 775 M | 100ms | diffserv3 | dual-dsthost | yes | no | none |

**Where they're applied**

- `ether1` interface queue = **cake-up** → shapes **upload** (aggregate, single WAN port).
- `ether2`–`ether7` interface queues = **cake-down** → shapes **download** on LAN egress (ether5 = desktop path).
- Global queue tree **`cake-download`**: `parent=global`, `packet-mark=wan-down`, `max-limit=775M`, `queue=cake-down`, `priority=8` → shapes **aggregate download** at L3.

Result: **Grade A**, but "Low Latency Gaming" ⚠️.

---

## What we tried (and what each proved)

| # | Change | Grade | Idle | Down active | Up active | Down speed | Notes |
|---|--------|-------|------|-------------|-----------|------------|-------|
| 1 | **Baseline** (tree 775M + per-port 775M) | **A** | 17 ms | **+14 ms** | +6 ms | 748 Mbps | Best result. Both shapers doing real work. |
| 2 | Disabled global tree, per-port only | C | 16 ms | +77 ms | +8 ms | — | Per-port alone can't control download → queue forms upstream. |
| 3 | Tree only (per-port removed), 725M | B | 17 ms | +35 ms | +13 ms | 615 Mbps | Tree HTB shapes, but AQM weaker without per-port. |
| 4 | Tree `max-limit=0` + `cake-bandwidth=550M` | B | 16 ms | +43 ms | +5 ms | **792 Mbps** | **Download ran wide open** → proved `cake-bandwidth` is ignored inside a queue tree; only `max-limit` (HTB) shapes there. Effectively bypassed CAKE. |
| 5 | **Rolled back to baseline** (775M both) | **A** | 17 ms | **+14 ms** | +6 ms | 748 Mbps | Confirmed baseline is optimal. Stopped here. |

---

## Key findings / lessons for next time

1. **The "double shaping" is NOT redundant on this box — it's the best config.** The global tree + per-port `cake-down` together give the lowest download latency (+14 ms). Removing either one made it worse. Don't "simplify" this.

2. **`cake-bandwidth` is honored on an *interface* queue, but IGNORED inside a *queue tree*.** In a tree, shaping comes only from the tree's `max-limit` (HTB); CAKE runs as the leaf qdisc. Setting `max-limit=0` on the tree removes all download shaping (test #4 hit 792 Mbps at a "550M" setting). **Never set the tree `max-limit` to 0.**

3. **Upload is easy, download is hard.** Upload shapes cleanly via `cake-up` on the single WAN egress (`ether1`) — always ~+5-6 ms. Download has to be controlled at L3 (global tree) because it fans out to LAN ports / VLANs.

4. **VLAN matters.** The desktop is on VLAN 5 over ether5; the global tree (L3, `packet-mark` based) is what reliably catches its download regardless of VLAN tagging.

5. **The ⚠️ on Low Latency Gaming is a strict synthetic warning, not a fault.** At Grade A, +14 ms down / +6 ms up, 17 ms idle, low jitter — the connection is genuinely good for gaming. The Waveform test *saturates the full 940 Mbps download* to force worst-case bufferbloat; real gameplay never does that, so the +14 ms rarely appears. Turning the triangle green would require shaping download down to ~650 Mbps — trading ~100 Mbps of real speed for a few ms you'd never feel. **Not worth it.** Decision: leave at baseline.

---

## Final config (current, verified good)

- `cake-up` = **38 M** on `ether1` (upload) — unchanged, works great.
- `cake-down` = **775 M** (diffserv3, dual-dsthost, nat=yes) on `ether2`–`ether7` (per-port).
- Global tree `cake-download` = **max-limit 775 M**, packet-mark `wan-down`, parent global.
- Ping to 8.8.8.8: 0% loss, ~14 ms. Grade A restored.

*(Advisory warning "CAKE type with bandwidth setting detected…" on the tree is cosmetic — it just notes the rate is set in two spots. Harmless.)*

---

## Handy reference commands (WinBox → New Terminal)

```
# Inspect
/queue type print detail where kind=cake
/queue tree print detail
/queue interface print
/ip dhcp-client print

# Baseline values (what to restore to)
/queue type set [find name=cake-down] cake-bandwidth=775M
/queue tree set [find name=cake-download] max-limit=775M
:foreach i in={"ether2";"ether3";"ether4";"ether5";"ether6";"ether7"} \
  do={/queue interface set [find interface=$i] queue=cake-down}

# Restore upload (if ever needed) — ether1 should be cake-up
/queue interface set [find interface=ether1] queue=cake-up

# Sanity check
/ping 8.8.8.8 count=4
```

## If you ever want to experiment again (single lever)

The only meaningful knob left is the **download shaper rate**. Lower `cake-down` `cake-bandwidth` (and the tree `max-limit` to match) to buy latency headroom at the cost of throughput; raise it toward ~850–900 M to recover speed at the cost of a slightly larger latency tail. Change **both** the type bandwidth and the tree `max-limit` to the same value, and keep the per-port queues in place. Retest on Waveform after each change.
