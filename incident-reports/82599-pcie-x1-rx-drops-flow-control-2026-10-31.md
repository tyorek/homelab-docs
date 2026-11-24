# Proxmox 10G NIC: PCIe x1 bottleneck, receive drops, flow-control fix

**Date:** 2026-10-31 (morning)
**Host:** pve (Proxmox VE 9.2, kernel 7.0.14-26-pve)
**NIC:** Intel 82599 SFP+ (`enp5s0`, ixgbe, bus `0000:05:00.0`), bridge port for `vmbr0`
**Switch:** AG01 (CRS305), host-facing port `sfp-sfpplus2`
**Trigger:** investigating game disconnects that line up with son's PC coming online; all LAN DNS
resolves through VMs/LXCs on pve, so any loss at the host NIC hits DNS

## What was found

**1. The 82599 is bus-limited, not link-limited.** The Ethernet link is 10G on the wire, but the card
sits in PCIEX1_1 on the B850 AORUS ELITE WIFI7 ICE. That slot is a full-length x16 connector wired as
PCIe 3.0 x1 off the chipset. The 82599 is a PCIe 2.0 x8 card, so the link trains at the lower of the two:

```
LnkCap: Port #0, Speed 5GT/s, Width x8
LnkSta: Speed 5GT/s, Width x1 (downgraded)
```

PCIe 2.0 x1 = 5 GT/s with 8b/10b = 4 Gb/s raw (500 MB/s), about 3.2 Gb/s (~400 MB/s) of real
throughput. `ethtool` still reports `Speed: 10000Mb/s` because that is the SFP+ link, not the bus.

**2. The NIC was dropping on receive.** Bursts from AG01 at 10G overran the 82599's on-chip rx
buffer faster than it could DMA across the x1 link:

```
rx_packets:        9,411,851
rx_missed_errors:  4,131      (~0.044%, still climbing under ordinary traffic)
rx_fifo_errors / rx_no_dma_resources / tx_fifo_errors: 0
```

Transfers to the host showed a sawtooth (TCP backing off on each loss). Any DNS query caught in a
drop is UDP and waits out a client timeout (1-2 s+) before retrying.

**3. The other end of the path is not limited.** The bedroom PC's 10G NIC (`Ethernet 3`) runs PCIe 2.0 x4
(16 Gb/s raw). The host's x1 slot is the only bus bottleneck on the bedroom PC <-> pve path.

**Ruled out:**
- RB5009 `sfp-sfpplus1` tx-queue-drop: 0 over ~103.6M tx packets (the ~4.9k noted in the 10/16 audit
  has not recurred in the current counter window).
- AG01 `sfp-sfpplus1` (uplink to router) tx-queue-drop: 0 over ~1.03B tx packets.
- RB5009 `ether1` (WAN): all rx error counters 0. The download sawtooth on internet traffic is TCP working
  against the CAKE download shaper, as designed.
- CAKE / fq_codel on the host: cannot help. The drops happen in NIC hardware before the kernel sees
  the packet; any qdisc (including ingress via IFB) is downstream of the loss.

## Changes made

```
# AG01: honor pause frames from the host on the host-facing port
/interface ethernet set sfp-sfpplus2 rx-flow-control=on      # tx-flow-control optional, harmless

# pve: send pause frames (applied live)
ethtool -A enp5s0 autoneg off rx on tx on
```

Persisted in `/etc/network/interfaces`, verified with `ifquery enp5s0`:

```
iface enp5s0 inet manual
        post-up /usr/sbin/ethtool -A enp5s0 autoneg off rx on tx on
        mtu 9018
```

Expected side effect: enabling flow control on the AG01 port renegotiated the link. A DNS probe on
The admin workstation logged one 7,020 ms lookup at 09:15:51 during the bounce, then 4 ms.

## Verification

- Large transfer to pve held flat at **408 MB/s** (~3.26 Gb/s, the Gen2 x1 ceiling) instead of sawtoothing.
- `rx_missed_errors` stayed at **4,136** while rx_packets went from 9,463,722 to 10,191,929.
- AG01 `sfp-sfpplus2`: `rx-pause` 453,803 (the 82599 pausing the switch, switch honoring it),
  `tx-drop-packet` 0 on all 8 queues, `rx-overflow` 0, `tx-pause` 0.

Every hop on the path is now lossless: RB5009 sfp1, AG01 uplink, AG01 host port, 82599 rx.

## Decisions

- **No DNS priority class on RB5009 sfp1.** A priority class only acts where a queue forms; sfp1 shows
  zero queue drops and stays on `only-hardware-queue`. A software queue on the main 10G trunk would cost
  CPU and hardware offload for no gain. The existing `up-dns` class on the WAN upload (10/17 follow-up in
  `MikroTik-QoS-Fix-2026-10-16.md`) stays as is.
- **No flow control on ether1 (WAN).** The router isn't the slow receiver there; pausing the modem would
  push the queue into the CM1200/CMTS and bring back the bufferbloat CAKE removes.

## Still to do

- Confirm the link to the game drops: on son's next cold boot, keep the DNS probe running and compare
  `rx_missed_errors` against 4,136. Not yet proven to be the cause.
- Optional `iperf3 -P 4` baseline from the bedroom PC to pve, then recheck `rx_missed_errors`.
- Bus headroom: a PCIe 3.0 10G NIC (X710-based or ConnectX-4 Lx) in the same x1 slot would give
  ~6.5-7 Gb/s. Full 10G on this board needs an x8/x8 bifurcation riser (BIOS support unconfirmed) or an
  M.2-to-PCIe x4 adapter in M2B_CPU (under the M.2 heatsink and the GPU).
- Resilience: put one resolver off the Proxmox host so LAN DNS doesn't depend on a single NIC.
- Anything served from pve (e.g. a future LANCache) is capped at ~400 MB/s until the NIC changes.

## Rollback

```
# pve
ethtool -A enp5s0 rx off tx off
sed -i '/post-up \/usr\/sbin\/ethtool -A enp5s0/d' /etc/network/interfaces

# AG01
/interface ethernet set sfp-sfpplus2 rx-flow-control=off tx-flow-control=off
```
