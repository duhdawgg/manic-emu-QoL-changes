#!/usr/bin/env python3
"""Get everything needed to sign an IPA from Apple, using an App Store Connect API key.

What it does, in order:
  1. Loads the signing certificate + private key saved by an earlier run (encrypted), or
     creates a new certificate if there is none, or the saved one was revoked or expired.
  2. Registers the iPhone(s) listed in DEVICE_UDID (if not registered yet).
  3. For the app and each of its extensions: registers a bundle ID, turns on the
     memory capabilities where Apple allows it, and makes a fresh provisioning profile
     that includes every registered iPhone.

Inputs (environment):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY  App Store Connect API key (.p8 contents)
  DEVICE_UDID          one or more UDIDs, separated by commas, spaces or new lines
  PROFILE_KIND         "development" (default) or "adhoc"
  NEW_BUNDLE_ID        optional; default is <original id>.<team id>
  ASC_API_BASE         optional; for tests only

Usage: prepare.py <app.ipa> <state file (read+write)> <output dir>

Output dir gets: key.pem, cert.pem, profiles/*.mobileprovision, info.json
"""

import base64
import hashlib
import json
import os
import plistlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import jwt
from cryptography import x509
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

API = os.environ.get("ASC_API_BASE", "https://api.appstoreconnect.apple.com")
PROFILE_PREFIX = "QoL Signer"

# Entitlement -> App Store Connect capability. These are requested for the main app.
# If Apple's API refuses one, the run continues and says how to turn it on by hand.
MAIN_APP_CAPABILITIES = ["INCREASED_MEMORY_LIMIT", "EXTENDED_VIRTUAL_ADDRESSING"]


def log(msg):
    print(msg, flush=True)


def warn(msg):
    # GitHub Actions shows these as yellow warnings on the run page.
    print(f"::warning::{msg}", flush=True)


def fail(msg):
    print(f"::error::{msg}", flush=True)
    sys.exit(1)


# ---------------------------------------------------------------- App Store Connect API

class ASC:
    def __init__(self, key_id, issuer_id, private_key):
        self.key_id, self.issuer_id, self.private_key = key_id, issuer_id, private_key
        self._token, self._token_time = None, 0

    def token(self):
        now = int(time.time())
        if not self._token or now - self._token_time > 600:
            self._token = jwt.encode(
                {"iss": self.issuer_id, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                self.private_key, algorithm="ES256",
                headers={"kid": self.key_id, "typ": "JWT"})
            self._token_time = now
        return self._token

    def call(self, method, path, body=None, ok_missing=False):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token())
        if data is not None:
            req.add_header("Content-Type", "application/json")
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                text = e.read().decode(errors="replace")
                if e.code == 404 and ok_missing:
                    return None
                if e.code in (429, 500, 502, 503) and attempt < 3:
                    time.sleep(5 * (attempt + 1))
                    continue
                raise APIError(e.code, text, method, path)
            except urllib.error.URLError:
                if attempt < 3:
                    time.sleep(5 * (attempt + 1))
                    continue
                raise

    def get_all(self, path):
        items, url = [], path
        while url:
            page = self.call("GET", url)
            items += page.get("data", [])
            url = page.get("links", {}).get("next")
        return items


class APIError(Exception):
    def __init__(self, code, text, method, path):
        self.code, self.text = code, text
        try:
            errs = json.loads(text).get("errors", [])
            self.detail = "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}" for e in errs) or text
        except ValueError:
            self.detail = text
        super().__init__(f"{method} {path} -> HTTP {code}: {self.detail}")


# ---------------------------------------------------------------- saved certificate

def state_cipher(private_key_text):
    # The saved certificate key is encrypted with a key derived from the API key secret,
    # so the file is useless without the repo's secrets.
    digest = hashlib.sha256(b"qol-signer-state-v1\n" + private_key_text.strip().encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def load_state(path, cipher):
    if not os.path.exists(path):
        return {}
    try:
        return json.loads(cipher.decrypt(open(path, "rb").read()))
    except (InvalidToken, ValueError):
        warn("Saved signing data could not be read (API key changed?). A new certificate will be made.")
        return {}


def save_state(path, cipher, state):
    with open(path, "wb") as f:
        f.write(cipher.encrypt(json.dumps(state).encode()))


def cert_still_valid(asc, cert_id):
    res = asc.call("GET", f"/v1/certificates/{cert_id}", ok_missing=True)
    if not res:
        return False
    exp = res["data"]["attributes"].get("expirationDate", "")
    # Renew a week early so an app signed today doesn't stop opening in a few days.
    if exp and time.strptime(exp[:10], "%Y-%m-%d") < time.gmtime(time.time() + 7 * 86400):
        return False
    return True


def get_certificate(asc, state, kind):
    cert_type = "DEVELOPMENT" if kind == "development" else "DISTRIBUTION"
    saved = state.get(cert_type)
    if saved and cert_still_valid(asc, saved["id"]):
        log(f"Using saved {cert_type} certificate {saved['id']}")
        return saved

    log(f"Creating a new {cert_type} certificate")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "QoL Signer")]))
           .sign(key, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    try:
        res = asc.call("POST", "/v1/certificates", {"data": {
            "type": "certificates",
            "attributes": {"certificateType": cert_type, "csrContent": csr_pem}}})
    except APIError as e:
        if e.code == 409:
            fail("Apple says you already have the maximum number of certificates of this type. "
                 "Open developer.apple.com > Account > Certificates, revoke one you don't use "
                 f"(only revoke one you made with this tool or don't need), then run again. Apple's message: {e.detail}")
        raise
    der = base64.b64decode(res["data"]["attributes"]["certificateContent"])
    saved = {
        "id": res["data"]["id"],
        "cert_pem": x509.load_der_x509_certificate(der).public_bytes(serialization.Encoding.PEM).decode(),
        "key_pem": key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                     serialization.NoEncryption()).decode(),
    }
    state[cert_type] = saved
    return saved


def team_id_from_cert(cert_pem):
    cert = x509.load_pem_x509_certificate(cert_pem.encode())
    ou = cert.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME)
    if not ou:
        fail("Could not read the team ID from the certificate.")
    return ou[0].value


# ---------------------------------------------------------------- devices

def parse_udids(text):
    udids = [u.strip() for u in re.split(r"[\s,;]+", text or "") if u.strip()]
    for u in udids:
        # iPhone XS and later: 8 hex, dash, 16 hex. Older: 40 hex.
        if not re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40}", u):
            fail(f"DEVICE_UDID has something that isn't a UDID: '{u}'. "
                 "It should look like 00008150-001A2B3C4D5E6F70.")
    return udids


def register_devices(asc, udids):
    registered = asc.get_all("/v1/devices?limit=200&filter[platform]=IOS")
    known = {d["attributes"]["udid"].upper(): d for d in registered}
    for n, udid in enumerate(udids, 1):
        if udid.upper() in known:
            d = known[udid.upper()]
            if d["attributes"].get("status") != "ENABLED":
                warn(f"iPhone {udid} is registered but disabled on your developer account; enable it there.")
            continue
        log(f"Registering iPhone {udid}")
        res = asc.call("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {
            "name": f"iPhone {n}" if len(udids) > 1 else "My iPhone",
            "udid": udid, "platform": "IOS"}}})
        known[udid.upper()] = res["data"]
    enabled = [d["id"] for d in known.values() if d["attributes"].get("status", "ENABLED") == "ENABLED"]
    if not enabled:
        fail("No enabled iPhone on your developer account. Set the DEVICE_UDID secret.")
    return enabled


# ---------------------------------------------------------------- the IPA

def read_bundles(ipa_path):
    """Returns [(path inside zip, Info.plist dict)], main app first."""
    with zipfile.ZipFile(ipa_path) as z:
        names = z.namelist()
        apps = sorted({m.group(1) for n in names if (m := re.match(r"(Payload/[^/]+\.app)/", n))})
        if len(apps) != 1:
            fail(f"This doesn't look like an IPA: expected one Payload/*.app, found {apps or 'none'}.")
        app = apps[0]
        out = []
        for n in sorted(names):
            if not n.endswith("/Info.plist"):
                continue
            bundle = n[: -len("/Info.plist")]
            if bundle == app or re.fullmatch(re.escape(app) + r"/(PlugIns|Extensions)/[^/]+\.appex", bundle):
                out.append((bundle, plistlib.loads(z.read(n))))
        out.sort(key=lambda b: b[0] != app)
        if not out or out[0][0] != app:
            fail("The app's Info.plist is missing from the IPA.")
        return out


# ---------------------------------------------------------------- bundle IDs and profiles

def find_bundle_id(asc, identifier):
    q = urllib.parse.quote(identifier)
    for b in asc.get_all(f"/v1/bundleIds?limit=200&filter[identifier]={q}"):
        # The filter matches prefixes too, so check the exact value.
        if b["attributes"]["identifier"] == identifier:
            return b
    return None


def ensure_bundle_id(asc, identifier, name):
    b = find_bundle_id(asc, identifier)
    if b:
        return b
    log(f"Registering bundle ID {identifier}")
    clean = re.sub(r"[^A-Za-z0-9 ]", " ", name).strip() or "App"
    try:
        res = asc.call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": identifier, "name": f"{clean[:40]} QoL", "platform": "IOS"}}})
    except APIError as e:
        if e.code == 409:
            fail(f"Apple won't register the bundle ID '{identifier}' (another team probably owns it). "
                 f"Run again and set a different bundle ID. Apple's message: {e.detail}")
        raise
    return res["data"]


def ensure_capabilities(asc, bundle, wanted):
    have = {c["attributes"]["capabilityType"]
            for c in asc.get_all(f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities")}
    missing_by_hand = []
    for cap in wanted:
        if cap in have:
            continue
        try:
            asc.call("POST", "/v1/bundleIdCapabilities", {"data": {
                "type": "bundleIdCapabilities", "attributes": {"capabilityType": cap},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}}}}})
            log(f"Turned on {cap} for {bundle['attributes']['identifier']}")
        except APIError as e:
            missing_by_hand.append(cap)
            log(f"Could not turn on {cap} through the API: {e.detail}")
    return missing_by_hand


def make_profile(asc, bundle, cert_id, device_ids, kind):
    identifier = bundle["attributes"]["identifier"]
    name = f"{PROFILE_PREFIX} {kind} {identifier}"[:100]
    # Delete old profiles from this tool so the new one includes current devices/capabilities.
    for p in asc.get_all(f"/v1/bundleIds/{bundle['id']}/profiles?limit=200"):
        if p["attributes"].get("name", "").startswith(PROFILE_PREFIX):
            asc.call("DELETE", f"/v1/profiles/{p['id']}", ok_missing=True)
    res = asc.call("POST", "/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": name,
                       "profileType": "IOS_APP_DEVELOPMENT" if kind == "development" else "IOS_APP_ADHOC"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            "devices": {"data": [{"type": "devices", "id": d} for d in device_ids]}}}})
    return base64.b64decode(res["data"]["attributes"]["profileContent"])


# ---------------------------------------------------------------- main

def main():
    if len(sys.argv) != 4:
        fail(__doc__)
    ipa, state_path, out_dir = sys.argv[1:]

    for var in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY", "DEVICE_UDID"):
        if not os.environ.get(var, "").strip():
            fail(f"The repository secret {var} is not set. See SIGNING.md.")
    p8 = os.environ["ASC_PRIVATE_KEY"].strip().replace("\\n", "\n")
    if "BEGIN PRIVATE KEY" not in p8:
        fail("ASC_PRIVATE_KEY should be the whole text of the .p8 file, "
             "including the -----BEGIN PRIVATE KEY----- line.")
    kind = os.environ.get("PROFILE_KIND", "development").strip().lower() or "development"
    if kind not in ("development", "adhoc"):
        fail("PROFILE_KIND must be 'development' or 'adhoc'.")

    bundles = read_bundles(ipa)
    main_info = bundles[0][1]
    old_main = main_info.get("CFBundleIdentifier", "")
    app_name = main_info.get("CFBundleDisplayName") or main_info.get("CFBundleName") or "App"
    log(f"App: {app_name} ({old_main}), {len(bundles) - 1} extension(s)")

    asc = ASC(os.environ["ASC_KEY_ID"].strip(), os.environ["ASC_ISSUER_ID"].strip(), p8)
    cipher = state_cipher(p8)
    state = load_state(state_path, cipher)
    cert = get_certificate(asc, state, kind)
    save_state(state_path, cipher, state)  # save right away so a new cert is never lost
    team = team_id_from_cert(cert["cert_pem"])
    log(f"Team ID: {team}")

    device_ids = register_devices(asc, parse_udids(os.environ["DEVICE_UDID"]))

    new_main = os.environ.get("NEW_BUNDLE_ID", "").strip() or f"{old_main}.{team}"
    if not re.fullmatch(r"[A-Za-z0-9.\-]+", new_main) or ".." in new_main:
        fail(f"'{new_main}' isn't a valid bundle ID (letters, numbers, dots and dashes only).")

    os.makedirs(os.path.join(out_dir, "profiles"), exist_ok=True)
    by_hand = []
    for i, (path, info) in enumerate(bundles):
        old_id = info.get("CFBundleIdentifier", "")
        # Same rule zsign uses when it renames extensions: replace the old main ID inside it.
        new_id = new_main if i == 0 else old_id.replace(old_main, new_main)
        if i and new_id == old_id:
            new_id = f"{new_main}.{old_id.rsplit('.', 1)[-1]}"
            warn(f"Extension {old_id} doesn't start with the app's ID; zsign may not rename it.")
        bundle = ensure_bundle_id(asc, new_id, app_name if i == 0 else path.rsplit("/", 1)[-1])
        if i == 0:
            by_hand += ensure_capabilities(asc, bundle, MAIN_APP_CAPABILITIES)
        profile = make_profile(asc, bundle, cert["id"], device_ids, kind)
        fname = os.path.join(out_dir, "profiles", f"{i:02d}-{new_id}.mobileprovision")
        with open(fname, "wb") as f:
            f.write(profile)
        log(f"Profile ready: {new_id} ({len(device_ids)} device(s))")

    with open(os.path.join(out_dir, "key.pem"), "w") as f:
        f.write(cert["key_pem"])
    with open(os.path.join(out_dir, "cert.pem"), "w") as f:
        f.write(cert["cert_pem"])
    with open(os.path.join(out_dir, "info.json"), "w") as f:
        json.dump({
            "name": app_name,
            "bundle_id": new_main,
            "original_bundle_id": old_main,
            "version": str(main_info.get("CFBundleShortVersionString") or main_info.get("CFBundleVersion") or "1.0"),
            "build": str(main_info.get("CFBundleVersion") or ""),
            "team_id": team,
            "kind": kind,
            "capabilities_to_enable_by_hand": by_hand,
        }, f, indent=2)

    if by_hand:
        warn("Turn these on by hand for full emulator memory: developer.apple.com > Account > "
             f"Identifiers > {new_main} > tick {', '.join(by_hand)} > Save, then run this workflow again.")


if __name__ == "__main__":
    main()
