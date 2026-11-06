#!/usr/bin/env python3
"""Build a separately identified local .app without installing or changing macOS."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build-local"


def run(command, log_name):
    log_path = BUILD / log_name
    with log_path.open("w", encoding="utf-8") as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log_path.read_text(encoding="utf-8")[-10000:])
        raise SystemExit(f"Command failed ({result.returncode}); see {log_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=pathlib.Path)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--package-only", action="store_true", help="Package an already compiled local executable")
    parser.add_argument("--fixture-root", type=pathlib.Path, help="Use only a marked disposable workspace below build-local/test-workspaces")
    parser.add_argument("--skip-tests", action="store_true", help="Build after a UI-only change without rerunning unchanged backend tests")
    args = parser.parse_args()
    product = json.loads((ROOT / "release/product.json").read_text(encoding="utf-8"))
    app_name = product["name"]
    if args.tests_only and args.skip_tests:
        parser.error("--tests-only and --skip-tests cannot be combined")
    BUILD.mkdir(exist_ok=True)
    fixture = None
    if args.fixture_root:
        fixture = args.fixture_root.absolute()
        allowed = (BUILD / "test-workspaces").resolve()
        if fixture.resolve(strict=True) != fixture or not fixture.is_relative_to(allowed):
            raise SystemExit("Fixture must be a real directory below build-local/test-workspaces")
        marker = json.loads((fixture / ".puremac-fixture.json").read_text())
        if marker != {"purpose": "PureMac disposable recovery tests", "root": str(fixture)}:
            raise SystemExit("Fixture marker is invalid; refusing to fall back to real user files")
    # CLT's macOS 27 SwiftUI headers require an Xcode-only macro plugin.
    # The installed 26.5 SDK supports this app's macOS 13 baseline with CLT.
    clt_sdk = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    sdk = args.sdk or (clt_sdk if clt_sdk.exists() else pathlib.Path(
        subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()))
    flags = ["/usr/bin/swiftc", "-parse-as-library", "-swift-version", "5",
             "-target", "arm64-apple-macosx13.0", "-sdk", str(sdk),
             "-module-cache-path", str(BUILD / "module-cache-26")]
    sources = sorted(str(path) for path in (ROOT / "PureMac").rglob("*.swift"))
    digest = hashlib.sha256((str(sdk) + "\n" + "\n".join(sources)).encode())
    for source in sources:
        digest.update(pathlib.Path(source).read_bytes())
    source_digest = digest.hexdigest()

    if not args.package_only and not args.skip_tests:
        tests = BUILD / "scan-regressions"
        run(flags + [str(ROOT / path) for path in [
            "PureMac/Models/ScanDiagnostics.swift",
            "PureMac/Logic/Utilities/DirectoryMeasurement.swift",
            "PureMacTests/DirectoryMeasurementTests.swift",
        ]] + ["-o", str(tests)], "scan-regressions-build.log")
        run([str(tests)], "scan-regressions.log")
        print((BUILD / "scan-regressions.log").read_text(encoding="utf-8"), end="")
        core_tests = BUILD / "recovery-store-tests"
        core_sources = [str(ROOT / path) for path in [
            "PureMac/Logic/Utilities/RecoveryFileSystem.swift", "PureMac/Services/RecoveryStore.swift",
            "PureMacTests/RecoveryStoreTests.swift",
        ]]
        run(flags + ["-D", "PUREMAC_RECOVERY_STORE_TEST_RUNNER"] + core_sources + ["-o", str(core_tests)], "recovery-store-tests-build.log")
        run([str(core_tests)], "recovery-store-tests.log")
        print((BUILD / "recovery-store-tests.log").read_text(encoding="utf-8"), end="", flush=True)
        integration = BUILD / "cleanup-recovery-integration-tests"
        run(flags + ["-module-name", "PureMac", "-D", "PUREMAC_RECOVERY_INTEGRATION_TEST_RUNNER"] + sources + [
            str(ROOT / "PureMacTests/RecoveryStoreTests.swift"),
            str(ROOT / "PureMacTests/CleaningRecoveryIntegrationTests.swift"), "-o", str(integration),
        ], "cleanup-recovery-integration-build.log")
        run([str(integration)], "cleanup-recovery-integration.log")
        print((BUILD / "cleanup-recovery-integration.log").read_text(encoding="utf-8"), end="", flush=True)
        release_tests = BUILD / "release-readiness-tests"
        run(flags + ["-module-name", "PureMac", "-D", "PUREMAC_RELEASE_TEST_RUNNER"] + sources + [
            str(ROOT / "PureMacTests/RecoveryStoreTests.swift"),
            str(ROOT / "PureMacTests/ReleaseReadinessTests.swift"), "-o", str(release_tests),
        ], "release-readiness-build.log")
        run([str(release_tests)], "release-readiness.log")
        print((BUILD / "release-readiness.log").read_text(encoding="utf-8"), end="", flush=True)
    if args.tests_only:
        return

    app = BUILD / (app_name + ("Fixture.app" if fixture else ".app"))
    contents = app / "Contents"
    resources = contents / "Resources"
    executable = contents / "MacOS" / "PureMac"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    if not args.package_only:
        run(flags + ["-module-name", "PureMac"] + sources + ["-o", str(executable)], "app-build.log")
        (BUILD / "app-source-sha256.txt").write_text(source_digest)
    elif fixture:
        if (BUILD / "app-source-sha256.txt").read_text() != source_digest:
            raise SystemExit("Sources changed; build and test the updated application first")
        shutil.copy2(BUILD / (app_name + ".app") / "Contents/MacOS/PureMac", executable)
    elif not executable.exists():
        raise SystemExit("No local executable exists; run without --package-only first")

    with (ROOT / "PureMac/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    info.update({
        "CFBundleExecutable": "PureMac", "CFBundleIdentifier": product["bundle_identifier"],
        "CFBundleName": app_name, "CFBundleDisplayName": product["chinese_name"] + " · " + app_name,
        "CFBundleShortVersionString": product["version"], "CFBundleVersion": product["build"],
        "LSMinimumSystemVersion": "13.0", "CFBundleIconFile": "BetaIcon.icns",
        "SafeCleanupBeta": True, "SafeCleanupStorageDirectory": product["storage_directory"],
        "SafeCleanupRepository": product["github_repository"], "SafeCleanupAssetPrefix": app_name,
    })
    if fixture:
        info.update({"PureMacFixtureRoot": str(fixture), "CFBundleIdentifier": product["bundle_identifier"] + ".fixture",
                     "CFBundleName": app_name + " Test", "CFBundleDisplayName": app_name + " 测试版"})
    # A development copy should not register a duplicate Finder uninstall service.
    info.pop("NSServices", None)
    with (contents / "Info.plist").open("wb") as destination:
        plistlib.dump(info, destination)
    for localization in (ROOT / "PureMac").glob("*.lproj"):
        shutil.copytree(localization, resources / localization.name, dirs_exist_ok=True)
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE.txt")
    for notice in ["THIRD-PARTY-NOTICES.md", "PRIVACY.md"]:
        if (ROOT / notice).exists():
            shutil.copy2(ROOT / notice, resources / notice)

    icon_source = ROOT / "PureMac/Assets.xcassets/BetaIcon.appiconset"
    if not icon_source.exists():
        run(["/usr/bin/swift", "-sdk", str(sdk), "-module-cache-path", str(BUILD / "module-cache-26"),
             str(ROOT / "scripts/render-beta-icon.swift"), str(icon_source)], "beta-icon-render.log")
    iconset = BUILD / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for image in json.loads((icon_source / "Contents.json").read_text())["images"]:
        if image.get("filename"):
            size = image["size"]
            scale = "@2x" if image["scale"] == "2x" else ""
            shutil.copy2(icon_source / image["filename"], iconset / f"icon_{size}{scale}.png")
    icon = resources / "BetaIcon.icns"
    cached_icon = BUILD / (app_name + ".app") / "Contents/Resources/BetaIcon.icns"
    if fixture and cached_icon.exists():
        shutil.copy2(cached_icon, icon)
    if not icon.exists() or icon.stat().st_mtime < max(p.stat().st_mtime for p in icon_source.glob("*.png")):
        run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(icon)], "icon-build.log")
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], "codesign.log")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], "codesign-verify.log")
    print(f"Built and signature-verified: {app}")


if __name__ == "__main__":
    main()
