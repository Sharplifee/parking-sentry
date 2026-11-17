#!/usr/bin/env python3
"""Pick a build number that cannot collide with one Apple already holds.

The run number alone is not safe. Apple silently DROPS an upload whose
CFBundleVersion already exists for that app version — no error from altool, which
reports success, and the previous build stays newest. That is how a release can
report green while shipping stale code, and it has happened on another app in
this account.

Apple's highest visible build is not safe on its own either: a build that was
uploaded minutes ago and is still being ingested does not appear in the API at
all, so "highest + 1" hands back a number that is already taken by something in
flight.

So: take the maximum of both. The run number only ever increases, which makes the
result monotonic on its own; Apple's highest is what rescues the case where the
run number has fallen behind the numbers already on the store.

Prints the chosen number on stdout and nothing else, so the workflow can capture
it directly. Never fails the build — if App Store Connect cannot be reached, the
run-number path still produces a usable, increasing number.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

APP_ID = os.environ.get("ASC_APP_ID", "")
KEY_ID = os.environ.get("ASC_KEY_ID", "")
ISSUER = os.environ.get("ASC_ISSUER_ID", "")
RUN = int(os.environ.get("GITHUB_RUN_NUMBER", "0") or 0)


def log(*a):
    # stderr, so stdout stays machine-readable for the caller.
    print(*a, file=sys.stderr)


def apple_highest():
    if not (APP_ID and KEY_ID and ISSUER):
        log("no ASC credentials in env; skipping Apple lookup")
        return 0
    try:
        import jwt
    except ImportError:
        log("pyjwt not installed; skipping Apple lookup")
        return 0

    key_pem = ""
    key_path = os.path.expanduser("~/private_keys/AuthKey_%s.p8" % KEY_ID)
    if os.path.exists(key_path):
        key_pem = open(key_path).read()
    elif os.environ.get("ASC_KEY_P8"):
        # This step runs before the upload step writes the key to disk, so the
        # base64 secret is the normal path here, not the fallback.
        import base64
        try:
            key_pem = base64.b64decode(os.environ["ASC_KEY_P8"]).decode()
        except Exception as e:
            log("could not decode ASC_KEY_P8 (%s); skipping Apple lookup" % e)
            return 0
    if not key_pem:
        log("no ASC private key available; skipping Apple lookup")
        return 0

    now = int(time.time())
    token = jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key_pem, algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"})

    url = ("https://api.appstoreconnect.apple.com/v1/builds"
           "?filter[app]=%s&limit=50&sort=-uploadedDate" % APP_ID)
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read()).get("data", [])
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
        log("Apple lookup failed (%s); falling back" % e)
        return 0

    numbers = []
    for b in data:
        v = b.get("attributes", {}).get("version")
        try:
            numbers.append(int(str(v)))
        except (TypeError, ValueError):
            continue
    highest = max(numbers) if numbers else 0
    log("Apple's highest visible build: %s (from %d records)" % (highest, len(data)))
    return highest


def main():
    run_based = RUN + 100
    highest = apple_highest()
    chosen = max(run_based, highest + 1)
    log("run-based=%d  apple+1=%d  -> %d" % (run_based, highest + 1, chosen))
    print(chosen)


if __name__ == "__main__":
    main()
