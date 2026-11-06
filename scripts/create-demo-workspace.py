#!/usr/bin/env python3
"""Create disposable fixtures; never accepts a real home or an existing target."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

repo = Path(__file__).resolve().parent.parent
root = repo / "build-local/test-workspaces" / ("cachora-demo-" + str(uuid.uuid4()))
root.mkdir(parents=True, exist_ok=False)
(root / ".puremac-fixture.json").write_text(json.dumps({"purpose": "PureMac disposable recovery tests", "root": str(root)}))
files = {
    "Library/Caches/01-Round-trip/visible.bin": b"DISPOSABLE-CACHE\n" * 4096,
    "Library/Caches/01-Round-trip/.hidden/payload.bin": b"HIDDEN-DISPOSABLE\n" * 1024,
    "Library/Caches/02-Conflict/original.bin": b"ORIGINAL-KEEP-ON-CONFLICT\n" * 2048,
    "Library/Caches/03-Confirmation/disposable.bin": b"DISPOSABLE-CONFIRMATION\n" * 1024,
    "Library/Caches/04-Unselected/keep.bin": b"UNSELECTED-KEEP\n" * 1024,
    "Documents/protected.txt": b"TEST-DOCUMENT-DO-NOT-CHANGE",
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
(root / "outside-home").mkdir()
(root / "outside-home/preserve.txt").write_bytes(b"OUTSIDE-BOUNDARY-KEEP")
(root / "baseline.json").write_text(json.dumps(baseline, indent=2) + "\n")
(repo / "build-local/gui-workspace.txt").write_text(str(root) + "\n")
print(root)
