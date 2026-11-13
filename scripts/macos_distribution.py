"""macOS archive creation and disposable installation checks; never installs globally."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile


class DistributionError(RuntimeError):
    pass


def validate_product(product):
    """Keep version labels and the application's update channel in agreement."""
    version = product.get("version", "")
    if not isinstance(version, str) or not re.fullmatch(
            r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version):
        raise DistributionError("Product version must be a semantic version")
    beta = product.get("beta")
    if type(beta) is not bool or beta != ("-" in version.split("+", 1)[0]):
        raise DistributionError("Product beta flag must match its prerelease version")


def run(command):
    result = subprocess.run([str(item) for item in command], capture_output=True, text=True)
    if result.returncode:
        raise DistributionError(f"{command[0]} failed ({result.returncode}): "
                                + (result.stderr or result.stdout)[-5000:])
    return result.stdout


def save_json(destination, value):
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(destination)


def sha256(file):
    digest = hashlib.sha256()
    with file.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bundle_digest(app):
    """Include content, file modes and links; refuse links outside the bundle."""
    if app.is_symlink() or not app.is_dir():
        raise DistributionError("Application must be a real bundle directory")
    digest = hashlib.sha256()
    for item in sorted(app.rglob("*")):
        relative = item.relative_to(app).as_posix()
        mode = stat.S_IMODE(item.lstat().st_mode)
        if item.is_symlink():
            if not item.resolve().is_relative_to(app.resolve()):
                raise DistributionError("Application contains an external symbolic link: " + relative)
            value = b"link:" + os.readlink(item).encode()
        elif item.is_file():
            value = b"file:" + bytes.fromhex(sha256(item))
        elif item.is_dir():
            # Directory ownership/modes may differ when mounting a disk image.
            continue
        else:
            raise DistributionError("Unsupported file type in bundle: " + relative)
        digest.update(relative.encode() + b"\0" + str(mode).encode() + b"\0" + value)
    return digest.hexdigest()


def validate_app(app, product):
    validate_product(product)
    bundle_digest(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if "PureMacFixtureRoot" in info or info.get("CFBundleIdentifier") != product["bundle_identifier"]:
        raise DistributionError("Refusing a test fixture or mismatched application")
    for key, value in [("CFBundleName", product["name"]),
                       ("CFBundleShortVersionString", product["version"]),
                       ("CFBundleVersion", product["build"])]:
        if info.get(key) != value:
            raise DistributionError("Application metadata is stale: " + key)
    if type(info.get("SafeCleanupBeta")) is not bool or info["SafeCleanupBeta"] != product["beta"]:
        raise DistributionError("Application update channel does not match the product")
    executable_name = info.get("CFBundleExecutable", "")
    if not executable_name or Path(executable_name).name != executable_name:
        raise DistributionError("Invalid bundle executable")
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise DistributionError("Application executable is missing or not executable")
    # The current source build has one executable and no embedded code to sign.
    for folder in ["Frameworks", "PlugIns", "XPCServices", "Library/LoginItems"]:
        nested = app / "Contents" / folder
        if nested.exists() and any(nested.iterdir()):
            raise DistributionError("Nested code requires an explicit signing plan: " + folder)
    if any(item != executable for item in executable.parent.iterdir()):
        raise DistributionError("Unexpected executable in application bundle")
    return info


def make_zip(app, archive):
    if archive.exists():
        raise DistributionError("Existing archive retained: " + str(archive))
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])


def make_dmg(app, destination, workspace, product, preview=False):
    validate_product(product)
    if destination.exists():
        raise DistributionError("Existing disk image retained: " + str(destination))
    layout = Path(tempfile.mkdtemp(prefix="disk-layout-", dir=workspace))
    shutil.copytree(app, layout / app.name, symlinks=True)
    (layout / "Applications").symlink_to("/Applications", target_is_directory=True)
    notice = "本地验证包：未获 Apple 发行签名和公证，不作为正式下载。\n\n" if preview else ""
    edition = "免费内测版本" if product["beta"] else "免费版本"
    (layout / "安装说明.txt").write_text(
        notice + "轻盘 · Cachora\n\n"
        "将 Cachora.app 拖入 Applications。复制完成后推出磁盘映像，再从应用程序中打开。\n"
        "首次使用请先看扫描结果和实际路径，复核选择后再清理。\n"
        "移入恢复区仍占磁盘空间；恢复不会覆盖同名文件。永久删除无法撤销。\n"
        f"当前为{edition} {product['version']}（Build {product['build']}），仅适用于 Apple Silicon（M 系列）Mac。\n\n"
        "Drag Cachora.app to Applications, eject this image, then open the installed app.\n"
        "Review paths before cleanup. Recovery copies still consume space.\n"
        "Restore never overwrites an existing item; permanent deletion is irreversible.\n\n"
        "Privacy and verification: https://github.com/" + product["github_repository"] + "\n",
        encoding="utf-8")
    run(["/usr/bin/hdiutil", "create", "-volname", "Cachora Preview" if preview else "Cachora",
         "-srcfolder", layout, "-fs", "HFS+", "-format", "UDZO", destination])


def assess_app(app, notarized=False):
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    if notarized:
        run(["/usr/bin/xcrun", "stapler", "validate", app])
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])


def verify_installers(app, archive, dmg, workspace, product, notarized=False):
    """Extract/copy only into this attempt's disposable directories, never /Applications."""
    expected = bundle_digest(app)
    results = {}
    check = Path(tempfile.mkdtemp(prefix="install-check-", dir=workspace))
    extracted = check / "zip-unpacked"
    extracted.mkdir()
    run(["/usr/bin/ditto", "-x", "-k", archive, extracted])
    unpacked_app = extracted / app.name
    validate_app(unpacked_app, product)
    if bundle_digest(unpacked_app) != expected:
        raise DistributionError("ZIP round trip changed application content or permissions")
    assess_app(unpacked_app, notarized)
    results["zip_round_trip"] = "passed"
    run(["/usr/bin/hdiutil", "verify", dmg])
    mount = check / "mounted-image"
    mount.mkdir()
    run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg])
    try:
        link = mount / "Applications"
        if not link.is_symlink() or os.readlink(link) != "/Applications":
            raise DistributionError("Disk image Applications link is invalid")
        if not (mount / "安装说明.txt").is_file():
            raise DistributionError("Disk image installation instructions are missing")
        copied = check / "Applications" / app.name
        copied.parent.mkdir()
        run(["/usr/bin/ditto", mount / app.name, copied])
        validate_app(copied, product)
        if bundle_digest(copied) != expected:
            raise DistributionError("DMG installation changed application content or permissions")
        assess_app(copied, notarized)
        results["dmg_install_into_disposable_applications"] = "passed"
        results["actual_applications_folder_modified"] = False
    finally:
        run(["/usr/bin/hdiutil", "detach", mount])
    results["notarization_and_gatekeeper"] = "passed" if notarized else "not run: local preview"
    return results
