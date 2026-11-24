# homelab-docs

Runbooks, incident write-ups and small configs from a home lab (Proxmox, MikroTik RB5009 + CRS305 fabric, Windows AD, OpenMediaVault, Technitium/Unbound DNS, Wazuh), kept as a portfolio of how problems were found and fixed.

**Incident reports** (`incident-reports/`): 10G NIC RX drops on a PCIe x1 slot, CAKE QoS tuning for gaming, a QoS fix, NAS AD trust failure, Kerberos/NTP SMB outage, VLAN ND dropout breaking winbind, jumbo-frame MTU blackhole, 5 GHz 80 MHz coexistence, IPv6 firewall parity scan, DMZ resolver postmortem, SIEM expansion write-up.

**Runbooks** (`runbooks/`): AG switch fabric, DNS egress enforcement on MikroTik, router consolidation, iSCSI/ZFS migration and OMV decommission, NAS NIC swap and routing, RB5009 CAKE QoS, Zammad deployment, and a household "complaint desk" page.

**Configs and scripts** (`configs/`, `scripts/`, `html/`): agent-box and IoT VLAN firewall rules, NAS isolation service, Zammad nginx config, NAS NIC-swap helpers, custom 401 page.

---

*Published from a home lab. Site identifiers are sanitized: public IPv4 uses the documentation ranges (203.0.113.0/24, 198.51.100.0/24), the delegated IPv6 prefix is `2001:db8::/32`, the ULA prefix is `fd12:3456:789a::/48`, domains are `example.com` / `home.arpa`, MAC addresses, Wi-Fi SSIDs, serials, keys and names are replaced. RFC 1918 addresses are left as they are so the layouts still read. Credentials are never in these files; scripts read them from `agent.env` or similar files that are not published.*

## Disclaimer

This repository is shared **as is**, for reference and learning. It is a personal home-lab project, not a product, and it comes with no support.

- **No warranty.** Everything here (code, configurations, scripts, rules and documentation) is provided without warranty of any kind, express or implied, including fitness for a particular purpose. It may contain bugs, errors or omissions.
- **No commitment to maintain.** The author makes no commitment to fix bugs, answer questions, upgrade or update this repository beyond what is provided here. Any future updates are made purely on a voluntary basis, at the author's sole discretion, and may stop at any time.
- **You are solely responsible.** Any review, adaptation, configuration, testing, deployment or operation of this material is solely the responsibility of the person using it. Bugs, fixes and updates in your environment are yours to handle.
- **No liability.** To the fullest extent permitted by law, the author is not liable for any damages or losses of any kind arising from the use or misuse of this material, including but not limited to outages, data loss, security incidents, lost revenue, damage to hardware or other property, and any physical or digital harm.
- **Test before you trust.** Several scripts change firewalls, routers, DNS, authentication or system services. Read them, adapt them to your network, test them in a lab, and keep backups and a rollback path before running anything in production.

## License

The code and documentation in this repository are released under the [MIT License](LICENSE), an open-source license, unless a file or folder states otherwise.
