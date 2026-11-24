# PIBOX AD Trust Failure — Incident Writeup

Oct 1, 2026 · @the admin

## TL;DR

A Claude-driven Wazuh triage pipeline flagged repeated Windows logon failures on both domain controllers in the home.arpa home lab. What looked at first like routine noise from newly-joined NAS devices turned out, after live packet capture, to be a broken Kerberos machine-account trust on PIBOX, an OpenMediaVault NAS: its stored computer-account password no longer matched Active Directory's copy. A domain-rejoin using an account with rights to reset the computer object (not the account that originally joined it) restored the trust, stopping the recurring alerts and fixing a failing SMB share in the same stroke.

## Environment

The lab runs an Active Directory domain, HOME.ARPA, across two domain controllers, monitored by a Wazuh SIEM whose alerts a Claude-driven triage agent polls on a schedule and summarizes into reports.

| Host | Role | Address |
| --- | --- | --- |
| DC01 | Domain controller | 192.168.20.7 |
| DC02 | Domain controller | 192.168.20.6 |
| PIBOX | OpenMediaVault NAS, domain-joined via Samba/winbind | 192.168.5.5 |
| Wazuh indexer | SIEM alert storage, queried via a read-only `claude-agent` account | — |

PIBOX sits on a different VLAN than the domain controllers, with a separate internal DNS/management subnet (10.20.0.0/24) in between, routed through a MikroTik fabric.

## Detection

The triage agent's reports surfaced Wazuh rule 60204, "Multiple Windows Logon Failures" (level 10), firing repeatedly on both domain controllers — itself an aggregate over the underlying per-event rule 60122, which had fired 84 times. The first report coincided with two NAS devices being joined to the domain, so it was initially read as expected reauthentication noise from that process.

After a dedupe fix made the triage pipeline only resurface alert groups that were genuinely new or growing, the same alert kept reappearing well after the NAS join had finished. Pulling the underlying Windows event 4625 records directly in the Wazuh dashboard identified the real source: a computer account, `PIBOX$`, at 192.168.5.5, failing NTLM logon against both DC01 and DC02 at an almost exact 30-second interval, with status `0xC000006D` / sub status `0xC000006A` (wrong password). A separate, outwardly unrelated symptom turned out to be the same issue: a Windows client failed to open a share on PIBOX with "We can't sign you in with this credential because your domain isn't available" — the client-side face of the same broken trust.

## Investigation

Samba's own diagnostics (`wbinfo -t`, `net ads testjoin`) reported a generic `NT_STATUS_DOMAIN_CONTROLLER_NOT_FOUND` / "no logon servers available" error, which turned out to be an unhelpful stand-in for the real failure several layers down. Each candidate cause was checked and ruled out in turn before the actual one was found:

1. DNS resolution for the domain — SRV records for `_ldap._tcp.dc._msdcs.home.arpa` and A records for both DCs resolved correctly. Healthy.
2. IPv6 routing or fallback — TCP connections to port 389 succeeded over both IPv4 and IPv6 to both DCs. Healthy.
3. Clock skew — `timedatectl` showed PIBOX's clock synchronized via NTP. Healthy.
4. Static configuration — `/etc/hosts` had no stale overrides, and both `krb5.conf` (realm, KDC addresses) and `smb.conf` (realm, workgroup, `security = ads`) matched the domain correctly. Healthy.
5. Live packet capture during a `net ads testjoin` attempt — the UDP CLDAP ping to the DC succeeded, and two Kerberos exchanges completed over port 88 with responses, ruling out a simple transport or discovery failure.
6. Decoding that capture with `tshark` found the actual fault: the Kerberos AS-REQ came back with a `KRB-ERROR` of `eRR-PREAUTH-FAILED`, and the subsequent SMB2 session setup failed with NT status `0xC000006D` (`STATUS_LOGON_FAILURE`) — the same code seen in the original Wazuh alerts.

## Root Cause

PIBOX's Samba/winbind machine-trust secret had drifted out of sync with Active Directory's copy of the `PIBOX$` computer account password — almost certainly from an automatic machine-password rotation that didn't complete cleanly on the OMV/Samba side, rather than anything done to the account directly. Network, DNS, and every piece of static configuration were correct; the mismatch was purely in the stored credential itself.

| Error | Layer | Meaning |
| --- | --- | --- |
| `eRR-PREAUTH-FAILED` (24) | Kerberos AS-REQ | The KDC couldn't decrypt the pre-authentication timestamp with the key it holds for `PIBOX$` — the presented password is wrong. |
| `0xC000006D` (`STATUS_LOGON_FAILURE`) | SMB2 session setup | The downstream SMB failure caused by that same rejected credential — identical to the code in the original 4625 alerts. |

Every connection that depended on that trust failed identically: an automated process on PIBOX retrying every 30 seconds against both DCs, and a Windows client trying to reach PIBOX's own SMB share.

## Resolution

PIBOX was rejoined to the domain with `net ads join -U administrator`, resetting the `PIBOX$` computer object's password in both Active Directory and PIBOX's local secrets store, followed by a restart of `winbind`, `smbd`, and `nmbd`. `wbinfo -t` then reported the trust secret as valid.

The rejoin had to use an account with administrative rights over the computer object, not the regular domain account that originally joined PIBOX. Any authenticated domain user can create a new computer account (bounded by the default machine-account quota), but resetting an *existing* object's password is a separate, narrower right that a regular user doesn't hold by default — which is why the original account could no longer fix the trust it had originally created.

Once the trust was restored, the recurring 4625 alerts on DC01 and DC02 stopped, and the failing SMB share on PIBOX came back up.

## Follow-ups / Lessons Learned

- [ ] Delegate scoped "Reset Password" and "Validated write" rights on the computer-object OU to a dedicated or personal account, instead of reaching for the built-in Administrator account for routine machine-trust fixes.
- [ ] Confirm why PIBOX's machine password drifted in the first place — check that OMV/Samba's automatic password-change interval is actually completing, to prevent a repeat.
- [ ] Consider a detection rule tuned to the specific signature seen here — one source, one account, a fixed \~30-second retry interval — so a broken machine trust is called out distinctly from generic brute-force correlation next time.

The triage pipeline itself was also hardened along the way: a misconfigured `--allowedTools` permission rule (`Write(...)` instead of `Edit(...)`) was silently blocking report writes; report filenames are now generated deterministically in UTC instead of being left to the agent to invent; and a `state/seen.json` dedupe now limits reports to alert groups that are genuinely new or growing, rather than re-reporting the same burst on every run.
