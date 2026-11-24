# Complaint page — deploy notes

Zammad's Form channel is now **enabled** (Admin → Channels → Form): group = Users,
title "Household Complaint", inline (non-modal), name/email/message fields.
Submissions create real tickets; Zammad auto-creates a customer from the email,
so you can see whether it was your wife or son complaining.

## Deploy `complaint.html` on the caddy VM (10.20.0.7)

Serve it from the **same origin** as Zammad to avoid CORS — a `/complaint` path
on the existing `zammad.home.arpa` site:

```bash
# on the caddy VM
sudo mkdir -p /srv/complaint
sudo cp complaint.html /srv/complaint/
```

Change the existing Caddyfile site block to:

```caddyfile
zammad.home.arpa {
    handle /complaint* {
        root * /srv/complaint
        rewrite * /complaint.html
        file_server
    }
    handle {
        reverse_proxy 10.20.0.8:8080   # your existing Zammad upstream line
    }
    # keep whatever tls/logging directives you already have
}
```

```bash
sudo systemctl reload caddy
```

Family URL: **https://zammad.home.arpa/complaint**
(Bookmark it on their devices / put it on the fridge as a QR code.)

## Notes

- jQuery loads from code.jquery.com (internet required). To make it fully
  LAN-only, download jquery-3.6.0.min.js into /srv/complaint and change the
  script src in complaint.html to `/complaint/jquery-3.6.0.min.js` (adjust the
  rewrite: use `try_files {path} /complaint.html` instead of `rewrite`).
- Zammad rate-limits form submissions per IP (defaults ~20/day) — plenty for a
  household, but worth knowing if a teenager discovers automation.
- New tickets land in group Users, state new — they'll show in "Unassigned &
  Open Tickets".
- Test after deploy: open the URL, file a test complaint, confirm the ticket
  appears, then close it.
