#!/usr/bin/env python3
"""Validate build-time update configuration and write plist values safely."""
import base64
import os
import plistlib
import re
import sys
from urllib.parse import urlparse

PRODUCTION_FEED = "https://github.com/BIGWOO/minascp-app/releases/latest/download/appcast.xml"

def configuration(mode):
    version = os.environ["MINASCP_VERSION"]
    build = os.environ["MINASCP_BUILD"]
    key = os.environ.get("MINASCP_UPDATE_PUBLIC_KEY", "")
    feed = os.environ["MINASCP_FEED_URL"]
    testing = os.environ.get("MINASCP_UPDATE_TEST") == "1"
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("MINASCP_VERSION must be major.minor.patch")
    if not re.fullmatch(r"\d+(\.\d+){0,2}", build):
        raise ValueError("MINASCP_BUILD must contain one to three numeric components")
    if key and len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Update public key must be a base64 Ed25519 public key")
    if mode == "release" and not key:
        raise ValueError("Release requires MINASCP_UPDATE_PUBLIC_KEY; never use a placeholder key")
    url = urlparse(feed)
    if testing:
        if url.scheme not in ("http", "https") or url.hostname not in ("127.0.0.1", "localhost"):
            raise ValueError("Test feed must be loopback HTTP(S)")
    elif feed != PRODUCTION_FEED:
        raise ValueError("Production feed must use the fixed GitHub Release URL")
    return version, build, key, feed, testing

if __name__ == "__main__":
    try:
        action, target = sys.argv[1:]
        version, build, key, feed, testing = configuration(target if action == "validate" else "plist")
        if action == "plist":
            with open(target, "rb") as handle:
                info = plistlib.load(handle)
            info.update(CFBundleShortVersionString=version, CFBundleVersion=build,
                        CFBundleDevelopmentRegion="zh_TW", CFBundleLocalizations=["zh_TW"],
                        SUFeedURL=feed, SUEnableAutomaticChecks=False,
                        SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                        SUEnableSystemProfiling=False, SUShowReleaseNotes=True,
                        SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
            if key:
                info["SUPublicEDKey"] = key
            if testing:
                info["CFBundleIdentifier"] = "com.mina.scp.update-test"
                info["MinaUpdateTestBuild"] = True
                info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
            with open(target, "wb") as handle:
                plistlib.dump(info, handle)
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
