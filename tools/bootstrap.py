#!/usr/bin/env python3
"""Download and unpack the pinned Zig nightly into `.tools/zig/`.

The exact compiler version is fixed in `toolchain.lock.json` (currently
0.18.0-dev.753+1420479be). This script resolves the right archive for the
current platform through <https://ziglang.org/download/index.json>, verifies
the SHA-256 when one is known, and extracts it so that the rest of the project
can use `.tools/zig/zig[.exe]` exactly like the README describes.

Usage:
    python tools/bootstrap.py              # install if missing / verify
    python tools/bootstrap.py --force      # re-download even if present
    python tools/bootstrap.py --version    # print the pinned version

Only the Python standard library is used; no network access is required once
`.tools/zig/` exists and matches the pinned version.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "toolchain.lock.json")
TOOLS_DIR = os.path.join(ROOT, ".tools")
ZIG_DIR = os.path.join(TOOLS_DIR, "zig")
ZIG_EXE = os.path.join(ZIG_DIR, "zig.exe" if os.name == "nt" else "zig")
INDEX_URL = "https://ziglang.org/download/index.json"
BUILD_URL = "https://ziglang.org/builds/zig-{platform}-{version}.{ext}"


def load_lock() -> dict:
    with open(LOCK, encoding="utf-8") as f:
        return json.load(f)


def platform_key() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }.get(machine, machine)
    if system == "windows":
        return f"{arch}-windows"
    if system == "darwin":
        return f"{arch}-macos"
    if system == "linux":
        return f"{arch}-linux"
    raise SystemExit(f"unsupported platform: {system} {machine}")


def installed_version() -> str | None:
    if not os.path.exists(ZIG_EXE):
        return None
    try:
        out = subprocess.run([ZIG_EXE, "version"], capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return None


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve_artifact(platform_str: str, version: str, locked_sha: str | None) -> tuple[str, str | None]:
    """Return (url, expected_sha256 or None)."""
    try:
        with urllib.request.urlopen(INDEX_URL, timeout=60) as resp:
            index = json.load(resp)
        for channel in index.values():
            if isinstance(channel, dict) and channel.get("version") == version:
                entry = channel.get(platform_str)
                if entry and entry.get("tarball"):
                    return entry["tarball"], entry.get("shasum") or locked_sha
    except Exception as exc:  # offline / index moved on: fall back to the archive URL
        print(f"note: download index unavailable ({exc}); using build archive URL")
    ext = "zip" if platform_str.endswith("windows") else "tar.xz"
    return BUILD_URL.format(platform=platform_str, version=version, ext=ext), locked_sha


def extract(archive: str, dest: str) -> None:
    os.makedirs(dest, exist_ok=True)
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as zf:
            names = zf.namelist()
            prefix = names[0].split("/")[0] + "/"
            for name in names:
                if not name.startswith(prefix):
                    continue
                rel = name[len(prefix):]
                if not rel:
                    continue
                target = os.path.join(dest, rel)
                if name.endswith("/"):
                    os.makedirs(target, exist_ok=True)
                else:
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with zf.open(name) as src, open(target, "wb") as out:
                        shutil.copyfileobj(src, out)
    else:
        with tarfile.open(archive, "r:xz") as tf:
            members = tf.getmembers()
            prefix = members[0].name.split("/")[0] + "/"
            for member in members:
                if not member.name.startswith(prefix):
                    continue
                rel = member.name[len(prefix):]
                if not rel:
                    continue
                member.name = rel
                try:
                    tf.extract(member, dest, filter="data")
                except TypeError:  # Python < 3.12 has no extraction filters
                    tf.extract(member, dest)
    if os.name != "nt":
        os.chmod(os.path.join(dest, "zig"), 0o755)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="re-download even if the pinned version is installed")
    ap.add_argument("--version", action="store_true", help="print the pinned Zig version and exit")
    args = ap.parse_args()

    lock = load_lock()
    zig = lock["zig"]
    version = zig["version"]
    if args.version:
        print(version)
        return 0

    have = installed_version()
    if have == version and not args.force:
        print(f"Zig {version} already installed at {ZIG_EXE}")
        return 0
    if have is not None and have != version and not args.force:
        print(f"found Zig {have}, want {version}: reinstalling")

    platform_str = platform_key()
    locked_sha = zig.get("sha256_" + platform_str.replace("-", "_"))
    url, expected = resolve_artifact(platform_str, version, locked_sha)
    print(f"downloading {url}")
    os.makedirs(TOOLS_DIR, exist_ok=True)
    fd, archive = tempfile.mkstemp(dir=TOOLS_DIR, suffix=".zip" if url.endswith(".zip") else ".tar.xz")
    os.close(fd)
    try:
        urllib.request.urlretrieve(url, archive)
        got = sha256_file(archive)
        if expected and got.lower() != expected.lower():
            raise SystemExit(f"SHA-256 mismatch: got {got}, expected {expected}")
        if not expected:
            print(f"note: no pinned SHA-256 for {platform_str}; downloaded SHA-256 is {got}")
        if os.path.isdir(ZIG_DIR):
            shutil.rmtree(ZIG_DIR)
        extract(archive, ZIG_DIR)
    finally:
        os.unlink(archive)

    have = installed_version()
    if have != version:
        raise SystemExit(f"installation failed: `zig version` reported {have!r}, expected {version!r}")
    print(f"Zig {version} installed at {ZIG_EXE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
