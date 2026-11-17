#!/usr/bin/env python3
"""Ask App Store Connect whether the build actually landed.

altool exits non-zero on a 409 from Apple's delivery service even when the binary
has already been accepted, and blind-retrying makes it worse ("the entity has been
replaced by another entity"). So its exit code is advisory and this is the source
of truth.

Three outcomes, kept distinct because they need different responses and conflating
them is how a release reports green while shipping stale code:

  FRESH    a build with this number exists and was uploaded just now -> success.
  STALE    a build with this number exists but was uploaded long ago. Apple DROPS
           an upload whose CFBundleVersion already exists, silently, while altool
           reports success. This is that case, and it is a hard failure: the new
           binary is nowhere and the old one is still newest.
  ABSENT   no build with this number exists yet. Usually Apple's ingestion queue
           running slow; occasionally a delivery that was accepted and then
           rejected during processing. Either way it is unverified, so it fails —
           but it is reported as unverified rather than as a failed upload,
           because claiming the upload failed is itself a guess.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import jwt

APP_ID = sys.argv[1]
WANTED = str(sys.argv[2])
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
P8 = os.path.expanduser("~/private_keys/AuthKey_%s.p8" % KEY_ID)

# 25 minutes. Apple's queue regularly takes more than ten, and a verify that
# gives up early produces false alarms that train everyone to ignore it.
ATTEMPTS = 50
GAP = 30
# A build uploaded longer ago than this is not the one this run just sent.
STALE_AFTER = 45 * 60


def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900,
                       "aud": "appstoreconnect-v1"},
                      open(P8).read(), algorithm="ES256",
                      headers={"kid": KEY_ID, "typ": "JWT"})


def builds():
    url = ("https://api.appstoreconnect.apple.com/v1/builds"
           "?filter[app]=%s&limit=50&sort=-uploadedDate" % APP_ID)
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + token())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read()).get("data", [])
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
        detail = ""
        if isinstance(e, urllib.error.HTTPError):
            detail = e.read()[:300].decode(errors="replace")
        print("ASC query failed: %s %s" % (e, detail))
        return []


def age_seconds(attributes):
    raw = attributes.get("uploadedDate")
    if not raw:
        return None
    try:
        when = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - when).total_seconds()


for attempt in range(ATTEMPTS):
    found = [b for b in builds()
             if str(b["attributes"].get("version")) == WANTED]
    if found:
        b = found[0]
        attrs = b["attributes"]
        age = age_seconds(attrs)
        if age is not None and age > STALE_AFTER:
            print("FAILED: a build numbered %s exists at Apple but was uploaded "
                  "%.0f minutes ago, so it is not the one this run just sent.\n"
                  "Apple drops an upload whose build number already exists, "
                  "without reporting an error. The binary from this run is not "
                  "on App Store Connect and the older build is still the newest."
                  % (WANTED, age / 60))
            sys.exit(1)
        print("Build %s is present at Apple: id=%s processing=%s uploaded=%s"
              % (WANTED, b["id"], attrs.get("processingState"),
                 attrs.get("uploadedDate")))
        sys.exit(0)
    print("attempt %d/%d: build %s not visible yet" % (attempt + 1, ATTEMPTS, WANTED))
    time.sleep(GAP)

print("UNVERIFIED: build %s has not appeared at App Store Connect after %d minutes.\n"
      "altool may have reported the upload succeeded — check the log above for a "
      "Delivery UUID. If it is there, Apple accepted the binary and its ingestion "
      "queue is slow, and the build will usually show up on its own; if it is not, "
      "the upload did not happen. This run cannot tell which, so it is not calling "
      "the release done." % (WANTED, (ATTEMPTS * GAP) // 60))
sys.exit(1)
