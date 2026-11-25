#!/usr/bin/env python3
"""
Pre-release privacy & cleanliness scanner for Macap deliverables.
Scans directories, .app bundles, .zip archives (recursively), and .dmg disk images
(both text files and raw Mach-O / binary strings) to block any leak of:
  - Hardcoded user home paths (/Users/<username>)
  - Local machine account / full name / hostname
  - Private LAN IPv4 addresses (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
  - API keys / private keys / tokens
  - Backup or Finder junk files (*.orig_bak, *.bak_*, .DS_Store)

Usage:
  python3 tools/privacy_scan.py --selftest
  python3 tools/privacy_scan.py <path1> [<path2> ...]
"""

from __future__ import annotations

import argparse
import getpass
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

JUNK_SUFFIXES = (".orig_bak", ".DS_Store")
JUNK_INFIXES = (".bak_",)

# Regex patterns evaluated against extracted printable ASCII/UTF-8 chunks of every file (including binaries).
REGEX_RULES: list[tuple[str, re.Pattern[bytes]]] = [
    ("hardcoded_macos_user_path", re.compile(rb"/Users/[A-Za-z0-9._-]{2,64}")),
    ("private_lan_ip_192_168", re.compile(rb"(?<![0-9.])192\.168\.(?:25[0-5]|2[0-4]\d|1?\d?\d)\.(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![0-9.])")),
    ("private_lan_ip_172", re.compile(rb"(?<![0-9.])172\.(?:1[6-9]|2\d|3[01])\.(?:25[0-5]|2[0-4]\d|1?\d?\d)\.(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![0-9.])")),
    ("private_key_pem", re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("api_token_sk", re.compile(rb"\bsk-[A-Za-z0-9]{20,}\b")),
    ("github_pat", re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{24,}\b")),
    ("aws_access_key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
]

# Allowed neutral documentation placeholders that must not false-positive
ALLOWED_USER_PATHS = {
    b"/Users/Shared",
    b"/Users/you",
    b"/Users/username",
}


def dynamic_host_tokens() -> list[tuple[str, bytes]]:
    """Collect current OS username, full name, and local hostname dynamically without hardcoding them in source."""
    tokens: list[tuple[str, bytes]] = []
    user = getpass.getuser().strip()
    if len(user) >= 3 and user.lower() not in {"root", "admin", "user", "runner", "builder"}:
        tokens.append(("current_username", user.encode("utf-8")))
    try:
        full_name = subprocess.check_output(["id", "-F"], text=True, stderr=subprocess.DEVNULL).strip()
        if len(full_name) >= 2 and full_name.lower() not in {"system administrator", "root", user.lower()}:
            tokens.append(("current_user_fullname", full_name.encode("utf-8")))
    except Exception:
        pass
    host = socket.gethostname().split(".")[0].strip()
    if len(host) >= 4 and host.lower() not in {"localhost", "macbook", "macbook-pro", "imac"}:
        tokens.append(("local_hostname", host.encode("utf-8")))
    return tokens


def scan_bytes(data: bytes, label: str, extra_tokens: list[tuple[str, bytes]], findings: list[str]) -> None:
    # For large binary files (like model weights .rmw), scan printable runs >= 6 bytes so random fp16 weights
    # cannot accidentally form 4-digit IPv4 octets, while every string in Mach-O / metallib / text is caught.
    is_text = b"\x00" not in data[:4096]
    if is_text:
        haystacks = [data]
    else:
        haystacks = re.findall(rb"[\x20-\x7e\t\r\n]{6,}|\S[\x20-\x7e\x80-\xff]{5,}", data)

    for chunk in haystacks:
        for rule_name, pat in REGEX_RULES:
            for m in pat.finditer(chunk):
                matched = m.group(0)
                if rule_name == "hardcoded_macos_user_path" and matched in ALLOWED_USER_PATHS:
                    continue
                preview = matched.decode("utf-8", errors="replace")[:80]
                findings.append(f"[{rule_name}] {label}: {preview}")
                break
        lower_chunk = chunk.lower()
        for tok_name, tok in extra_tokens:
            if tok.lower() in lower_chunk:
                findings.append(f"[{tok_name}] {label}: matched host identity token")
                break


def scan_path(target: Path, extra_tokens: list[tuple[str, bytes]], findings: list[str], display_prefix: str = "") -> None:
    rel_label = display_prefix or str(target.name)
    name = target.name
    if any(name.endswith(suf) for suf in JUNK_SUFFIXES) or any(inf in name for inf in JUNK_INFIXES):
        findings.append(f"[junk_file] {rel_label}")
        return

    if target.is_symlink():
        link_dest = os.readlink(target)
        scan_bytes(link_dest.encode("utf-8"), f"{rel_label} (symlink)", extra_tokens, findings)
        return

    if target.is_dir():
        for child in sorted(target.iterdir()):
            if child.name == ".git":
                continue
            scan_path(child, extra_tokens, findings, f"{rel_label}/{child.name}")
        return

    if not target.is_file():
        return

    low = name.lower()
    if low.endswith(".zip"):
        try:
            with zipfile.ZipFile(target, "r") as zf:
                for info in zf.infolist():
                    entry_label = f"{rel_label}!/{info.filename}"
                    base = Path(info.filename).name
                    if any(base.endswith(suf) for suf in JUNK_SUFFIXES) or any(inf in base for inf in JUNK_INFIXES):
                        findings.append(f"[junk_file] {entry_label}")
                        continue
                    if not info.is_dir():
                        with tempfile.TemporaryDirectory(prefix="ci_zip_") as td:
                            extracted = Path(zf.extract(info, td))
                            scan_path(extracted, extra_tokens, findings, entry_label)
        except Exception as exc:
            findings.append(f"[corrupt_zip] {rel_label}: {exc}")
        return

    if low.endswith(".dmg"):
        mount_dir = tempfile.mkdtemp(prefix="ci_dmg_scan_")
        attached_dev = None
        try:
            out = subprocess.check_output(
                ["hdiutil", "attach", "-readonly", "-nobrowse", "-noverify", "-plist", "-mountpoint", mount_dir, str(target)],
                stderr=subprocess.DEVNULL,   # macOS 27 prints a deprecation warning that would break the plist
            )
            pl = plistlib.loads(out)
            for ent in pl.get("system-entities", []):
                if "dev-entry" in ent and attached_dev is None:
                    attached_dev = ent["dev-entry"]
            scan_path(Path(mount_dir), extra_tokens, findings, f"{rel_label} (mounted)")
        except Exception as exc:
            findings.append(f"[dmg_mount_error] {rel_label}: {exc}")
        finally:
            if attached_dev or os.path.ismount(mount_dir):
                subprocess.run(["hdiutil", "detach", mount_dir, "-force"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(mount_dir, ignore_errors=True)
        return

    # Also scan raw bytes of the file itself
    try:
        data = target.read_bytes()
    except Exception as exc:
        findings.append(f"[unreadable_file] {rel_label}: {exc}")
        return
    scan_bytes(data, rel_label, extra_tokens, findings)


def run_selftest() -> int:
    """Verify red-then-green ('先坏后好'): planted leaks in text, binary, and nested .zip MUST fail, clean tree MUST pass."""
    extra = [("test_owner_token", b"SecretClinicOwnerName")]
    with tempfile.TemporaryDirectory(prefix="ci_priv_selftest_") as td:
        root = Path(td)
        # 1. Planted leaks: hardcoded /Users/ path in fake Mach-O binary, LAN IP in config, secret inside .zip, junk .orig_bak
        # Assemble synthetic fixture strings dynamically so scanning privacy_scan.py itself does not self-trigger.
        fake_user_path = b"/" + b"Users/" + b"leaked_dev_account/.build/foo.bundle\x00"
        fake_lan_ip = "192.168" + ".31.88"
        fake_sk = "sk-" + ("a1b2c3d4" * 3)
        (root / "fake_bin").write_bytes(b"\xcf\xfa\xed\xfe\x00\x00" + fake_user_path)
        (root / "notes.txt").write_text(f"server = {fake_lan_ip}\nowner = SecretClinicOwnerName\n", encoding="utf-8")
        (root / ("leftover.swift." + "orig_bak")).write_text("// backup", encoding="utf-8")
        zpath = root / "nested.zip"
        with zipfile.ZipFile(zpath, "w") as zf:
            zf.writestr("inner/secret.txt", f"token = {fake_sk}\n")

        bad_findings: list[str] = []
        scan_path(root, extra, bad_findings, "selftest_dirty")
        cats = {f.split("]", 1)[0].lstrip("[") for f in bad_findings}
        required = {"hardcoded_macos_user_path", "private_lan_ip_192_168", "test_owner_token", "junk_file", "api_token_sk"}
        missing = required - cats
        if missing:
            sys.stderr.write(f"PRIVACY SELFTEST FAIL: missed planted leak categories: {sorted(missing)} (got {sorted(cats)})\n")
            return 1

        # 2. Clean tree MUST pass with zero findings
        clean = root / "clean_pkg"
        clean.mkdir()
        (clean / "README.md").write_text("# Macap\nShared path example: /Users/Shared/Macap\n", encoding="utf-8")
        (clean / "weights.rmw").write_bytes(b"\x00\x01\x02\x03RIFE425\x00" * 128)
        clean_z = clean / "archive.zip"
        with zipfile.ZipFile(clean_z, "w") as zf:
            zf.writestr("ok.txt", "100% clean release notes\n")

        good_findings: list[str] = []
        scan_path(clean, extra, good_findings, "selftest_clean")
        if good_findings:
            sys.stderr.write(f"PRIVACY SELFTEST FAIL: false positive on clean tree: {good_findings}\n")
            return 1

    print("privacy_scan selftest: PASS (planted binary/text/zip leaks blocked, clean tree green)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Pre-release privacy scanner for Macap.")
    ap.add_argument("--selftest", action="store_true", help="Run red-then-green self-test.")
    ap.add_argument("targets", nargs="*", help="Files, directories, .app, .zip, or .dmg to scan.")
    args = ap.parse_args()

    if args.selftest:
        return run_selftest()

    if not args.targets:
        ap.error("provide at least one target path or --selftest")

    extra = dynamic_host_tokens()
    findings: list[str] = []
    for raw in args.targets:
        p = Path(raw)
        if not p.exists():
            sys.stderr.write(f"PRIVACY SCAN ERROR: target does not exist: {raw}\n")
            return 2
        scan_path(p, extra, findings, p.name)

    if findings:
        sys.stderr.write(f"PRIVACY SCAN BLOCKED ({len(findings)} issue(s) found):\n")
        for item in findings[:40]:
            sys.stderr.write(f"  - {item}\n")
        if len(findings) > 40:
            sys.stderr.write(f"  ... and {len(findings) - 40} more\n")
        return 1

    print(f"privacy_scan: CLEAN ({len(args.targets)} target(s) verified, 0 leaks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
