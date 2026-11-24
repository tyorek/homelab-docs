#!/usr/bin/env bash
#
# Scrubs the pre-sanitization pibox commit(s) from tyorek/General history.
#
# It collapses the three pibox-related commits:
#     60af050  Add pibox ... (ORIGINAL, contains real domain + internal IPs)
#     66fe818  Delete pibox-smb-kerberos-ntp-incident.md
#     d5ec0e7  Sanitize incident write-up
# into a SINGLE clean commit on top of the last good commit (b604894, "Create README.md"),
# then force-pushes. The real-data blob never appears in the new history.
#
# HOW TO RUN (Git Bash):
#     cd "/c/Users/labadmin/Nextcloud/Documents/.claude workspace"
#     bash scrub-pibox-history.sh
#
# Your browser GitHub login (Git Credential Manager) supplies the push credentials.

set -euo pipefail

REPO_URL="https://github.com/tyorek/General.git"
BASE="b604894"                 # last clean commit before the pibox uploads (Create README.md)
EXPECTED_TIP="d5ec0e7"         # current sanitized tip; abort if main has moved since
NEWMSG="Add pibox SMB/Kerberos/NTP incident write-up (sanitized)"
WORK="$(mktemp -d)"

echo ">> Cloning fresh copy into: $WORK"
git clone --quiet "$REPO_URL" "$WORK/General"
cd "$WORK/General"

TIP="$(git rev-parse --short HEAD)"
echo ">> Current main tip: $TIP"
if [ "$TIP" != "$EXPECTED_TIP" ]; then
  echo "!! main is at $TIP but expected $EXPECTED_TIP."
  echo "!! Something changed on GitHub since this script was made. Aborting so nothing is lost."
  exit 1
fi

# Confirm the base commit really exists in history before touching anything.
git cat-file -e "${BASE}^{commit}"

echo ">> Collapsing the pibox commits into one clean commit on top of $BASE ..."
git reset --soft "$BASE"
git add -A
git commit --quiet -m "$NEWMSG"

echo
echo ">> New history (top 5):"
git log --oneline -5
echo
echo ">> Checking the pibox write-up for any real values ..."
if git grep -niE 'homelab|192\.168\.20' -- pibox-smb-kerberos-ntp-incident.md ; then
  echo "!! Sensitive strings still present in the pibox file. Aborting BEFORE push."
  exit 1
fi
echo "   Clean — no domain or internal IPs in the pibox write-up."

echo
read -r -p ">> Force-push rewritten main to GitHub? This is DESTRUCTIVE. Type YES: " CONFIRM
if [ "$CONFIRM" = "YES" ]; then
  git push --force-with-lease origin main
  echo
  echo ">> Done. main now has one clean pibox commit."
  echo ">> Note: the old commits (60af050 / 66fe818 / d5ec0e7) become 'dangling' and stay"
  echo "   reachable by their SHA until GitHub garbage-collects them. For guaranteed"
  echo "   immediate removal, contact GitHub Support and ask them to run gc on the repo."
else
  echo ">> Aborted. Nothing was pushed."
fi
