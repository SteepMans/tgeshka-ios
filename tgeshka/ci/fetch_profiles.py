"""Fetches (or creates) App Store provisioning profiles for TGeshka and its
extensions through the App Store Connect API and writes them to
<out>/profiles/*.mobileprovision for Make.py --codesigningInformationPath.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, DIST_CERT_ID.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

SUFFIXES = ["", ".Share", ".NotificationContent", ".NotificationService", ".SiriIntents", ".Widget", ".BroadcastUpload"]
API = "https://api.appstoreconnect.apple.com"


def token():
    now = int(time.time())
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main():
    out = sys.argv[1]
    base = os.environ["BUNDLE_ID"]
    cert = os.environ["DIST_CERT_ID"]
    os.makedirs(out + "/profiles", exist_ok=True)
    for suffix in SUFFIXES:
        ident = base + suffix
        code, d = call("GET", "/v1/bundleIds?filter[identifier]=" + ident + "&limit=5")
        ids = [x for x in d.get("data", []) if x["attributes"]["identifier"] == ident]
        if not ids:
            sys.exit("bundle id %s is not registered" % ident)
        bundle = ids[0]["id"]
        name = "TGeshka AppStore " + ident
        code, d = call("GET", "/v1/bundleIds/%s/profiles?limit=50" % bundle)
        profiles = [p for p in d.get("data", []) if p["attributes"]["name"] == name and p["attributes"]["profileState"] == "ACTIVE"]
        if profiles and os.environ.get("RECREATE_PROFILES") == "1":
            for p in profiles:
                call("DELETE", "/v1/profiles/" + p["id"])
            profiles = []
        if profiles:
            code, d = call("GET", "/v1/profiles/" + profiles[0]["id"])
            content = d["data"]["attributes"]["profileContent"]
        else:
            code, d = call("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                                                            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                                                                              "certificates": {"data": [{"type": "certificates", "id": cert}]}}}})
            if code != 201:
                sys.exit("profile %s: %s %s" % (ident, code, [e.get("detail") for e in d.get("errors", [])]))
            content = d["data"]["attributes"]["profileContent"]
        with open("%s/profiles/%s.mobileprovision" % (out, ident), "wb") as f:
            f.write(base64.b64decode(content))
        print("profile", ident, "ok")


if __name__ == "__main__":
    main()
