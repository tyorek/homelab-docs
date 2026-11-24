# pibox: NIC role swap, DMZ routing cleanup, OMV sync (2026-10-17)

**Host:** pibox, Raspberry Pi 4 (onboard eth0 = bcmgenet, max MTU 1500), OMV, Docker (NPM), LXC (buauth/bunodes on br1)
**USB NIC:** enp1s0u1, Realtek, MAC 02:00:5e:be:56:86, max MTU 9194

## Final state (verified)

| Role | Interface | IPv4 | IPv6 | MTU |
|---|---|---|---|---|
| VLAN 5 storage | enp1s0u1 (USB) | 192.168.5.5/28 (DHCP reservation by MAC) | fd12:3456:789a:5:da3a:ddff:fec3:a511, 2001:db8:4a00:2b04:da3a:ddff:fec3:a511 (token keeps pre-swap IDs) | 9000 |
| DMZ | br1 (port: onboard eth0) | 10.20.0.2/25 | fd12:3456:789a:10:1490:76ff:fe0b:78b7, 2001:db8:4a00:2b01:1490:76ff:fe0b:78b7 | 1500 |

- Jumbo verified: `ping -f -l 8972 192.168.5.5` succeeds end to end (also across the router).
- Single IPv4 default route: via 10.20.0.1 on br1. NPM, Docker and pibox's own egress leave via the DMZ.
- Policy rule 200: anything sourced from 192.168.5.0/28 (and VLAN 5's two IPv6 /64s) uses table 200 -> answers via VLAN 5.
- DC host routes 192.168.20.6/.7 via 192.168.5.1 keep winbind/Kerberos on the data side.
- IPv6 router advertisements on VLAN 5 go into table 200 only (no second IPv6 default in main).
- br1 MAC pinned (02:00:5e:6b:55:70) -> 10.20.0.2 and DMZ IPv6 unchanged through the swap.
- NPM verified: HTTP 200 for home.example.com over IPv4 (10.20.0.2) and TLS over IPv6.

## Config ownership

- OMV DB (Network page) now matches reality: br1 member = eth0 (MTU 1500); enp1s0u1 = ethernet, DHCP, MTU 9000, IPv6 manual.
  Writes `/etc/netplan/20-openmediavault-enp1s0u1.yaml` and `60-openmediavault-br1.yaml`.
- `/etc/netplan/50-pibox.yaml` (ours) adds only routing/behaviour on top. OMV redeploys leave it alone.

```yaml
network:
  version: 2
  ethernets:
    enp1s0u1:
      dhcp-identifier: mac
      link-local: [ipv6]
      accept-ra: true
      ipv6-address-token: "::da3a:ddff:fec3:a511"
      ra-overrides: {table: 200, use-dns: false}
      dhcp4-overrides: {use-routes: false, use-dns: false, use-ntp: false}
      dhcp6-overrides: {use-routes: false, use-dns: false, use-ntp: false}
      routes:
        - {to: 192.168.5.0/28, scope: link, table: 200}
        - {to: default, via: 192.168.5.1, on-link: true, table: 200}
        - {to: 192.168.20.7/32, via: 192.168.5.1}
        - {to: 192.168.20.6/32, via: 192.168.5.1}
      routing-policy:
        - {from: 192.168.5.0/28, table: 200, priority: 200}
        - {from: "fd12:3456:789a:5::/64", table: 200, priority: 200}
        - {from: "2001:db8:4a00:2b04::/64", table: 200, priority: 200}
  bridges:
    br1:
      macaddress: 02:00:5e:6b:55:70
      ignore-carrier: true
```

## ARP flux fix (05:37)

- pibox: `/etc/sysctl.d/99-arp-multihome.conf` sets `net.ipv4.conf.all.arp_ignore=1` and `net.ipv4.conf.all.arp_announce=2`, so each address is answered only on its own interface.
- Router: removed the stale `10.20.0.2 -> 02:00:5e:be:56:86 on bridge5` entry. After a fresh ping, only `10.20.0.2 -> 02:00:5e:6b:55:70 on bridge10` remains.

## Router changes

- DHCP lease 192.168.5.5 (dhcp1): mac-address=02:00:5e:be:56:86, client-id="" (match on MAC only), comment "pibox VLAN5 (USB NIC, jumbo)".
- Forward rule added before "isolate vlans": accept tcp 10.20.0.2 -> 192.168.99.8:3000,8090 ("npm (DMZ): Homepage + digest viewer").

## Problems hit and why (for next time)

1. **Interfaces on the wrong VLANs** - roles swapped in software but cables not swapped (or vice versa). Switch ports are access ports; config and cabling must change together.
2. **Staged config never activated** - the step-1 script parked the new file under /root by design; `netplan try` re-applied OMV's files.
3. **192.168.5.5 kept coming back as .2** - the reservation still carried systemd-networkd's old DUID client-id. Fixed with `dhcp-identifier: mac` on pibox and client-id="" on the lease. (RouterOS: `unset ... client-id` is rejected; use `set ... client-id=""`.)
4. **IPv6 changed on VLAN 5** - SLAAC IDs derive from the MAC; the USB NIC has a different MAC. Restored with `ipv6-address-token`.
5. **NPM unreachable over IPv4** - at 05:12:40 br1 lost carrier for about 1 s during an apply; networkd dropped br1's DHCP config (default route) and did not renew. Replies from NPM had no route back. Fixed with `networkctl reconfigure br1`; prevented with `ignore-carrier: true` on br1.
6. **Earlier lockout** - the first policy-routing attempt used a table-200 default without `on-link`, and the session dropped mid-`netplan try`. Use tmux, or the local console, for network changes.

## Follow-ups (05:50-06:25)

- **pibox lost its own DNS/egress**: OMV INPUT rule 2 (reject all to 10.20.0.2 except 80/443) rejected reply traffic once pibox started sourcing from 10.20.0.2. Fix: `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` at the top of INPUT (IPv4 + IPv6). Added at runtime; **must also exist in OMV Firewall rules (both tabs, top position)** to survive an apply or reboot.
- **NPM -> OMV returned 504**: replies from 192.168.5.5 to the NPM container (172.18.0.2) hit policy rule 200, and table 200 has no Docker route. Fix: rule `to 172.16.0.0/12 lookup main` priority 100 (netplan: `{to: 172.16.0.0/12, table: 254, priority: 100}` as the first routing-policy entry).
- **omv.pibox.example.com**: A record -> 10.20.0.2 on both Technitium servers (primenodetls had been created as an empty zone; added `@` A record). NPM proxy host -> http://192.168.5.5:8080 with websockets, cert `*.pibox.example.com` (Let's Encrypt via Cloudflare DNS challenge; first attempts failed with a malformed API token, Cloudflare error 6111). Chain verified: leaf -> YE1 -> Root YE -> X2 -> X1.
- The browser "not secure" warning was the browser remembering a warning bypassed earlier; a full browser restart cleared it.
- Name -> interface rule of thumb: proxied names -> DMZ (10.20.0.2 / fd9a:...:10:1490:76ff:fe0b:78b7); storage/admin -> VLAN 5 (192.168.5.5 / fd9a:...:5:da3a:ddff:fec3:a511).

## Still open

- DNS: `pibox.home.arpa` (Technitium) has no AAAA record; add fd12:3456:789a:5:da3a:ddff:fec3:a511 if wanted. `home.example.com` has no AAAA either (IPv4 only).
- NPM admin port 81 still published on all addresses (bind to 192.168.5.5:81 in compose).
- OMV INPUT firewall: make the ESTABLISHED,RELATED rule permanent in the GUI (both tabs, top). Rule 3's source port 8080 never matches.
- Confirm the 172.16.0.0/12 -> main rule is in 50-pibox.yaml (not just added at runtime).
- Internal pibox.example.com still has two VLAN 5 AAAA records; proxied names should list only DMZ addresses.
- Consider keeping omv.pibox.example.com internal-only (no Cloudflare record), or adding an NPM access list.
- Optional: rule 46 (NPM -> Homepage from 192.168.5.5) is now redundant.

## AD trust "broken" after the swap (fixed 07:53)

What looked like a broken trust was DNS. systemd-resolved treats `.local` as multicast DNS and will not forward `home.arpa` queries to unicast DNS servers unless some link or the global config claims that domain. Plain `host` returned REFUSED from the local resolved stub, while `dig @10.20.0.9` and `dig @192.168.15.9` both returned dc01/dc02, which showed the records and the upstream servers were fine. After the swap, no pibox link carried the `home.arpa` domain any more, so winbind couldn't find the domain controllers.

Fix: the resolved drop-in `/etc/systemd/resolved.conf.d/homelab-ad.conf`, which OMV and netplan don't touch:

```
[Resolve]
DNS=10.20.0.9 192.168.15.9
Domains=~home.arpa
```

Verified after the fix: the SRV lookup works through the stub, `net ads testjoin` returns Join is OK, `sudo wbinfo -t` succeeds, and `wbinfo -u` and `getent passwd` resolve domain users. Note that `wbinfo -t` must be run with sudo: as a normal user it fails with WBC_ERR_WINBIND_NOT_AVAILABLE because it can't open winbind's privileged socket.

## Final checks (07:59)

The `to 172.16.0.0/12 lookup main priority 100` rule is saved in 50-pibox.yaml, so the fix for the NPM-to-OMV 504s survives a reboot. The OMV firewall service is active. In the IPv6 INPUT chain, the established/related accept comes first, then 80/443 accepts for the public and ULA DMZ addresses, then TCP and UDP rejects for each address. ICMPv6 is no longer rejected, so neighbor discovery and ping work.
