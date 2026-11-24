# cAP ax 5GHz — 80MHz Width Cap & Coexistence Backoff

**Date:** 2026-09-04
**Edge router:** RB5009UG+S+ (`RTR-HOMELAB-CN-1`, RouterOS 7.23.x, ARM64)
**AP:** cAP ax (`02:00:5E:FD:BC:11`), 2x2, CAPsMAN-managed via `/interface wifi`
**Radio:** `cap-wifi1` (SSID WiFi-Main, VLAN 30) + virtual `cap-wifi1-virtual` (SSID WiFi-Guest, ft-eap). Channel is owned by the master interface's config profile `cfg-wifi-main`; virtual APs inherit the radio channel.

---

## Symptom

5GHz clients capped at ~200 Mbps regardless of signal (phone at -48). Both an AC client and an AX client sat in the ~190–260 Mbps range — i.e. 40MHz-shaped throughput — even though the AP reported 80MHz.

---

## Result

| | Before | After |
|---|---|---|
| Operating channel | 5825/ax/Ceee (auto) | 5260/ax/Ceee (pinned, DFS) |
| Effective client width | ~40MHz (fell back) | full 80MHz, stable |
| Phone throughput | ~200 Mbps | 480–500+ Mbps |
| Width down-modulation | frequent 80→20/40 | none (clean secondaries) |

---

## Root cause (two stacked problems)

**1. Auto frequency range parked the block in U-NII-4.**
`cfg-wifi-main` had `channel.frequency=5180-5825` with **no `channel.width` set**. Auto-select
landed the primary on **5825 (ch165)** and built the 80MHz block upward into U-NII-4
(5850–5895). Wi-Fi 5 (AC) clients have no standard 80MHz block above ch161, so they
dropped to ~40MHz → ~200 Mbps. Reg-table `band` column showed the client PHY
(`5ghz-ac` vs `5ghz-ax`) — that reflects the *client's* negotiation, not an AP setting.

**2. After pinning 5745, coexistence backoff narrowed it.**
Pinning `channel.frequency=5745 channel.width=20/40/80mhz` moved it to the standard
149–161 block and clients jumped to 480–500. But the radio then intermittently stepped
80→20/40 on its own. Cause: **802.11 20/40 coexistence (OBSS)** — a `/interface wifi scan`
found 18 neighbor APs, with the 5745 block's secondaries crowded (five APs on 5785, one
at -78; plus 5745 and 5805 occupied). The 5180 block was worse (strong -55/-58 on
5200/5220). The radio narrows by design to protect neighbors.

---

## Fix

Move the 80MHz block onto clean spectrum. The scan's only empty 80MHz block was
**U-NII-2A, ch52–64 (5260–5320)**:

```
/interface wifi configuration set cfg-wifi-main channel.frequency=5260
```

(width stays `20/40/80mhz`). With no APs on the secondary channels, coexistence never
fires, so the radio holds full 80MHz — speeds came out even higher than on 5745.

---

## Gotchas

**1. RouterOS 7 wifi has no "80MHz only" width.**
`channel.width` only accepts the cumulative sets: `20mhz`, `20/40mhz`, `20/40/80mhz`,
`20/40/80/160mhz`. A bare `channel.width=80mhz` throws `syntax error`. You **cannot**
hard-lock 80 — `20/40/80mhz` is the ceiling and inherently permits narrower. The only way
to stop the down-modulation is to remove the trigger (clean spectrum), not to disable it.
There is no coexistence-disable toggle in wifiwave2.

**2. Channel lives on the master config, not the virtual AP.**
Set `channel.*` on `cfg-wifi-main` (the config bound to master `cap-wifi1`). WiFi-Guest
(`cap-wifi1-virtual`) shares the radio and follows automatically.

**3. Don't leave 5GHz frequency as a wide auto range.**
A range spanning up to 5825 lets auto-select climb into U-NII-4, where legacy AC clients
can't use 80MHz. Pin an explicit anchor (5180 / 5745 / 5260) + width.

**4. DFS trade-off (the site is inside a weather-radar footprint).**
5260 is DFS: provisioning to it costs a ~60s CAC (5GHz down while it listens), and a radar
detection can later force it off-channel — watch `/log` for a DFS/"radar detected" entry.
5260–5320 sits **below** the 5600–5650 TDWR weather-radar band, so hits should be rare.
Escape hatches if it ever gets noisy: the upper U-NII-2C blocks (~5580) also scanned clean.

---

## Diagnostic commands

```
/interface wifi monitor cap-wifi1 once                         # current channel / width (Ceee = 80MHz)
/interface wifi registration-table print                       # client band (ac/ax), signal
/interface wifi print detail where name=cap-wifi1              # effective channel.frequency / .width
/interface wifi configuration print detail where name=cfg-wifi-main
/interface wifi scan cap-wifi1                                 # neighbor APs by channel/signal (bumps clients off-channel)
```

**Channel-string notation:** `<freq>/<phy>/<letters>` — each letter is a 20MHz segment,
`C` = primary. `Ce` = 40MHz, `Ceee` = 80MHz, `Ceeeeeee` = 160MHz.
