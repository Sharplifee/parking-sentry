#!/usr/bin/env python3
"""Ask App Store Connect whether the build actually landed.

altool exits non-zero on a 409 from Apple's delivery service even when the
binary has already been accepted, and blind-retrying makes it worse ("the
entity has been replaced by another entity"). So the exit code is advisory;
this is the source of truth.
"""
import json, os, sys, time, urllib.request, urllib.error
import jwt

APP_ID = sys.argv[1]
WANTED = str(sys.argv[2])
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
P8 = os.path.expanduser("~/private_keys/AuthKey_%s.p8" % KEY_ID)


def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900,
                       "aud": "appstoreconnect-v1"},
                      open(P8).read(), algorithm="ES256",
                      headers={"kid": KEY_ID, "typ": "JWT"})


def builds():
    url = ("https://api.appstoreconnect.apple.com/v1/builds"
           "?filter[app]=%s&limit=20&sort=-uploadedDate" % APP_ID)
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + token())
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read()).get("data", [])
    except urllib.error.HTTPError as e:
        print("ASC query failed", e.code, e.read()[:300].decode(errors="replace"))
        return []


for attempt in range(20):
    found = [b for b in builds() if str(b["attributes"].get("version")) == WANTED]
    if found:
        b = found[0]
        print("Build %s is present at Apple: id=%s state=%s processing=%s"
              % (WANTED, b["id"], b["attributes"].get("expirationDate"),
                 b["attributes"].get("processingState")))
        sys.exit(0)
    print("attempt %d: build %s not visible yet" % (attempt + 1, WANTED))
    time.sleep(30)

print("Build %s never appeared at App Store Connect - the upload really did fail." % WANTED)
sys.exit(1)
