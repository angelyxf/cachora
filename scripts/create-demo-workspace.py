#!/usr/bin/env python3
"""Create a new disposable workspace for the Cachora test app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import uuid
import zlib

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--temporary", action="store_true", help="Keep the test app and files in a private temporary folder")
args = parser.parse_args()
build = repo / "build-local"
build.mkdir(exist_ok=True)
base = Path(tempfile.mkdtemp(prefix="cachora-fixture-", dir="/private/tmp")) if args.temporary else build
root = base / "test-workspaces" / ("cachora-demo-" + str(uuid.uuid4()))
root.mkdir(parents=True, exist_ok=False)
(root / ".puremac-fixture.json").write_text(json.dumps({"purpose": "PureMac disposable recovery tests", "root": str(root)}))


def photo(variant):
    width, height = 96, 72
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            if variant == 2:
                color = (245, 210, 40) if (x // 8 + y // 8) % 2 == 0 else (20, 35, 210)
            elif variant == 1 and x > 82 and y > 60:
                color = (210, 205, 190)
            else:
                color = (35 + x * 2, 55 + y * 2, 145)
            pixels.extend(color)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


def app_metadata(name, token):
    return plistlib.dumps({
        "CFBundlePackageType": "APPL", "CFBundleName": name,
        "CFBundleIdentifier": "org.cachora.sample." + token,
        "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
    })


copy = b"Identical test copies for the duplicate finder.\n" * 320
backup = "Library/Application Support/MobileSync/Backup/0000000000000000000000000000000000000001"
files = {
    "Library/Caches/01-Round-trip/visible.bin": b"DISPOSABLE-CACHE\n" * 4096,
    "Library/Caches/01-Round-trip/.hidden/payload.bin": b"HIDDEN-DISPOSABLE\n" * 1024,
    "Library/Caches/02-Conflict/original.bin": b"ORIGINAL-KEEP-ON-CONFLICT\n" * 2048,
    "Library/Caches/03-Confirmation/disposable.bin": b"DISPOSABLE-CONFIRMATION\n" * 1024,
    "Library/Caches/04-Unselected/keep.bin": b"UNSELECTED-KEEP\n" * 1024,
    "Documents/protected.txt": b"TEST-DOCUMENT-DO-NOT-CHANGE",
    "Documents/Sample Files/01-original.txt": copy,
    "Documents/Sample Files/Nested/02-copy.txt": copy,
    "Documents/Sample Files/03-notes.txt": b"Different content\n" * 192,
    "Downloads/old-test-file.bin": b"\x23" * (12 * 1024 * 1024),
    "Pictures/01-photo.png": photo(0),
    "Pictures/02-photo-edit.png": photo(1),
    "Pictures/03-unrelated.png": photo(2),
    "Applications/Sample Editor.app/Contents/Info.plist": app_metadata("Sample Editor", "editor"),
    "Applications/Sample Gallery.app/Contents/Info.plist": app_metadata("Sample Gallery", "gallery"),
    "Library/Preferences/org.cachora.sample.editor.plist": plistlib.dumps({"fixture": True}),
    "Library/Caches/org.cachora.sample.editor/index.bin": b"EDITOR-CACHE\n" * 1024,
    "Library/Logs/org.cachora.sample.editor.log": b"EDITOR-LOG\n" * 1024,
    "Library/Caches/org.cachora.sample.retired/index.bin": b"RETIRED-APP-CACHE\n" * 1024,
    "Library/Mail Downloads/example-attachment.txt": b"TEST MAIL DOWNLOAD\n" * 512,
    ".Trash/previously-discarded.txt": b"DISCARDABLE SAMPLE\n" * 512,
    ".ollama/logs/server.log": b"TEST AI LOG\n" * 512,
    "Library/Developer/Xcode/DerivedData/Sample/build.o": b"TEST BUILD DATA\n" * 1024,
    ".npm/_cacache/index-v5/cache.bin": b"TEST NODE CACHE\n" * 1024,
    "Library/Caches/Homebrew/downloads/test.tar.gz": b"TEST BREW CACHE\n" * 1024,
    ".docker/buildx/cache/layer.bin": b"TEST DOCKER LAYER\n" * 1024,
    "System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels/sample.bin": b"SAMPLE MODEL\n" * 1024,
    "Library/Application Support/com.apple.idleassetsd/sample.bin": b"SAMPLE WALLPAPER\n" * 1024,
    "Library/Application Support/GarageBand/sample.bin": b"SAMPLE SOUND\n" * 1024,
    "Library/Audio/Apple Loops/sample.bin": b"SAMPLE LOOP\n" * 1024,
    f"{backup}/Info.plist": plistlib.dumps({"Device Name": "Sample iPhone"}),
    f"{backup}/Manifest.plist": plistlib.dumps({"Version": "1"}),
    f"{backup}/Status.plist": plistlib.dumps({"SnapshotState": "finished"}),
    f"{backup}/Manifest.db": b"SAMPLE MANIFEST",
    f"{backup}/00/sample.bin": b"SAMPLE BACKUP DATA\n" * 512,
}
baseline = {}
for relative, data in files.items():
    path = root / "home" / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.chmod(path, 0o640)
    subprocess.run(["/usr/bin/xattr", "-w", "com.puremac.fixture", "fixture-metadata", str(path)], check=True)
    baseline[relative] = {"sha256": hashlib.sha256(data).hexdigest(), "mode": 0o640,
                          "bytes": len(data), "test_xattr": "fixture-metadata"}
os.utime(root / "home/Downloads/old-test-file.bin", (1_640_995_200, 1_640_995_200))
(root / "outside-home").mkdir()
(root / "outside-home/preserve.txt").write_bytes(b"OUTSIDE-BOUNDARY-KEEP")
(root / "baseline.json").write_text(json.dumps(baseline, indent=2) + "\n")
(build / "gui-workspace.txt").write_text(str(root) + "\n")
print(root)
