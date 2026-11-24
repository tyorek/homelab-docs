# RB5009 — CAKE / Bufferbloat Configuration

**Date:** 2026-07-20
**Device:** RB5009UG+S+ (`RouterOS 7.23.2`, ARM64, 4 cores)
**Line:** 940/40 provisioned · ~881/40 achievable (Ookla)

---

## Result

| | Before | After |
|---|---|---|
| Bufferbloat grade | C | **A** |
| Download latency under load | +66 ms | **+26 ms** |
| Upload latency under load | +260 ms (worst) | **+6 ms** |
| Download throughput | ~780 Mbps | ~680 Mbps |
| Upload throughput | 40 Mbps | 39.7 Mbps |
| Router CPU | 1–3 % | 3 % |

Cost: roughly 200 Mbps of peak download, and fasttrack disabled.

---

## Final configuration

### Queue types (pre-existing, unchanged except bandwidth)

```
/queue type
  cake-up    kind=cake cake-bandwidth=38M  cake-diffserv=diffserv4 \
             cake-flowmode=dual-srchost cake-ack-filter=filter cake-nat=yes
  cake-down  kind=cake cake-bandwidth=725M cake-diffserv=diffserv3 \
             cake-flowmode=dual-dsthost cake-nat=yes cake-rtt=100ms
```

### Upload — interface queue on WAN

```
/queue interface set [find interface=ether1] queue=cake-up
```

Interface queues are protocol-blind and sit below the fast path, so this worked
from the start and needed no other changes.

### Download — global queue tree

```
/ip firewall mangle add chain=forward in-interface=ether1 \
    action=mark-packet new-packet-mark=wan-down passthrough=yes \
    comment="mark WAN download for cake"

/ipv6 firewall mangle add chain=forward in-interface=ether1 \
    action=mark-packet new-packet-mark=wan-down passthrough=yes \
    comment="mark WAN v6 download for cake"

/queue tree add name=cake-download parent=global packet-mark=wan-down \
    queue=cake-down max-limit=725M
```

### Fasttrack — disabled, both protocols

```
/ip   firewall filter disable [find action=fasttrack-connection]
/ipv6 firewall filter disable [find action=fasttrack-connection]
```

Verify with `/ip settings print` — `ipv4-fasttrack-active` and
`ipv4-fast-path-active` must both read `no` (same for the v6 equivalents).

---

## Gotchas — read before changing anything

**1. `max-limit` is what actually enforces the cap.**
This was the whole problem. In a queue tree, RouterOS does *not* enforce the
queue type's `cake-bandwidth`; only the HTB `max-limit` on the tree node binds.
With `max-limit=0` the tree ran CAKE but never limited anything, so download
sailed past the cap and latency never improved. Set **both** values to the same
number and keep them in sync.

**2. The IPv6 mangle rule is mandatory on a dual-stack network.**
`/ip firewall mangle` is IPv4-only. This network is dual-stack and speed tests
prefer IPv6, so without the `/ipv6` twin most test traffic goes unmarked, misses
the tree entirely, and exceeds the cap.

**3. Fasttrack must be off for `parent=global` trees — on both stacks.**
Fasttracked packets skip the queue path. Disabling only the IPv4 rule leaves v6
traffic bypassing. Note also that *existing* connections keep their fasttrack
flag after the rule is disabled; `/ip firewall connection remove [find]` clears
them.

**4. Flushing conntrack drops your WinBox session.**
`/ip firewall connection remove [find]` kills all tracked sessions including
management. Expect to log back in.

**5. Interface-parented queue trees do NOT work on RouterOS 7.**
`parent=<interface>` trees are bypassed by fasttrack (this was v6-era behaviour).
Counters stay at exactly zero. Use `parent=global`, or an interface queue.

**6. Queues cannot be attached to VLAN interfaces.**
`/queue interface set [find interface=vlan5ether5] ...` returns
`failure: non rate limit queues are useless on this interface`.
The parent physical interface's queue governs tagged traffic.

**7. Waveform results are noisy — don't tune on a single run.**
Identical config produced 540 / 594 / 680 Mbps and grades B / B / A across
three consecutive runs. Take the best of several samples before concluding a
change helped or hurt.

---

## Topology notes

- **WAN:** `ether1`. All other ethernet ports are LAN.
- **LAN bridges:** `bridge5`, `bridge10`, `bridge15`, `bridge20`, `bridge25`,
  `bridge30`, `bridgecap` — members are VLAN sub-interfaces, not physical ports.
- **`sfp-sfpplus1`** left on `only-hardware-queue` deliberately: it is a 10G port
  with 9014 MTU, and a 725M CAKE ceiling would throttle LAN-to-LAN traffic ~10x.
- **Switch chip:** Marvell 88E6393X — no L3 hardware offload, so it is not a
  bypass path for routed traffic.
- Workstation `192.168.5.14` sits on `vlan5ether5` → egresses `ether5`.

## Interface queue assignments

```
ether1        cake-up               ← WAN, upload shaping
ether2–ether8 cake-down             ← LAN ports
sfp-sfpplus1  only-hardware-queue   ← intentionally unshaped
```

Note: with the global queue tree doing the download shaping, the `cake-down`
interface queues on ether2–ether8 are largely redundant. They are harmless but
could be reverted to `only-hardware-queue` if you want to simplify.

---

## Tuning

Current download cap is 725M ≈ 82 % of the 881 Mbps achievable. To trade
latency for throughput, adjust **both** together:

```
/queue tree set [find name=cake-download] max-limit=<X>M
/queue type set [find name=cake-down] cake-bandwidth=<X>M
```

Run the bufferbloat test several times per value. An 800M trial scored slightly
worse on one sample, but given the measurement noise it is worth re-testing
properly before ruling it out.

### Reverting

To drop download shaping and restore fasttrack (keeps the upload fix, which
costs nothing):

```
/queue tree disable [find name=cake-download]
/ip   firewall filter enable [find action=fasttrack-connection]
/ipv6 firewall filter enable [find action=fasttrack-connection]
```
