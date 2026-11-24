# Post-Mortem: DMZ Apple TV Resolution Failure

**Date:** 2026-07-11
**Symptom:** Apple TV in the DMZ failing all DNS-dependent operations; hammering its five cached resolvers at ~1 query/sec/resolver, retrying forever. Zero firewall drops logged.

## Root cause (two bugs masking each other)

**Bug 1 — Self-poisoned forwarders (the real fault).**
Technitium's upstream forwarders were configured by *hostname* rather than IP. To forward a query, Technitium must first resolve that forwarder hostname to an IP. But the A/AAAA records for those hostnames had been changed to point at the local reverse proxy — a box that runs **no DNS server**. So every upstream query dead-ended at a host that doesn't answer on port 53. The resolver looked healthy at the network layer (queries in, replies attempted) but had no working upstream, so real answers never materialized and clients retried forever.

**Bug 2 — Broken hairpin (why it stayed hidden).**
When the forwarder records were first changed, nothing appeared to break. That's because the hairpin masquerade wasn't catching (its counter sat at zero), so DMZ client traffic was being routed *around* the resolver entirely and never exercised the broken forwarder path. The latent misconfig had no way to surface.

Once the hairpin was fixed — confirmed by SACsd conntrack flags (seen-reply, srcnat, dstnat) and matched query/reply counts (e.g. 588 out / 587 back per resolver) — traffic finally landed on the resolver, and Bug 1 immediately surfaced.

## The fix

Set Technitium's forwarders by **IP address, not hostname.**

Forwarders should always be raw IPs precisely to avoid this chicken-and-egg: a resolver should never need to resolve a name in order to learn where to resolve names.

## If forwarders must stay as hostnames

Two fallbacks, both more fragile than raw IPs:

1. Restore the A/AAAA records for those forwarder hostnames to their correct (DNS-serving) IPs.
2. Give Technitium a bootstrap resolver that is not itself, so it can resolve the forwarder hostnames independently.

## Lessons for future-me

- **Forwarders stay as IPs.** Non-negotiable. Do not point them at hostnames.
- **Diagnose the transport before the payload.** A resolver can look completely healthy at L2/L3 — hairpin catching, conntrack green, query/reply counts matched — and still be returning nothing useful because its upstream is dead.
- **Two bugs can mask each other.** The routing bug hid the forwarder bug. Fixing one is what made the other visible; don't assume a new symptom means a new fault.
- **Zero drops ≠ healthy.** A silent failure with no logged drops points at the answer contents / upstream, not the firewall.

---

# Part II: The Self-Healing Forwarder Automation

**Date:** 2026-07-12

After the incident above, the fix was generalized into health-check daemons on the
Technitium boxes — the RouterOS `dns-fallback-check` pattern ported to Ubuntu. Each
daemon probes every Unbound upstream every 30s and keeps Technitium's forwarder list
pointed only at the healthy ones, via the Technitium HTTP API. Two boxes, deliberately
divergent:

- **LAN Technitium** (`primenodetls`, 192.168.15.9): forwards to its unbounds over
  **DoT** (853, real Let's Encrypt certs on `secnodetls` / `tertnodetls`).
- **DMZ Technitium** (`buauth`, 10.20.0.9): forwards to its unbounds over **regular
  DNS** (53), and *also* to the public GCP recursive resolvers `ns1`/`ns2`.

Getting there surfaced a long chain of interacting bugs. This is the field guide.

## The probe: test the service, over the right transport, at the right layer

- **Real DNS query, never ping.** A resolver will answer ICMP while its DNS service
  is wedged. Probe with an actual query for a name it will answer with data (`+short`
  empty on SERVFAIL/timeout catches the dead-upstream case from Part I).
- **`dig` cannot speak DoT.** The LAN unbounds listen only on 853 (TLS); a plaintext
  `dig` on 53 fails forever. Use **`kdig`** (knot-dnsutils) with full validation:
  `kdig +tls +tls-ca +tls-hostname=<SAN> @<ip> -p 853 <name> A +short`.
  `+tls-ca` validates the chain against the system trust store (catches an expired or
  wrong cert); `+tls-hostname` pins the SAN — an LE cert has **no IP in its SAN**, so
  validating a bare IP fails and the hostname is mandatory.
- **Probe the layer clients actually use.** Health-checking a DoT-only backend
  *directly* tests the wrong thing; the meaningful check is whether the client-facing
  resolver resolves end to end. (This bit us — the probe drifted onto an 853-only
  backend, so it failed on v6 while v4 happened to work.)

## Technitium forwarder mechanics (v15) — the sharp edges

The daemon drives `settings/get` and `settings/set`. Hard-won facts:

1. **Protocol is a separate field.** Setting `forwarders=<ips>` alone leaves
   `forwarderProtocol` at its default (`Udp`). To forward over DoT you must *also* set
   `forwarderProtocol=Tls`. Forget it and forwarders look correct but resolution is
   dead — Technitium fires plaintext UDP at an 853-only backend. Worse, `settings/set`
   returns `status: ok` even when it ignores a parameter, so **"ok" is not proof the
   change took** — read it back.
2. **DoT + real certs need `hostname (IP)`, not a bare IP.** A DoT handshake to a bare
   IP can't validate the LE cert. Technitium's `dns.example.com (10.0.0.2)` form uses
   the hostname for SNI/validation and the IP for the connection — cert validation
   *and* no bootstrap lookup, resolving the Part I "forwarders must be IPs" vs "DoT
   needs a name" tension in one stroke.
3. **Read-back reformatting.** Technitium rewrites what you store: v6 wrapped in
   `[brackets]` (sometimes with `:port`), a hostname gets `:853` appended (outside the
   parens), the `hostname (IP)` label is preserved verbatim in v15 (but assume it could
   be stripped to a bare IP). Every difference between what-you-write and what-you-read
   is a potential thrash.

## Defeating the compare-thrash

The daemon must rewrite forwarders *only* when they actually differ. A naive compare
(raw string sort of what we want vs what Technitium returns) differs every cycle
because of the reformatting above → it rewrites forever, hammering the API. Every
thrash we hit was a compare keyed on the wrong thing:

- v6 `[brackets]` on read-back vs bare on write.
- `:port` / `hostname:853` suffixes.
- `hostname (IP)` label vs bare IP.
- v6 `::` compression vs expanded form.

**Durable answer: compare on the normalized SET OF ADDRESSES, never the raw strings.**
A single `norm()` reduces any token — `label (ip)`, `[v6]`, `v4:port`, bare — to its
bare address; `setify()` sorts the normalized set; rewrite only when the address sets
differ (or the protocol isn't what we want). Order-, format-, and label-insensitive →
exactly one write on a real change, silence otherwise. For v6, write the **RFC 5952
canonical compressed** form (`2600:1901:8140:8c0::`) — that's what .NET/Technitium
emits, so it round-trips instead of fighting an expanded form.

## The forwarder-preservation model (DMZ only)

The LAN box *owns* its entire forwarder list (only unbounds). The DMZ box does **not**
— it also carries the public GCP resolvers `ns1`/`ns2`, which the daemon must never
clobber. So the DMZ daemon manages only its own upstreams and preserves the rest:

- `MANAGED` = the `UPSTREAMS` addresses **plus their label hostnames**, so an old
  bare-hostname entry (`ns1.example.com`) is recognized as ours and *replaced* by
  the pinned form rather than duplicated alongside it.
- Any current forwarder not in `MANAGED` is preserved verbatim.
- `want` = preserved others + healthy managed.

We later promoted `ns1`/`ns2` themselves to managed (pinned by IP, health-dropped per
family) with an optional `LABEL` map (IP → display name) so the list stays readable
while the IP is pinned. `norm()` extracting the parenthetical address means the label
never causes a thrash even if Technitium were to strip it.

## Per-family (v4/v6) independence

Each address is health-checked and added/removed independently, so a broken address
family drops just that family while the other keeps serving. This turned "the DMZ
can't reach v6" into a non-event: unreachable v6 addresses simply get dropped and
never used, so no query fails. (We then fixed the underlying v6 and they self-healed
back in — see below.)

## Operational potholes (each cost real time)

- **HTTP 307.** The DMZ console force-redirects HTTP→HTTPS. `curl` without `-L`
  silently dead-ends at the redirect (empty body → the script logs "no response"), and
  `settings/set` fails even though `settings/get` had worked earlier. Fix: `curl -L` to
  follow, plus `-k` for the loopback self-signed cert (127.0.0.1 → validation-skip is
  safe). A `-w "%{http_code}"` probe is the only way to *see* a redirect that `-f`/`-s`
  hides.
- **`curl -f` makes API errors invisible.** `-f` returns empty on any non-2xx; the
  script just logs "no response." Re-run without `-f`/`jq` and with
  `-w "\n--- HTTP %{http_code} ---\n"` to see the real status and body.
- **Verify on the target box, not a cached copy.** Repeatedly, an edited script/config
  was reinstalled from a *stale* copy — WinSCP nesting the folder inside itself
  (`~/x/x/`), or file-sync lag. Always `grep` a known marker on the box
  (`grep -c "others preserved" /usr/local/sbin/unbound-health-check.sh`) before trusting
  a deploy. The running copy is `/usr/local/sbin`, not the folder you edited.
- **Stop the old timer before deploying.** Once a redirect/permission blocker is
  removed, a still-running *old* version finally "succeeds" at doing the wrong thing
  (e.g. stripping ns1/ns2). `systemctl stop …timer …service` before installing the fix.

## The IPv6 egress root cause (the bunodes)

**Symptom:** DMZ Unbound containers (bunode1/2) couldn't reach anything off-subnet over
IPv6 — ns1/ns2 v6 "failed every time." `buauth` worked; the bunodes didn't.
**Diagnosis:** `ip -6 route` — buauth had `default via fe80::… proto ra`; the bunodes
had the on-link `/64` but **no default route at all**.
**Root cause:** `net.ipv6.conf.eth0.accept_ra = 0` on the bunodes → they ignore Router
Advertisements → never install the RA-provided default route. (The prefix/address came
from elsewhere; only the *gateway* comes from the RA, so you get on-link v6 but no
egress.)
**Fix:** `accept_ra=1` (forwarding is off, so `1` suffices), persisted in
`/etc/sysctl.d/99-ipv6-accept-ra.conf`. On boot the interface solicits an RA and
installs the default route itself — dynamic, tracks the router.

**Unprivileged-LXC notes:** `net.*` sysctls are namespaced and settable in-container;
`ping` needs `CAP_NET_RAW` the container lacks, so test egress with `dig`/`curl`, not
ping. If even route changes are denied, the fix moves to the Proxmox host
(`ip6=auto` for SLAAC, or `gw6=fe80::…` static, in the container's network config).
The harmless `Read-only file system` errors from `sysctl --system` are host-level
`kernel.*`/`fs.*`/`vm.*` keys a container can't touch — the `net.ipv6.*` key applies fine.

## Final architecture

| | LAN Technitium (192.168.15.9) | DMZ Technitium (10.20.0.9) |
|---|---|---|
| Transport | DoT (`forwarderProtocol=Tls`) | Regular DNS (`Udp`) |
| Upstreams | `secnodetls.example.com (192.168.15.10)`, `tertnodetls… (…15.11)` (+v6) + ns1/ns2 DoT | bunode1/2 (v4+v6) + ns1/ns2 pinned `ns1.example.com (34.174.100.7 / 2600:1901:8140:8c0::)` etc. |
| Probe | `kdig +tls +tls-ca +tls-hostname=<SAN>` on 853 | `dig` on 53 |
| Ownership | Owns the whole list | Manages own upstreams, preserves externals |
| Cloud (ns1/ns2) | metered — probed every 600s, not 30s | metered — probed every 600s, not 30s |
| Both | Compare on normalized address sets · one write per real change · silent otherwise · per-family v4/v6 failover · cloud probes metered for egress cost | |

## Cost control: metered probing of cloud upstreams

The GCP resolvers (`ns1`/`ns2`) bill for outbound data, and — counter-intuitively —
the **health probes, not the forwarding, are the dominant cloud egress.** With
`concurrentForwarding` picking the two *fastest* forwarders, the sub-millisecond local
unbounds almost always win, so the cloud resolvers rarely see a real forwarded query.
The 30s health probe, on the other hand, hits every upstream every cycle — 4 cloud
addresses × 1 query / 30s ≈ **11,520/day per checker**, and DoT probes carry a full TLS
handshake on top.

Fix: a **metered-probe gate**. Upstreams listed in `SLOW_UPSTREAMS` are probed at most
once per `SLOW_PROBE_INTERVAL` (default 600s); between probes the daemon reuses the
cached state and sends **no query**. Local unbounds stay on the fast 30s cadence for
tight failover; cloud addresses drop to ~144/day each (a ~20× cut). Implementation is a
few lines in `health()`: for a metered address, if `now - last_probe < interval`, echo
the cached state and return; otherwise stamp `<ip>.probed` and probe as normal.

Tradeoff: metered failover slows to ~2× the interval (the 2-probe hysteresis), i.e.
~20 min at 600s — acceptable for backup clouds, and it trades directly against query
cost via the one knob. The same gate now guards the cloud resolvers on **both** boxes,
including the LAN checker after ns1/ns2 were added there as DoT (853) upstreams.

## Consolidated lessons for future-me

1. **Forwarders stay as IPs** (Part I) — but DoT needs a name for the cert, so use
   Technitium's `hostname (IP)` form: name for validation, IP pinned so there's no
   bootstrap lookup.
2. **Probe the service over its real transport at the layer clients use.** Real query
   not ping; `kdig` (not `dig`) for DoT; validate the cert; require answer data.
3. **Setting the forwarder list is not setting the protocol.** `forwarderProtocol=Tls`
   is a separate field, and `status: ok` doesn't prove it applied — read it back.
4. **Compare on normalized address sets, not raw strings.** Strip brackets/ports,
   extract the parenthetical, canonicalize v6 — or you thrash every 30s.
5. **Own vs. preserve.** A daemon that rewrites a shared list must know which entries
   are its to manage and leave the rest alone.
6. **Per-family independence makes an unreachable address a non-event**, and lets a
   fix self-heal in without special-casing.
7. **See what the tool hides.** `curl -w "%{http_code}"` reveals the 307 and the real
   errors that `-f`/`-s` swallow into "no response."
8. **Deploy from the right copy, to the right place, after stopping the old one.**
   Verify with a `grep` marker on the target box; the runner is `/usr/local/sbin`.
9. **`accept_ra=0` gives you on-link v6 but no default route.** Prefix ≠ gateway; the
   gateway rides the RA. `accept_ra=1` (or fix it at the LXC/Proxmox layer).
10. **Probes, not forwarding, are the cloud egress cost.** Fastest-wins concurrent
    forwarding starves the cloud resolvers of real traffic, so the 30s health probe
    dominates. Meter cloud probes (probe once per N minutes, reuse cached state
    between) — big cost cut for a failover slowdown that's fine on backups.
