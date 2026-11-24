# IPv6 ↔ IPv4 Firewall Parity Scan — R1 (`map`, RB5009, ROS 7.23.2)

**Scanned live:** 2026-08-01, via WinBox terminal on `map`. Read-only exports of
`/ip` and `/ipv6` firewall `filter`, `nat`, `mangle`, `raw`, and `address-list`.

> ## ✅ APPLIED 2026-08-01 (Safe Mode, committed)
>
> All three gaps below were fixed live and verified. Work was done with the WinBox
> Safe-Mode toggle on, then committed; v6 port-53 conntrack was flushed afterward.
>
> - **Gap 1 — v6 raw:** added `drop WAN-inbound DNS v6 (udp)` and `(tcp)`. Verified in
>   `/ipv6 firewall raw print`.
> - **Gap 2 — client-facing GUA:** `dns-auth6` += bauth GUA (`…2b01…c59`) + primenode GUA
>   (`…2b05…93b0`); `dns-dmz6` += bauth GUA; `dns-lan6` += primenode GUA.
> - **Gap 3 — `dns6` exemption:** added current DMZ-side GUA on `2b01` for bauth, bunode1,
>   bunode2; **removed** the three stale `2b04` entries. LAN-side infra (primenode,
>   secnodetls, tertnodetls) stays covered by the existing `2b05::/64` + `fd9a:…:15::/64`
>   prefix exemptions — no per-host adds needed.
>
> Node addresses used (you supplied): bunode1 `…2b01…fe0e:458d` / `…:10…458d`,
> bunode2 `…2b01…fefd:c36a` / `…:10…c36a`, secnodetls `…2b05…fe4d:4c62` / `…:15…4c62`,
> tertnodetls `…2b05…fe15:71fa` / `…:15…71fa`. bunode1's live ULA read as `:458d`
> (matches you) — my earlier `:458a` was a misread.
>
> **Deliberately NOT added to client-facing lists:** bunode1/2 and secnodetls/tertnodetls
> are the forwarder tier — putting them in `dns-auth6`/`dns-dmz6`/`dns-lan6` would reopen
> the forwarder-bypass hole. They remain source-exempt (`dns6`) only.
>
> **Cleanup — also done:** removed the dead v6 `input: OSPFv3 from R2` rule
> (`chain=input protocol=ospf in-interface=ether3`). Swept both stacks for any other
> R2/OSPFv3 remnants and confirmed clean: v4 filter has **no** OSPF/R2 rules, there are
> **no** OSPF instances/areas/interface-templates, and **no** `r2-networks` address-list
> on either stack. The `2026-07-31` flatten had already removed everything except this one
> v6 rule.
>
> **Still open (optional enhancement, not cleanup — your call):** GUA-target dstnat redirect
> twins, so hardcoded **public-GUA** resolver bypass attempts get transparently answered
> instead of just failing closed. v4 doesn't need this (single family); it's beyond strict
> parity, so I left it.

The section below is the original scan write-up; the fix commands there are the ones
that were applied.

**Roles (confirmed):** `primenode` = LAN/internal authoritative resolver (the "primary"),
`bauth` = DMZ authoritative resolver.

| Host | GUA (you gave) | ULA (you gave) |
|---|---|---|
| bauth (DMZ auth) | `2001:db8:4a00:2b01:216:3eff:fe0e:c59` | `fd12:3456:789a:10:216:3eff:fe0e:c59` |
| primenode (LAN auth) | `2001:db8:4a00:2b05:be24:11ff:fe6a:93b0` | `fd12:3456:789a:15:be24:11ff:fe6a:93b0` |

---

## Verdict

The v6 DNS-egress policy is **already at near-full parity** with v4. The forward-chain
drops, both bidirectional fallback gates, all four NAT redirect pairs, the DMZ hairpin,
and the mangle connection-marks are all present and structurally equivalent. Three real
gaps remain — one clear miss (raw table) and two addressing/coverage issues around IPv6
scope.

---

## What already matches (no action)

| Control | IPv4 | IPv6 | Status |
|---|---|---|---|
| DMZ clients → auth resolvers only (udp + tcp/853) | `src-address=10.20.0.0/25`, `dst-list=!dns-auth` | `in-interface=bridge10`, `dst-list=!dns-auth6` | ✅ parity |
| Internal clients → auth resolvers only (udp + tcp/853) | `src-list=lan-clients`, `dst-list=!dns-auth` | `in-interface-list=LAN`, `dst-list=!dns-auth6` | ✅ parity |
| Fallback gate — block DMZ→LAN resolver | `dst-list=dns-lan` | `dst-list=dns-lan6`, `in-interface=bridge10` | ✅ parity |
| Fallback gate — block LAN→DMZ resolver | `dst-list=dns-dmz` | `dst-list=dns-dmz6`, `in-interface-list=!DMZ` | ✅ parity |
| Resolver reachability accept (client→auth) | `forward: dns … dst-list=dns-auth` | `forward: dns6 … dst-list=dns-auth6` | ✅ parity |
| dstnat — DMZ redirect primary (udp/tcp) | → `10.20.0.9` | → `fd9a:…:10:…:c59` (bauth ULA) | ✅ parity |
| dstnat — LAN redirect primary (udp/tcp) | → `192.168.15.9` | → `fd9a:…:15:…:93b0` (primenode ULA) | ✅ parity |
| dstnat — LAN redirect fallback (disabled twins) | → `10.20.0.9` | → bauth ULA | ✅ parity |
| dstnat — DMZ redirect fallback (disabled twins) | → `192.168.15.9` | → primenode ULA | ✅ parity |
| srcnat — DMZ hairpin masquerade | `conn-mark=dmz-dns-hairpin`, out `bridge10` | same | ✅ parity |
| mangle — mark redirected DMZ DNS (udp/tcp) | `dst=10.20.0.9`, mark `dmz-dns-hairpin` | `dst=bauth ULA`, mark `dmz-dns-hairpin` | ✅ parity |
| Health-check toggle comments | `DNS fallback block …` / `… DNS redirect primary/fallback` | identical substrings | ✅ the existing scheduler already toggles both families |

---

## Gaps found

### Gap 1 — `/ipv6 firewall raw` is empty (v4 has WAN dst-53 drops)

v4 has:

```
/ip firewall raw
add chain=prerouting action=drop protocol=udp in-interface-list=WAN dst-port=53
add chain=prerouting action=drop protocol=tcp in-interface-list=WAN dst-port=53
```

v6 has **no raw rules at all**. The v6 input chain already defaults to drop, so this is
defense-in-depth / pre-conntrack hygiene rather than an open hole — but it's a clean miss
of parity.

**Fix (pure add, zero risk):**

```
/ipv6 firewall raw
add chain=prerouting action=drop protocol=udp in-interface-list=WAN dst-port=53 comment="drop WAN-inbound DNS v6 (udp)"
add chain=prerouting action=drop protocol=tcp in-interface-list=WAN dst-port=53 comment="drop WAN-inbound DNS v6 (tcp)"
```

### Gap 2 — client-facing v6 lists are ULA-only (no GUA members)

`dns-auth6`, `dns-dmz6`, and `dns-lan6` contain **only the ULA `/128`** of each resolver:

- `dns-auth6` = { primenode ULA, bauth ULA }
- `dns-dmz6`  = { bauth ULA }
- `dns-lan6`  = { primenode ULA }

v4's single family is fully covered, so this is a v6-only coverage gap. As long as your
RAs hand out **only** the ULA for DNS, live behaviour is fine. But every VLAN has GUA via
prefix delegation, so if anything reaches a resolver by its GUA it is treated as a
non-resolver and dropped/redirected. Completing the lists makes the policy scope-complete.

**Fix (add current GUA `/128`s):**

```
/ipv6 firewall address-list
add list=dns-auth6 address=2001:db8:4a00:2b05:be24:11ff:fe6a:93b0 comment="primenode GUA (LAN auth)"
add list=dns-auth6 address=2001:db8:4a00:2b01:216:3eff:fe0e:c59  comment="bauth GUA (DMZ auth)"
add list=dns-dmz6  address=2001:db8:4a00:2b01:216:3eff:fe0e:c59  comment="bauth GUA (DMZ auth)"
add list=dns-lan6  address=2001:db8:4a00:2b05:be24:11ff:fe6a:93b0 comment="primenode GUA (LAN auth)"
```

### Gap 3 — `dns6` source-exemption GUA entries are on a STALE prefix (`2b04`)

The `dns6` list (resolver-infra source exemption) does carry GUA entries, but they sit on
`2001:db8:4a00:2b04:…` and are commented **"re-delegation risk"**:

```
dns6  2001:db8:4a00:2b04:216:3eff:fe0e:c59   ;;; buauth  GUA
dns6  2001:db8:4a00:2b04:216:3eff:fe0e:458a  ;;; bunode1 GUA
dns6  2001:db8:4a00:2b04:216:3eff:fefd:c36a  ;;; bunode2 GUA
```

The addresses **you gave me are on `2b01` (bauth) and `2b05` (primenode)** — a different
sub-prefix. That is exactly the ISP re-delegation the comment warned about: the current
GUA delegation has moved off `2b04`, so these exemptions no longer match the resolvers'
live GUAs. Effect: a resolver making an upstream query from its **current** GUA is not
source-exempt and can be caught by its own egress drops.

**Fix (add current GUA to the exemption; then retire the stale `2b04` entries):**

```
/ipv6 firewall address-list
add list=dns6 address=2001:db8:4a00:2b01:216:3eff:fe0e:c59  comment="bauth GUA (current 2b01)"
add list=dns6 address=2001:db8:4a00:2b05:be24:11ff:fe6a:93b0 comment="primenode GUA (current 2b05)"
# after confirming the bunodes' CURRENT GUAs, refresh those too, then:
# /ipv6 firewall address-list remove [find list=dns6 address~"2b04"]
```

> ⚠️ I only have your confirmed current GUAs for **bauth** and **primenode** — not for
> `bunode1`/`bunode2`. Confirm their live GUAs before removing the `2b04` bunode entries,
> or you'll strip the unbound tier's source exemption.

---

## Other observations (not v4/v6 parity, but worth a look)

- **Stale input rule:** v6 input chain still has `input: OSPFv3 from R2` (`in-interface=ether3`).
  Per the flatten runbook, R2 is now pure L2 and OSPFv3 was meant to be removed — this rule
  is dead. (Confirm, then `/ipv6 firewall filter remove [find comment~"OSPFv3 from R2"]`.)
- **Redirect scope:** the v6 dstnat targets are ULA. A client hardcoded to a **public GUA**
  resolver still gets caught by the filter drop (fails closed, correct), but the redirect
  can't transparently "fix" it the way v4 does within one family. Only relevant if you want
  hardcoded-GUA devices to resolve transparently; it would need GUA-target redirect twins
  (beyond strict v4 parity).

---

## Suggested apply order (all in **safe mode**)

1. **Gap 1** — raw drops. Pure add, no interaction with live flows. Safe to apply now.
2. **Gap 2** — GUA members on client-facing lists. Additive; only widens what's permitted.
3. **Gap 3** — refresh `dns6` GUA, confirm bunode GUAs, then retire `2b04`. Do the removal
   last, after you've verified the current bunode addresses.

After changes: flush stale v6 conntrack so cached no-NAT verdicts don't linger —
`/ipv6 firewall connection remove [find dst-port=53]` — and confirm the `dns-fallback-check`
scheduler still toggles the v6 gates (it will; the comments already match).
