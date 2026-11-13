#!/usr/bin/env python3
"""Check the public source surface and optionally export a clean source archive."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build-local"
FILES = ["README.md", "LICENSE", "THIRD-PARTY-NOTICES.md", "PRIVACY.md", "CONTRIBUTING.md",
         ".gitignore", "project.yml", "docs/BETA-RELEASE.md", "docs/RELEASE-STATUS.md", "docs/MACOS-DISTRIBUTION.md",
         "docs/BUILDING.md", "docs/screenshots/build18-duplicates.jpg",
         "docs/screenshots/build18-cleanup-review.jpg", "docs/screenshots/build18-recovery.jpg",
         "release/product.json", "release/RELEASE-NOTES.md"]
FOLDERS = ["PureMac", "PureMacTests", "PureMac.xcodeproj", "scripts", ".github"]


def public_files():
    result = [ROOT / name for name in FILES]
    for folder in FOLDERS:
        for path in (ROOT / folder).rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            if any(part in {"__pycache__", "xcuserdata", ".DS_Store"} for part in path.parts):
                continue
            if path.name in {".DS_Store", "SECRETS.md"} or path.suffix in {".p8", ".p12", ".cer", ".mobileprovision", ".pyc"}:
                continue
            result.append(path)
    return sorted(set(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--source-archive", action="store_true")
    args = parser.parse_args()
    product = json.loads((ROOT / "release/product.json").read_text())
    files = public_files()
    problems = []
    for path in files:
        if not path.is_file():
            problems.append(str(path.relative_to(ROOT)) + ": missing")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        else:
            if str(Path.home()) in content:
                problems.append(str(path.relative_to(ROOT)) + ": personal home path")
            if re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}", content):
                problems.append(str(path.relative_to(ROOT)) + ": credential-shaped content")
    if product["github_repository"].lower() == "momenbasel/puremac" or not product["github_repository"]:
        problems.append("Independent GitHub repository is not configured")
    if "Signed%20%26%20Notarized" in (ROOT / "README.md").read_text():
        problems.append("README claims an unverified signing state")
    for path in [ROOT / "project.yml", ROOT / ".github/workflows/release.yml", ROOT / "scripts/release-local.sh"]:
        if re.search(r"H3WXHVTP97|Moamen Basel|AuthKey_", path.read_text()):
            problems.append(str(path.relative_to(ROOT)) + ": upstream signing identity")
    digest = hashlib.sha256()
    for path in files:
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes())
    BUILD.mkdir(exist_ok=True)
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "product": product,
              "public_files": len(files), "public_source_sha256": digest.hexdigest(),
              "problems": problems, "source_checks_passed": not problems,
              "notarization": "requires separate successful signing and notarization record"}
    if args.source_archive and not problems:
        archive = BUILD / (product["name"] + "-" + product["version"] + "-source.zip")
        prefix = product["slug"] + "-" + product["version"]
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            for path in files:
                output.write(path, prefix + "/" + str(path.relative_to(ROOT)))
        report["source_archive"] = archive.name
        report["source_archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    (BUILD / "public-readiness.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if problems:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
