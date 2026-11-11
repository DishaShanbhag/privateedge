"""Compute one SHA-256 over every test-set file, so the freeze can be verified later.

Usage: python eval/hash_testset.py data/test/
Files are hashed in sorted path order; README.md and TESTSET_SHA256 are skipped.
"""
import hashlib
import sys
from pathlib import Path

SKIP = {"README.md", "TESTSET_SHA256"}


def hash_dir(root: Path) -> str:
    h = hashlib.sha256()
    files = sorted(p for p in root.rglob("*") if p.is_file() and p.name not in SKIP)
    if not files:
        raise SystemExit(f"No test files found in {root}")
    for p in files:
        h.update(p.relative_to(root).as_posix().encode())
        h.update(b"\0")
        h.update(p.read_bytes())
        h.update(b"\0")
    return h.hexdigest()


if __name__ == "__main__":
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "data/test")
    print(hash_dir(root))
