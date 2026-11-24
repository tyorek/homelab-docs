# LinkedIn post: Wazuh SIEM expansion post-mortem (2026-11-20)

Image to attach: `HTML Mockups & Images/wazuh-threat-detection-dashboard-2026-11-20.png` (Threat Detection Heat Map
dashboard; only external attacker/CDN IPs visible, no browser URL bar).
Full technical write-up: `Runbooks & Setup Guides/wazuh-syslog-mikrotik-npm-rollout.md`.

Left out of the post on purpose: internal IPs and VLAN numbers, the home IPv6 prefix (it pins the ISP and area),
public hostnames of the admin UIs, and which hosts sit behind which proxy.

---

## Full post-mortem version

What happens when you give your SIEM eyes on the network fabric? It finds something within 30 minutes.

Home lab post-mortem: my Wazuh SIEM only saw hosts that could run an agent. The devices actually enforcing my segmentation (a MikroTik RB5009 and three access switches) sent it nothing. Firewall drops for my zero-trust IoT VLAN were sitting in a 2,000-line RAM buffer on the router, and my reverse proxy's access logs for every internet-facing host were never collected.

What I built in one morning:
→ Wazuh as the syslog receiver for the whole MikroTik fabric, with custom decoders and 21 rules (IoT VLAN escape attempts, brute force, recon probes)
→ Nginx Proxy Manager access logs pushed to its agent through Wazuh's centralized config
→ GeoIP enrichment for Suricata's src_ip in the indexer ingest pipeline, plus a backfill of 17,749 alerts, so IPS block-list hits finally land on a map
→ The dashboard below: attack sources, top countries, detections over time, and inbound IPS hits

What broke along the way (the useful part):
1. Wazuh only runs the first matching child decoder, so my login fields came out empty until I split them.
2. A built-in decoder for a web server I don't run silently captured my proxy logs because the timestamp format looked the same.
3. Behind Cloudflare, every attacker had the same IP: Cloudflare's. The proxy read X-Real-IP; Cloudflare sends CF-Connecting-IP.
4. My first heat map was a blue haze. Half the GeoIP results were country-only, stacked on country centroids, and one centroid set the whole color scale.
5. The switches had DHCP addresses on every VLAN, including the DMZ, so their management plane was reachable from places it shouldn't be. Fixed.

The payoff: within 30 minutes the new firewall feed flagged my monitoring box hitting Microsoft's mail servers on port 25 every few seconds. A default Postfix install was retrying cron mail that could never leave its locked-down VLAN. Small issue, but exactly the kind of thing that hides when you can't see the network.

Lesson: list the devices that enforce your policy but can't run an agent. That's where your blind spots are.

#Wazuh #SIEM #SOC #BlueTeam #Suricata #MikroTik #HomeLab #Cybersecurity #ThreatDetection

---

## Short version

My Wazuh SIEM could see every host with an agent, and none of the network gear that actually enforces my segmentation. So I fixed that.

In one morning: MikroTik router and switch syslog into Wazuh with custom decoders and 21 rules, reverse-proxy access logs with real client IPs (Cloudflare was masking every attacker), and GeoIP enrichment for Suricata so IPS block-list hits show up on a threat map (dashboard below).

Within 30 minutes the new firewall feed caught my monitoring box retrying undeliverable mail to Microsoft every few seconds. Blind spots live where your agents can't.

#Wazuh #SIEM #SOC #BlueTeam #HomeLab #Cybersecurity
