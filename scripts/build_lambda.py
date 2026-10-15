#!/usr/bin/env python3
"""Build the ingest Lambda package (arm64, Python 3.13).

Downloads Linux arm64 wheels, adds the kiro_ingest package and the RDS CA
bundle, and writes a deterministic zip: fixed timestamps, sorted entries, so
the same source always produces the same hash and OpenTofu only redeploys
the function when something actually changed.

  python3 scripts/build_lambda.py            -> build/kiro-ingest.zip
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "ingest"
BUILD = ROOT / "build"
PKG = BUILD / "lambda-pkg"
OUT = BUILD / "kiro-ingest.zip"

PYTHON_VERSION = "3.13"
PLATFORM = "manylinux2014_aarch64"
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> int:
    shutil.rmtree(PKG, ignore_errors=True)
    PKG.mkdir(parents=True)

    run([
        sys.executable, "-m", "pip", "install", "--quiet",
        "--platform", PLATFORM, "--implementation", "cp",
        "--python-version", PYTHON_VERSION, "--only-binary=:all:",
        "--target", str(PKG), "-r", str(SRC / "requirements.txt"),
    ])

    shutil.copytree(SRC / "kiro_ingest", PKG / "kiro_ingest",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))

    ca = ROOT / "certs" / "rds-global-bundle.pem"
    if b"BEGIN CERTIFICATE" not in ca.read_bytes():
        raise SystemExit(f"{ca} does not look like a PEM bundle")
    shutil.copy(ca, PKG / "kiro_ingest" / "rds-ca-bundle.pem")

    # Not needed at runtime and not deterministic.
    for junk in list(PKG.rglob("__pycache__")) + list(PKG.glob("*.dist-info/RECORD")):
        shutil.rmtree(junk) if junk.is_dir() else junk.unlink()
    for bindir in PKG.glob("bin"):
        shutil.rmtree(bindir)

    OUT.unlink(missing_ok=True)
    files = sorted(p for p in PKG.rglob("*") if p.is_file())
    with zipfile.ZipFile(OUT, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(PKG).as_posix(), FIXED_TIME)
            mode = 0o755 if path.suffix == ".so" else 0o644
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, path.read_bytes())

    digest = hashlib.sha256(OUT.read_bytes()).hexdigest()
    print(f"wrote {OUT.relative_to(ROOT)}  {OUT.stat().st_size / 1024:.0f} KiB  {len(files)} files  sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
