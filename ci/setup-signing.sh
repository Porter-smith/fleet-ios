#!/usr/bin/env bash
# One-time (and yearly) setup for the ad hoc workflow. Runs on Linux or macOS
# with openssl, python3 and an authenticated gh; no Mac or Xcode needed.
#
#   ci/setup-signing.sh DIR [owner/repo]
#
# DIR is a private folder outside any repo (made 0700) holding the App Store
# Connect key. Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8) and
# APPLE_TEAM_ID first. The script:
#   1. makes an RSA key and CSR in DIR and an Apple Distribution certificate
#      from it through the API, unless DIR/dist.p12 already exists;
#   2. packs them into DIR/dist.p12 with a random password;
#   3. sets the repo's Actions secrets from those files (nothing is printed).
# Optional: IOS_DEVICE_UDIDS (comma-separated) is set as a secret too.
set -euo pipefail

DIR="${1:?usage: setup-signing.sh DIR [owner/repo]}"
REPO="${2:-Porter-smith/fleet-ios}"
HERE="$(cd "$(dirname "$0")" && pwd)"
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH APPLE_TEAM_ID; do
  [ -n "${!v:-}" ] || { echo "set $v" >&2; exit 1; }
done
umask 077
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

if [ ! -f dist.p12 ]; then
  openssl genrsa -out dist.key 2048 2>/dev/null
  openssl req -new -key dist.key -out dist.csr -subj "/CN=Fleet CI Distribution/C=US"
  python3 -I "$HERE/asc.py" create-cert --csr dist.csr --out dist.cer
  openssl x509 -inform DER -in dist.cer -out dist.pem
  openssl rand -hex 24 | tr -d '\n' > dist.p12.password
  # 3DES and a SHA-1 MAC: the formats macOS `security import` accepts.
  openssl pkcs12 -export -inkey dist.key -in dist.pem -out dist.p12 \
    -passout file:dist.p12.password -name "Fleet CI Distribution" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
fi
openssl x509 -in dist.pem -noout -subject -enddate

gh secret set APPLE_TEAM_ID -R "$REPO" --body "$APPLE_TEAM_ID"
gh secret set ASC_KEY_ID -R "$REPO" --body "$ASC_KEY_ID"
gh secret set ASC_ISSUER_ID -R "$REPO" --body "$ASC_ISSUER_ID"
gh secret set ASC_KEY_P8 -R "$REPO" < "$ASC_KEY_PATH"
base64 < dist.p12 | tr -d '\n' | gh secret set DIST_CERT_P12 -R "$REPO"
gh secret set DIST_CERT_PASSWORD -R "$REPO" < dist.p12.password
if [ -n "${IOS_DEVICE_UDIDS:-}" ]; then
  gh secret set IOS_DEVICE_UDIDS -R "$REPO" --body "$IOS_DEVICE_UDIDS"
fi
gh secret list -R "$REPO"
