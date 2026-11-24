# homelab-docs

Runbooks, incident write-ups and small configs from a home lab (Proxmox, MikroTik RB5009 + CRS305 fabric, Windows AD, OpenMediaVault, Technitium/Unbound DNS, Wazuh), kept as a portfolio of how problems were found and fixed.

**Incident reports** (`incident-reports/`): 10G NIC RX drops on a PCIe x1 slot, CAKE QoS tuning for gaming, a QoS fix, NAS AD trust failure, Kerberos/NTP SMB outage, VLAN ND dropout breaking winbind, jumbo-frame MTU blackhole, 5 GHz 80 MHz coexistence, IPv6 firewall parity scan, DMZ resolver postmortem, SIEM expansion write-up.

**Runbooks** (`runbooks/`): AG switch fabric, DNS egress enforcement on MikroTik, router consolidation, iSCSI/ZFS migration and OMV decommission, NAS NIC swap and routing, RB5009 CAKE QoS, Zammad deployment, and a household "complaint desk" page.

**Configs and scripts** (`configs/`, `scripts/`, `html/`): agent-box and IoT VLAN firewall rules, NAS isolation service, Zammad nginx config, NAS NIC-swap helpers, custom 401 page.

---

*Published from a home lab. Site identifiers are sanitized: public IPv4 uses the documentation ranges (203.0.113.0/24, 198.51.100.0/24), the delegated IPv6 prefix is `2001:db8::/32`, the ULA prefix is `fd12:3456:789a::/48`, domains are `example.com` / `home.arpa`, MAC addresses, Wi-Fi SSIDs, serials, keys and names are replaced. RFC 1918 addresses are left as they are so the layouts still read. Credentials are never in these files; scripts read them from `agent.env` or similar files that are not published.*
