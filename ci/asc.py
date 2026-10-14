#!/usr/bin/env python3
"""App Store Connect API helper for Fleet's ad hoc builds. Python 3 stdlib plus
the openssl CLI (for the ES256 token), so it runs on GitHub's macOS runners and
on Linux with nothing to install.

Credentials come from the environment: ASC_KEY_ID, ASC_ISSUER_ID and either
ASC_KEY_PATH (the .p8 file) or ASC_KEY_P8 (its contents).

  asc.py create-cert --csr dist.csr --out dist.cer
      One-time: make an Apple Distribution certificate from a CSR (DER out).
  asc.py adhoc-profile --bundle-id ID --cert-serial HEX --out fleet.mobileprovision
      [--udids "UDID1,UDID2"] [--name "Fleet Ad Hoc CI"]
      Register the bundle ID and any given devices, then reuse or remake an ad
      hoc profile for that certificate and every enabled iOS device on the team.
      Prints the profile's UUID and name. Never prints UDIDs.
  asc.py devices
      Count the team's enabled iOS devices (no UDIDs printed).

Errors print Apple's error titles and details, never the token.
"""
import argparse
import base64
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig):
    """ECDSA DER signature (SEQUENCE of two INTEGERs) -> 64-byte r||s."""
    def read_len(buf, i):
        n = buf[i]
        if n < 0x80:
            return n, i + 1
        k = n & 0x7F
        return int.from_bytes(buf[i + 1:i + 1 + k], "big"), i + 1 + k

    assert sig[0] == 0x30, "not a DER sequence"
    _, i = read_len(sig, 1)
    out = b""
    for _ in range(2):
        assert sig[i] == 0x02, "not a DER integer"
        n, i = read_len(sig, i + 1)
        out += int.from_bytes(sig[i:i + n], "big").to_bytes(32, "big")
        i += n
    return out


def key_path():
    if os.environ.get("ASC_KEY_PATH"):
        return os.environ["ASC_KEY_PATH"], None
    pem = os.environ.get("ASC_KEY_P8")
    if not pem:
        sys.exit("set ASC_KEY_PATH or ASC_KEY_P8")
    fd, path = tempfile.mkstemp(suffix=".p8")
    with os.fdopen(fd, "w") as f:
        f.write(pem.strip() + "\n")
    return path, path


_token = {"value": None, "exp": 0}


def token():
    now = int(time.time())
    if _token["value"] and _token["exp"] - now > 60:
        return _token["value"]
    for var in ("ASC_KEY_ID", "ASC_ISSUER_ID"):
        if not os.environ.get(var):
            sys.exit(f"set {var}")
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200,
              "aud": "appstoreconnect-v1"}
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "."
                     + b64url(json.dumps(claims, separators=(",", ":")).encode()))
    path, tmp = key_path()
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path],
                             input=signing_input.encode(), capture_output=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        sys.exit("openssl could not sign with the API key: " + e.stderr.decode().strip()[:300])
    finally:
        if tmp:
            os.unlink(tmp)
    _token["value"] = signing_input + "." + b64url(der_to_raw(der))
    _token["exp"] = now + 1200
    return _token["value"]


def call(method, path, body=None, ok404=False):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if ok404 and e.code == 404:
            return None
        try:
            errs = json.loads(e.read()).get("errors", [])
            msg = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errs)
        except Exception:
            msg = e.reason
        sys.exit(f"App Store Connect {method} {urllib.parse.urlparse(url).path} -> {e.code}: {msg}")


def get_all(path, params=None):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    items = []
    while url:
        page = call("GET", url)
        items += page.get("data", [])
        url = page.get("links", {}).get("next")
    return items


def norm_serial(s):
    return s.upper().replace(":", "").lstrip("0")


def ensure_bundle_id(identifier):
    for b in get_all("/v1/bundleIds", {"filter[identifier]": identifier, "limit": 200}):
        if b["attributes"]["identifier"] == identifier:
            return b["id"]
    print(f"registering bundle ID {identifier}")
    r = call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": "Fleet", "platform": "IOS"}}})
    return r["data"]["id"]


def ensure_devices(udids):
    for n, udid in enumerate(udids, 1):
        found = get_all("/v1/devices", {"filter[udid]": udid, "limit": 200})
        found = [d for d in found if d["attributes"]["udid"].lower() == udid.lower()]
        if not found:
            print(f"registering device #{n}")
            call("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {
                "name": f"Fleet device {n}", "udid": udid, "platform": "IOS"}}})
        elif found[0]["attributes"]["status"] != "ENABLED":
            print(f"enabling device #{n}")
            call("PATCH", f"/v1/devices/{found[0]['id']}", {"data": {
                "type": "devices", "id": found[0]["id"], "attributes": {"status": "ENABLED"}}})


def enabled_devices():
    return [d["id"] for d in get_all("/v1/devices", {
        "filter[platform]": "IOS", "filter[status]": "ENABLED", "limit": 200})]


def find_cert(serial):
    want = norm_serial(serial)
    for c in get_all("/v1/certificates", {
            "filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION", "limit": 200}):
        if norm_serial(c["attributes"]["serialNumber"]) == want:
            return c["id"]
    sys.exit("no Apple Distribution certificate on the team matches the serial of DIST_CERT_P12")


def linked_ids(profile_id, rel):
    return {d["id"] for d in get_all(f"/v1/profiles/{profile_id}/relationships/{rel}", {"limit": 200})}


def cmd_adhoc_profile(a):
    udids = [u.strip() for u in (a.udids or "").replace("\n", ",").split(",") if u.strip()]
    bundle = ensure_bundle_id(a.bundle_id)
    ensure_devices(udids)
    cert = find_cert(a.cert_serial)
    devices = set(enabled_devices())
    if not devices:
        sys.exit("the team has no enabled iOS devices; set the IOS_DEVICE_UDIDS secret")
    print(f"{len(devices)} enabled iOS device(s) on the team")

    soon = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=14)
    profile = None
    for p in get_all("/v1/profiles", {"filter[name]": a.name, "limit": 200}):
        at = p["attributes"]
        if at["name"] != a.name:
            continue
        exp = dt.datetime.fromisoformat(at["expirationDate"].replace("Z", "+00:00"))
        fresh = (at["profileState"] == "ACTIVE" and at["profileType"] == "IOS_APP_ADHOC"
                 and exp > soon and cert in linked_ids(p["id"], "certificates")
                 and devices <= linked_ids(p["id"], "devices")
                 and call("GET", f"/v1/profiles/{p['id']}/bundleId")["data"]["id"] == bundle)
        if fresh and profile is None:
            profile = p
        else:
            print(f"deleting outdated profile {p['id']}")
            call("DELETE", f"/v1/profiles/{p['id']}", ok404=True)
    if profile is None:
        print(f"creating ad hoc profile '{a.name}'")
        profile = call("POST", "/v1/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": a.name, "profileType": "IOS_APP_ADHOC"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                "certificates": {"data": [{"type": "certificates", "id": cert}]},
                "devices": {"data": [{"type": "devices", "id": d} for d in sorted(devices)]},
            }}})["data"]
    else:
        print(f"reusing ad hoc profile '{a.name}'")
    with open(a.out, "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    print("uuid=" + profile["attributes"]["uuid"])
    print("expires=" + profile["attributes"]["expirationDate"])


def cmd_create_cert(a):
    with open(a.csr) as f:
        csr = f.read()
    r = call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr}}})
    at = r["data"]["attributes"]
    with open(a.out, "wb") as f:
        f.write(base64.b64decode(at["certificateContent"]))
    print(f"created {at['name']} (id {r['data']['id']}, expires {at['expirationDate']})")


def cmd_devices(_):
    print(f"{len(enabled_devices())} enabled iOS device(s) on the team")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create-cert")
    c.add_argument("--csr", required=True)
    c.add_argument("--out", required=True)
    c.set_defaults(fn=cmd_create_cert)
    c = sub.add_parser("adhoc-profile")
    c.add_argument("--bundle-id", required=True)
    c.add_argument("--cert-serial", required=True)
    c.add_argument("--udids", default=os.environ.get("IOS_DEVICE_UDIDS", ""))
    c.add_argument("--name", default="Fleet Ad Hoc CI")
    c.add_argument("--out", required=True)
    c.set_defaults(fn=cmd_adhoc_profile)
    c = sub.add_parser("devices")
    c.set_defaults(fn=cmd_devices)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
