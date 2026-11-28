#!/usr/bin/env python3
"""Add a signed app to the install page (the `apps` branch, served by GitHub Pages).

Usage: publish.py <info.json from prepare.py> <public IPA URL> <site base URL> <site dir> [icon.png]

Writes <site dir>/manifests/<bundle id>.plist (what iOS reads to install the app),
updates <site dir>/apps.json, and copies index.html next to them.
"""

import datetime
import json
import os
import plistlib
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    info_path, ipa_url, base_url, site = sys.argv[1:5]
    icon = sys.argv[5] if len(sys.argv) == 6 else ""
    info = json.load(open(info_path))
    base_url = base_url.rstrip("/") + "/"
    bid = info["bundle_id"]

    os.makedirs(os.path.join(site, "manifests"), exist_ok=True)
    os.makedirs(os.path.join(site, "icons"), exist_ok=True)

    icon_url = ""
    if icon and os.path.isfile(icon) and os.path.getsize(icon) > 0:
        shutil.copyfile(icon, os.path.join(site, "icons", f"{bid}.png"))
        icon_url = f"{base_url}icons/{bid}.png"

    assets = [{"kind": "software-package", "url": ipa_url}]
    if icon_url:
        assets += [{"kind": "display-image", "url": icon_url}, {"kind": "full-size-image", "url": icon_url}]
    manifest = {"items": [{
        "assets": assets,
        "metadata": {
            "bundle-identifier": bid,
            "bundle-version": info["version"],
            "kind": "software",
            "title": info["name"],
        },
    }]}
    with open(os.path.join(site, "manifests", f"{bid}.plist"), "wb") as f:
        plistlib.dump(manifest, f)

    apps_path = os.path.join(site, "apps.json")
    apps = json.load(open(apps_path)) if os.path.exists(apps_path) else []
    apps = [a for a in apps if a.get("bundle_id") != bid]
    apps.insert(0, {
        "name": info["name"],
        "bundle_id": bid,
        "version": info["version"],
        "build": info.get("build", ""),
        "kind": info["kind"],
        "signed": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "manifest": f"{base_url}manifests/{bid}.plist",
        "ipa": ipa_url,
        "icon": icon_url,
    })
    with open(apps_path, "w") as f:
        json.dump(apps, f, indent=2)

    shutil.copyfile(os.path.join(HERE, "site", "index.html"), os.path.join(site, "index.html"))
    # Without this file GitHub Pages runs Jekyll, which is slower and can skip files.
    open(os.path.join(site, ".nojekyll"), "w").close()
    print(f"Install page updated: {base_url}")


if __name__ == "__main__":
    main()
