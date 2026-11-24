# agent-box-vlan99-firewall.rsc
# Lockdown rules for the Claude agent LXC on VLAN 99 (192.168.99.3).
#
# STATUS: APPLIED on RTR-HOMELAB-CN-1 (RB5009, RouterOS 7.23.5) via Winbox
# terminal on 2026-10-01. This file is now a record of what's live, not a
# draft to paste -- re-running the `add` lines below would duplicate rules.
#
# Resolved values: Proxmox host = 192.168.99.2, RouterOS read-only target =
# 192.168.99.1 (the RB5009's own mgmtVlan99 address), admin workstation =
# 192.168.5.9. IPv6 GUA/ULA below were verified against the live ARP entry
# for 192.168.99.3 (MAC 02:00:5e:87:89:26 -> EUI-64 be24:11ff:feb3:21d2) --
# re-verify these if the LXC is ever rebuilt with a new MAC.

/ip firewall address-list
add list=agent-box     address=192.168.99.3   comment="claude agent LXC"
add list=agent-targets address=192.168.5.12   comment="Wazuh manager"
add list=agent-targets address=192.168.99.2   comment="Proxmox API"
add list=agent-targets address=192.168.99.1   comment="RouterOS read-only (SSH/API-SSL)"

/ip firewall filter
add chain=forward action=accept src-address-list=agent-box dst-address=192.168.5.12 protocol=tcp dst-port=55000 comment="agent: Wazuh API"
add chain=forward action=accept src-address-list=agent-box dst-address=192.168.99.2 protocol=tcp dst-port=8006 comment="agent: Proxmox API"
add chain=forward action=accept src-address-list=agent-box dst-address-list=agent-targets protocol=tcp dst-port=22,8729 comment="agent: SSH / API-SSL to targets"
# DNS only to the local resolvers (matches the existing DNS egress policy)
add chain=forward action=accept src-address-list=agent-box dst-address-list=dns-auth protocol=udp dst-port=53 comment="agent: DNS udp"
add chain=forward action=accept src-address-list=agent-box dst-address-list=dns-auth protocol=tcp dst-port=53 comment="agent: DNS tcp"
# HTTPS out to the internet (Anthropic API + apt/npm). ether1 is WAN.
add chain=forward action=accept src-address-list=agent-box out-interface-list=WAN protocol=tcp dst-port=443 comment="agent: HTTPS out"
add chain=forward action=drop   src-address-list=agent-box comment="agent: drop all other egress"
# Nothing else may initiate into the box except your admin workstation (SSH)
add chain=forward action=accept src-address=192.168.5.9 dst-address-list=agent-box protocol=tcp dst-port=22 comment="agent: admin SSH in"
add chain=forward action=drop   dst-address-list=agent-box comment="agent: drop all other ingress"

# NOT IN THE ORIGINAL DRAFT -- added during apply, required for the router
# audit path to actually work: 192.168.99.1 is the RB5009's OWN address, so
# traffic to it never traverses the forward chain (it terminates in input).
# The "SSH / API-SSL to targets" forward rule above is a harmless no-op for
# that specific target; this input-chain rule is what actually lets the
# agent reach RouterOS's own SSH/API-SSL.
/ip firewall filter
add chain=input action=accept src-address=192.168.99.3 dst-address=192.168.99.1 protocol=tcp dst-port=22,8729 comment="agent: input RouterOS mgmt (read-only audit)" place-before=9

# IPv6: the LXC has SLAAC GUA + ULA addresses. The agent works over v4, so drop its v6 forwarding.
/ipv6 firewall address-list
add list=agent-box6 address=2001:db8:4a00:2b06:be24:11ff:feb3:21d2/128 comment="agent LXC GUA"
add list=agent-box6 address=fd12:3456:789a:99:be24:11ff:feb3:21d2/128 comment="agent LXC ULA"
/ipv6 firewall filter
add chain=forward action=drop src-address-list=agent-box6 comment="agent: drop v6 egress"
add chain=forward action=drop dst-address-list=agent-box6 comment="agent: drop v6 ingress"

# ---- PLACEMENT NOTES (for next time) ----
# The existing ruleset has a "forward: isolate vlans" rule (drop
# in-interface-list=LAN out-interface-list=LAN) and mgmtVlan99 IS a member
# of the LAN interface-list -- so "first drop" isn't good enough guidance.
# The agent: forward rules MUST sit strictly ABOVE "forward: isolate vlans"
# (verified via `/interface list member print where list=LAN`), in the same
# block as the existing per-host exceptions (wazuh agents, resolver-to-wazuh,
# etc.) that already precede it. Likewise the two v6 "agent: drop" rules
# were moved above the v6 "forward: isolate vlans" (placed right after the
# fasttrack6 rule) so they're not bypassed by connection fasttracking.
#
# Gotcha hit live: `/ip firewall filter move [find comment~"^agent:" and
# chain=forward] destination=<id>` silently reordered things in an
# unexpected way with a multi-item find + destination=<number> (admin SSH
# in / Wazuh API rules initially landed in the wrong slot, which would have
# put accept rules AFTER the catch-all drop -- always re-verify order with
# a plain `/ip firewall filter print` after any batch move, not a filtered
# print, since filtered `where comment=a or comment=b` queries were seen to
# show stale rule numbers immediately after a move). Moving rules one at a
# time with bare numeric ids (`move <num> destination=<num>`) was reliable.
# Also: the number shown in `print` is a persistent per-rule id, not a
# position -- row ORDER in the output is what determines evaluation order.
#
# ---- VERIFY (run from the LXC itself -- not done as part of this apply) ----
# curl -sS https://api.anthropic.com   (should connect)
# ping a VLAN 10 host                  (should fail)
# curl/ssh to 192.168.5.12:55000 (Wazuh API) and 192.168.99.1:8729 (RouterOS API-SSL)

# ---- FOLLOW-UP: api-ssl service enabled 2026-10-01 ----
# Verification after applying the above found api-ssl (8729) was DISABLED at
# the service level (both `api` and `api-ssl` showed RouterOS's X/disabled
# flag) -- the firewall rule allowing port 8729 was a no-op until this was
# fixed. SSH (22) was already enabled and already service-restricted to
# 192.168.5.0/28 + 192.168.99.0/28, so SSH-based audit access needed no
# change. Fixed api-ssl as follows:
#
#   /certificate add name=api-ssl-ca common-name=homelab-api-ssl-ca key-usage=key-cert-sign,crl-sign
#   /certificate sign api-ssl-ca
#   /certificate add name=api-ssl-cert common-name=RTR-HOMELAB-CN-1 key-usage=tls-server
#   /certificate sign api-ssl-cert ca=api-ssl-ca
#   /ip service set api-ssl certificate=api-ssl-cert disabled=no address=192.168.5.0/28,192.168.99.0/28
#
# Did NOT reuse the existing WiFi-CAPsMAN-CA-78YA188DESC8 cert/CA -- that's
# CAPsMAN's own, kept separate from router-admin TLS. `certificate=auto` is
# not a valid /ip service value in this RouterOS version; a real signed cert
# is required. `/certificate sign <name>` alone failed with "failure: CA not
# found" for both the CA and the leaf cert -- the leaf needed an explicit
# `ca=<ca-cert-name>` (not a boolean), and the CA itself just needed a plain
# `sign` with no `ca=` (self-signed root).
#
# STILL OPEN: the agent-ro user group and `agent` RouterOS user (per
# claude-noc-agent-setup.md step 3) do not exist yet -- SSH/API-SSL are
# reachable now, but there's no account for the agent to authenticate with.

# ---- TEMP: install-only HTTP egress, added 2026-10-01 ----
# The forward-chain lockdown only allows port 443 (HTTPS) out to WAN. Debian/
# TurnKey's default apt mirrors are typically plain HTTP (port 80), which
# would have made `apt update` in setup-agent-lxc.sh fail silently against
# the existing egress drop. Added, right before "agent: drop all other
# egress":
#
#   add chain=forward action=accept src-address-list=agent-box \
#     out-interface-list=WAN protocol=tcp dst-port=80 \
#     comment="agent: TEMP install-only HTTP out -- REMOVE after LXC base install (apt mirrors)"
#
# REMOVE THIS once setup-agent-lxc.sh has run successfully:
#   /ip firewall filter remove [find comment~"TEMP install-only HTTP"]
# Node/npm/Claude Code CLI and the agent's own ongoing operation are all
# HTTPS (443) and don't need this rule once the base install is done.

# ---- TEMP HTTP rule REMOVED 2026-10-01 ----
# LXC base install (setup-agent-lxc.sh) completed successfully -- agent user,
# Node 22.23.3, npm 10.9.9, Claude Code CLI 2.1.286, directory layout, and
# the SSH keypair all confirmed in place. Removed the temporary port-80
# egress rule:
#   /ip firewall filter remove [find comment~"TEMP install-only HTTP"]
# Forward chain is back to HTTPS-only egress for the agent box.

# ---- END-TO-END CONNECTIVITY VERIFIED 2026-10-01 ----
# From the LXC, as the agent Linux user:
#   sudo -u agent ssh -i /home/agent/.ssh/id_ed25519 agent@192.168.99.1 "/system/identity/print"
#   -> name: RTR-HOMELAB-CN-1
# Confirms the full chain works: forward-chain SSH/API-SSL rule (no-op for
# this target, as noted above) + the dedicated input-chain rule + the
# api-ssl/ssh service address restriction + the agent-ro RouterOS account's
# own address lock (192.168.99.3/32) + SSH key auth, all together.

# ---- Wazuh Indexer API egress added 2026-10-01 ----
# Greenfield Wazuh setup -- no indexer read access existed yet. The original
# firewall only opened port 55000 (Wazuh Manager API), which manages
# agents/rules/config, not alert events. Alert data for wazuh-triage lives in
# the Indexer (OpenSearch-compatible), same host, default port 9200. Added:
#   add chain=forward action=accept src-address-list=agent-box dst-address=192.168.5.12 protocol=tcp dst-port=9200 comment="agent: Wazuh Indexer API"
# placed right after "agent: HTTPS out", before "agent: drop all other egress".
# Indexer-side: still need a read-only OpenSearch internal user + role scoped
# to wazuh-alerts-* (see claude-noc-agent-setup.md for the setup commands).
