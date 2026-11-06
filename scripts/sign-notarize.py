#!/usr/bin/env python3
"""Use an existing Developer ID identity and stored notary profile. No secrets are exported."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build-local"


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--identity")
    parser.add_argument("--notary-profile")
    args = parser.parse_args()
    product = json.loads((ROOT / "release/product.json").read_text())
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    count = sum("Developer ID Application:" in line for line in identities.splitlines())
    available = subprocess.run(["/usr/bin/xcrun", "--find", "notarytool"], capture_output=True).returncode == 0
    app = BUILD / (product["name"] + ".app")
    reasons = []
    if not count:
        reasons.append("No valid Developer ID Application identity in the current keychain")
    if not available:
        reasons.append("notarytool is unavailable")
    if not app.exists():
        reasons.append("Build the beta application first")
    report = {"developer_id_identities": count, "notarytool_available": available,
              "preflight_passed": not reasons, "status": "blocked" if reasons else "ready_for_credentials",
              "reasons": reasons, "notarized": False}
    BUILD.mkdir(exist_ok=True)
    output = BUILD / "signing-preflight.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    if not args.run:
        print(json.dumps(report, indent=2))
        if reasons:
            raise SystemExit(2)
        return
    if reasons:
        raise SystemExit("Signing stopped: " + "; ".join(reasons))
    if not args.identity or "Developer ID Application:" not in args.identity or not args.notary_profile:
        raise SystemExit("Provide your Developer ID identity and an existing stored notary profile")
    if not any(args.identity in line for line in identities.splitlines()):
        raise SystemExit("Requested identity was not found in the valid identity list")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("PureMacFixtureRoot") or info.get("CFBundleIdentifier") != product["bundle_identifier"]:
        raise SystemExit("Refusing to distribute a fixture or mismatched application")
    release = BUILD / "release" / product["version"]
    release.mkdir(parents=True, exist_ok=True)
    signed_app = release / app.name
    if signed_app.exists():
        raise SystemExit("Existing release application retained; select a new build version before retrying")
    shutil.copytree(app, signed_app)
    run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity,
         "--entitlements", str(ROOT / "PureMac/PureMac.entitlements"), str(signed_app)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(signed_app)])
    upload = release / "notary-submission.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(signed_app), str(upload)])
    result = json.loads(run(["/usr/bin/xcrun", "notarytool", "submit", str(upload), "--keychain-profile",
                             args.notary_profile, "--wait", "--output-format", "json"]))
    (release / "notary-result.json").write_text(json.dumps(result, indent=2) + "\n")
    if result.get("status") != "Accepted":
        raise SystemExit("Apple did not accept the notarization; no public archive generated")
    run(["/usr/bin/xcrun", "stapler", "staple", str(signed_app)])
    run(["/usr/bin/xcrun", "stapler", "validate", str(signed_app)])
    run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(signed_app)])
    archive = release / (product["name"] + "-" + product["version"] + "-arm64.zip")
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(signed_app), str(archive)])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (release / "SHA256SUMS.txt").write_text(digest + "  " + archive.name + "\n")
    report.update(status="notarized", notarized=True, archive=archive.name, sha256=digest)
    (release / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
