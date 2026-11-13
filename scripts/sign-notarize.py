#!/usr/bin/env python3
"""Prepare an installer preview or use an existing Developer ID and stored notary profile."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from macos_distribution import (DistributionError, assess_app, bundle_digest, make_dmg,
                                make_zip, run, save_json, sha256, validate_app, verify_installers)

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build-local"


def identities():
    output = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    return [{"fingerprint": m[1], "name": m[2]} for m in re.finditer(
        r'\b([A-Fa-f0-9]{40})\s+"(Developer ID Application: [^"\n]+)"', output)]


def select_identity(available, requested=None):
    selected = available if not requested else [item for item in available
        if requested == item["name"] or requested.upper() == item["fingerprint"].upper()]
    if len(selected) != 1:
        raise DistributionError("Select exactly one valid Developer ID Application identity")
    return selected[0]


def validate_build(app, product):
    validate_app(app, product)
    old_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    sdk = old_sdk if old_sdk.exists() else Path(run(["/usr/bin/xcrun", "--show-sdk-path"]).strip())
    sources = sorted(str(item) for item in (ROOT / "PureMac").rglob("*.swift"))
    digest = hashlib.sha256((str(sdk) + "\n" + "\n".join(sources)).encode())
    for source in sources:
        digest.update(Path(source).read_bytes())
    saved = BUILD / "app-source-sha256.txt"
    if not saved.exists() or digest.hexdigest() != saved.read_text().strip():
        raise DistributionError("Application sources changed; rebuild before packaging")
    executable = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    if run(["/usr/bin/lipo", "-archs", app / "Contents/MacOS" / executable]).strip() != "arm64":
        raise DistributionError("This installer supports verified arm64 builds only")
    assess_app(app)


def preflight(product):
    available = identities()
    tools = {name: subprocess.run(["/usr/bin/xcrun", "--find", name],
                                  capture_output=True).returncode == 0
             for name in ["notarytool", "stapler", "codesign", "ditto", "hdiutil", "lipo"]}
    reasons = []
    if not available:
        reasons.append("Install your own Developer ID Application certificate and matching private key")
    reasons.extend(name + " is unavailable" for name, present in tools.items() if not present)
    try:
        validate_build(BUILD / (product["name"] + ".app"), product)
    except (DistributionError, OSError, ValueError) as error:
        reasons.append(str(error))
    report = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "developer_id_identities": len(available), "identities": available,
              "tools": tools, "preflight_passed": not reasons,
              "status": "blocked" if reasons else "ready_for_stored_notary_profile",
              "reasons": reasons, "notarized": False, "distribution_ready": False}
    BUILD.mkdir(exist_ok=True)
    save_json(BUILD / "signing-preflight.json", report)
    return report


def new_attempt(parent, product):
    for key in ["name", "version", "build"]:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", product[key]):
            raise DistributionError("Unsafe product metadata: " + key)
    folder = parent / (product["version"] + "-build" + product["build"])
    folder.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="attempt-", dir=folder))


def prepare_preview(product):
    app = BUILD / (product["name"] + ".app")
    validate_build(app, product)
    attempt = new_attempt(BUILD / "installer-preview", product)
    copied = attempt / app.name
    shutil.copytree(app, copied, symlinks=True)
    run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
         "--sign", "-", copied])
    stem = product["name"] + "-" + product["version"] + "-build" + product["build"] + "-arm64-local-preview"
    archive, dmg = attempt / (stem + ".zip"), attempt / (stem + ".dmg")
    make_zip(copied, archive)
    make_dmg(copied, dmg, attempt, product, preview=True)
    checks = verify_installers(copied, archive, dmg, attempt, product)
    report = {"status": "local_installer_preview", "notarized": False, "distribution_ready": False,
              "product": product, "attempt": str(attempt), "checks": checks,
              "artifacts": {item.name: sha256(item) for item in [archive, dmg]}}
    (attempt / "SHA256SUMS.txt").write_text("".join(digest + "  " + name + "\n"
        for name, digest in report["artifacts"].items()))
    save_json(attempt / "verification.json", report)
    save_json(BUILD / "installer-preview-latest.json", report)
    return report


def submit_once(attempt, manifest, phase, archive):
    if phase in manifest:
        return
    manifest[phase] = {"archive": archive.name, "sha256": sha256(archive), "submitted_sha256": sha256(archive),
                       "id": None, "status": "Submitting"}
    save_json(attempt / "state.json", manifest)
    result = json.loads(run(["/usr/bin/xcrun", "notarytool", "submit", archive,
        "--keychain-profile", manifest["notary_profile"], "--output-format", "json"]))
    submission_id = result.get("id", "")
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", submission_id):
        raise DistributionError("No submission ID returned; no public installer generated")
    manifest[phase].update(id=submission_id, status=result.get("status", "In Progress"))
    save_json(attempt / "state.json", manifest)


def ensure_accepted(attempt, manifest, phase):
    record = manifest[phase]
    if Path(record["archive"]).name != record["archive"]:
        raise DistributionError("Submission archive must stay inside its release attempt")
    if not record.get("id"):
        raise DistributionError("Submission outcome unknown. Check notarytool history before retrying; "
                                "this attempt will not resubmit automatically.")
    if sha256(attempt / record["archive"]) != record["sha256"]:
        raise DistributionError("Submitted archive changed; refusing to continue")
    if record.get("status") != "Accepted":
        result = json.loads(run(["/usr/bin/xcrun", "notarytool", "info", record["id"],
            "--keychain-profile", manifest["notary_profile"], "--output-format", "json"]))
        if result.get("id") != record["id"]:
            raise DistributionError("Apple returned a mismatched submission ID")
        record["status"] = result.get("status", "Unknown")
        save_json(attempt / "state.json", manifest)
    if record["status"] in {"Invalid", "Rejected"}:
        run(["/usr/bin/xcrun", "notarytool", "log", record["id"], "--keychain-profile",
             manifest["notary_profile"], attempt / (phase + "-notary-log.json")])
        raise DistributionError("Apple rejected " + phase + "; inspect its notarization log")
    if record["status"] != "Accepted":
        manifest["status"] = "waiting_for_apple_" + phase
        save_json(attempt / "state.json", manifest)
        return False
    return True


def verify_developer_signature(app, identity):
    assess_app(app)
    result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)],
                            capture_output=True, text=True, check=True)
    detail = result.stdout + result.stderr
    team = re.search(r"\(([A-Z0-9]{10})\)$", identity["name"])
    if (not team or "TeamIdentifier=" + team[1] not in detail
            or "Authority=" + identity["name"] not in detail
            or "runtime" not in detail or "Timestamp=" not in detail or "Signature=adhoc" in detail):
        raise DistributionError("Require own Developer ID, hardened runtime and secure timestamp")


def finish_release(attempt, manifest):
    product = manifest["product"]
    app = attempt / (product["name"] + ".app")
    validate_app(app, product)
    if bundle_digest(app) != manifest["app_digest"]:
        raise DistributionError("Staged application changed since signing")
    verify_developer_signature(app, manifest["identity"])
    submission = attempt / "notary-submission.zip"
    if not submission.exists():
        make_zip(app, submission)
    submit_once(attempt, manifest, "app", submission)
    if not ensure_accepted(attempt, manifest, "app"):
        return manifest
    if not manifest.get("app_stapled"):
        run(["/usr/bin/xcrun", "stapler", "staple", app])
        assess_app(app, notarized=True)
        manifest.update(app_stapled=True, app_digest=bundle_digest(app))
        save_json(attempt / "state.json", manifest)
    stem = product["name"] + "-" + product["version"] + "-arm64"
    dmg = attempt / (stem + ".dmg")
    if "dmg" not in manifest:
        if not dmg.exists():
            make_dmg(app, dmg, attempt, product)
        run(["/usr/bin/hdiutil", "verify", dmg])
        run(["/usr/bin/codesign", "--force", "--timestamp", "--sign",
             manifest["identity"]["fingerprint"], dmg])
        run(["/usr/bin/codesign", "--verify", "--strict", dmg])
    submit_once(attempt, manifest, "dmg", dmg)
    if not ensure_accepted(attempt, manifest, "dmg"):
        return manifest
    if not manifest.get("dmg_stapled"):
        run(["/usr/bin/xcrun", "stapler", "staple", dmg])
        manifest["dmg_stapled"] = True
        manifest["dmg"]["sha256"] = sha256(dmg)
        save_json(attempt / "state.json", manifest)
    run(["/usr/bin/xcrun", "stapler", "validate", dmg])
    run(["/usr/bin/codesign", "--verify", "--strict", dmg])
    run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg])
    archive = attempt / (stem + ".zip")
    if not archive.exists():
        make_zip(app, archive)
    checks = verify_installers(app, archive, dmg, attempt, product, notarized=True)
    report = {"status": "notarized", "notarized": True, "distribution_ready": True,
              "product": product, "identity": manifest["identity"], "checks": checks,
              "submissions": {key: manifest[key]["id"] for key in ["app", "dmg"]},
              "artifacts": {item.name: sha256(item) for item in [archive, dmg]}}
    dist = attempt / "dist"
    if dist.exists():
        raise DistributionError("Existing public output retained")
    ready = attempt / "publish-ready"
    ready.mkdir(exist_ok=True)
    for artifact in [archive, dmg]:
        shutil.copy2(artifact, ready / artifact.name)
    (ready / "SHA256SUMS.txt").write_text("".join(digest + "  " + name + "\n"
        for name, digest in report["artifacts"].items()))
    save_json(ready / "verification.json", report)
    ready.rename(dist)
    manifest.update(status="notarized", distribution_ready=True, output=str(dist))
    save_json(attempt / "state.json", manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--preflight", action="store_true")
    action.add_argument("--prepare", action="store_true", help="Build/test a local unsigned installer preview")
    action.add_argument("--run", action="store_true")
    action.add_argument("--resume", type=Path, help="Resume an existing release attempt without resubmitting")
    parser.add_argument("--identity", help="Exact Developer ID name or fingerprint; auto-selects if unique")
    parser.add_argument("--notary-profile", help="Existing local keychain profile, such as Cachora-notary")
    args = parser.parse_args()
    product = json.loads((ROOT / "release/product.json").read_text())
    try:
        if args.prepare:
            print(json.dumps(prepare_preview(product), ensure_ascii=False, indent=2))
            return 0
        if args.resume:
            attempt = args.resume.absolute()
            allowed = (BUILD / "release").resolve()
            if attempt.is_symlink() or not attempt.resolve().is_relative_to(allowed):
                raise DistributionError("Resume must stay below build-local/release")
            manifest = json.loads((attempt / "state.json").read_text())
            if manifest["product"] != product:
                raise DistributionError("Product version changed; preserve the previous attempt")
            if manifest.get("distribution_ready"):
                raise DistributionError("This attempt already completed; output retained")
        else:
            report = preflight(product)
            if not args.run:
                print(json.dumps(report, ensure_ascii=False, indent=2))
                return 0 if report["preflight_passed"] else 2
            if not report["preflight_passed"]:
                raise DistributionError("Signing stopped: " + "; ".join(report["reasons"]))
            if not args.notary_profile:
                raise DistributionError("Configure a stored notary profile; do not pass passwords here")
            identity = select_identity(report["identities"], args.identity)
            run(["/usr/bin/xcrun", "notarytool", "history", "--keychain-profile",
                 args.notary_profile, "--output-format", "json"])
            attempt = new_attempt(BUILD / "release", product)
            app = attempt / (product["name"] + ".app")
            shutil.copytree(BUILD / app.name, app, symlinks=True)
            run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign",
                 identity["fingerprint"], "--entitlements", ROOT / "PureMac/PureMac.entitlements", app])
            verify_developer_signature(app, identity)
            manifest = {"product": product, "identity": identity, "notary_profile": args.notary_profile,
                        "status": "signed", "distribution_ready": False, "app_digest": bundle_digest(app)}
            save_json(attempt / "state.json", manifest)
        print("Release attempt: " + str(attempt), flush=True)
        result = finish_release(attempt, manifest)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if not result.get("distribution_ready"):
            print("Apple is processing the submission. Resume with --resume " + str(attempt))
            return 3
        return 0
    except (DistributionError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("Distribution stopped: " + str(error))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
