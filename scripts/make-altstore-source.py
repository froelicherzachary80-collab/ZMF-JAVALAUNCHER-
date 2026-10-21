#!/usr/bin/env python3
"""Writes an AltStore / SideStore source (apps.json) describing one IPA.

Usage: make-altstore-source.py <out.json> <version> <ipa path> <ipa url> <repo url> <icon url> [prerelease]
"""
import datetime
import json
import os
import sys

out, version, ipa, ipa_url, repo_url, icon_url = sys.argv[1:7]
pre = len(sys.argv) > 7 and sys.argv[7] == "prerelease"
size = os.path.getsize(ipa)
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
description = (
    "Independent, unofficial launcher for Minecraft: Java Edition on iPhone. "
    "Version manager, Fabric mod manager, Microsoft sign-in, server list and ZMF Voice "
    "(proximity voice + rooms). Not affiliated with Mojang or Microsoft. "
    "Requires your own Minecraft: Java Edition account. See the project page for current limitations."
)
version_entry = {
    "version": version,
    "date": date,
    "localizedDescription": ("Preview build. " if pre else "") + f"See {repo_url}/releases for notes.",
    "downloadURL": ipa_url,
    "size": size,
    "minOSVersion": "17.0",
}
source = {
    "name": "ZMF Java Launcher",
    "identifier": "dev.zmf.javalauncher.source",
    "website": repo_url,
    "apps": [
        {
            "name": "ZMF Java",
            "bundleIdentifier": "dev.zmf.javalauncher",
            "developerName": "ZMF",
            "subtitle": "Unofficial Minecraft: Java Edition launcher",
            "localizedDescription": description,
            "iconURL": icon_url,
            "tintColor": "54D978",
            "category": "games",
            # legacy (AltStore 1.x) fields
            "version": version,
            "versionDate": date,
            "downloadURL": ipa_url,
            "size": size,
            # current format
            "versions": [version_entry],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSMicrophoneUsageDescription": "ZMF Voice: lets nearby ZMF players and your voice rooms hear you.",
                    "NSLocalNetworkUsageDescription": "Join Minecraft servers on your local network by address.",
                },
            },
        }
    ],
    "news": [],
}
with open(out, "w") as f:
    json.dump(source, f, indent=2)
print(f"wrote {out} ({version}, {size} bytes)")
