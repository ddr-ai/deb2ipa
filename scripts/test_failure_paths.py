#!/usr/bin/env python3
"""Failure-path tests for check_launchability.py.

Builds minimal synthetic Payload trees with hand-crafted arm64 Mach-O
binaries (pure struct packing - no toolchain needed) that each violate
exactly one checklist item, then asserts the checker fails with exit 6.

case_a: exe links a device-absolute /var/jb/ dylib  -> dylib_resolution fails
case_b: dangling symlink inside Frameworks/          -> chains + dylib_resolution fail
case_c: two outermost .app bundles                  -> single_outermost_app fails
case_d: CFBundleExecutable is a shell script        -> executable_arm64_macho fails
case_e: clean bundle                                -> RESULT=pass, exit 0 (control)
"""
import os
import shutil
import struct
import subprocess
import sys
import plistlib

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_launchability.py")
WORK = os.path.join(HERE, "t", "cases")

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_DYLIB = 6
MH_PIE = 0x200000

LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18 | 0x80000000
LC_RPATH = 0x1C | 0x80000000
LC_BUILD_VERSION = 0x32

PLATFORM_IOS = 2


def _lc_str(s):
    data = s.encode() + b"\x00"
    pad = (-len(data)) % 8
    return data + b"\x00" * pad


def _dylib_cmd(cmd, path):
    body = struct.pack("<IIII", 24, 1, 0x10000, 0x10000)  # name off, ts, cur, compat
    data = _lc_str(path)
    size = 24 + len(data)
    return struct.pack("<II", cmd, size) + body + data


def _rpath_cmd(path):
    data = _lc_str(path)
    size = 12 + len(data)
    return struct.pack("<III", LC_RPATH, size, 12) + data


def _build_version_cmd(major, minor):
    minos = (major << 16) | (minor << 8)
    return struct.pack("<IIIIII", LC_BUILD_VERSION, 24, PLATFORM_IOS, minos, minos, 0)


def macho(path, dylibs=(), weak=(), rpaths=(), filetype=MH_EXECUTE, min_ios=(14, 0)):
    cmds = b""
    n = 0
    for dl in dylibs:
        cmds += _dylib_cmd(LC_LOAD_DYLIB, dl); n += 1
    for dl in weak:
        cmds += _dylib_cmd(LC_LOAD_WEAK_DYLIB, dl); n += 1
    for rp in rpaths:
        cmds += _rpath_cmd(rp); n += 1
    cmds += _build_version_cmd(*min_ios); n += 1
    header = struct.pack("<IIIIIIII", MH_MAGIC_64, CPU_TYPE_ARM64, 0,
                         filetype, n, len(cmds), MH_PIE, 0)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(header + cmds)
    os.chmod(path, 0o755)


def info_plist(path, executable="Demo", bundle_id="com.example.demo", extra=None):
    d = {"CFBundleExecutable": executable,
         "CFBundleIdentifier": bundle_id,
         "CFBundleName": "Demo",
         "MinimumOSVersion": "14.0"}
    if extra:
        d.update(extra)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        plistlib.dump(d, fh)


def make_app(app_dir, executable="Demo", dylibs=(), weak=(), rpaths=(),
             min_ios=(14, 0), plist_extra=None, bundle_id="com.example.demo"):
    info_plist(os.path.join(app_dir, "Info.plist"), executable, bundle_id,
               plist_extra)
    macho(os.path.join(app_dir, executable), dylibs, weak, rpaths,
          min_ios=min_ios)


def zip_tree(staging, ipa_path):
    """Use the zip CLI so symlinks are stored as symlinks (--symlinks)."""
    os.makedirs(os.path.dirname(ipa_path), exist_ok=True)
    if os.path.exists(ipa_path):
        os.remove(ipa_path)
    subprocess.run(["zip", "-qry", "--symlinks", ipa_path, "Payload"],
                   cwd=staging, check=True)


def run_checker(ipa_path, staging):
    r = subprocess.run(
        [sys.executable, CHECKER, "--ipa", ipa_path,
         "--payload-dir", os.path.join(staging, "Payload"),
         "--report", os.path.join(staging, "report.json")],
        capture_output=True, text=True)
    return r.returncode, r.stdout


def case_dir(name):
    d = os.path.join(WORK, name)
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    return d


failures = []

# --- case a: /var/jb absolute dylib ------------------------------------
d = case_dir("a")
make_app(os.path.join(d, "Payload", "Demo.app"),
         dylibs=["/usr/lib/libSystem.dylib", "/var/jb/usr/lib/libfoo.dylib"])
zip_tree(d, os.path.join(d, "Demo.ipa"))
code, out = run_checker(os.path.join(d, "Demo.ipa"), d)
print("case a (var/jb dylib): exit=%d" % code)
print("   " + "\n   ".join(l for l in out.splitlines() if l.startswith("[fail]")))
if code != 6:
    failures.append("case a: expected exit 6, got %d" % code)

# --- case b: dangling symlink in Frameworks -----------------------------
d = case_dir("b")
app = os.path.join(d, "Payload", "Demo.app")
make_app(app, dylibs=["/usr/lib/libSystem.dylib", "@rpath/libfoo.dylib"],
         rpaths=["@executable_path/Frameworks"])
fw = os.path.join(app, "Frameworks")
os.makedirs(fw, exist_ok=True)
os.symlink("libmissing.dylib", os.path.join(fw, "libfoo.dylib"))
zip_tree(d, os.path.join(d, "Demo.ipa"))
code, out = run_checker(os.path.join(d, "Demo.ipa"), d)
print("case b (dangling Frameworks symlink): exit=%d" % code)
print("   " + "\n   ".join(l for l in out.splitlines() if l.startswith("[fail]")))
if code != 6:
    failures.append("case b: expected exit 6, got %d" % code)

# --- case c: two outermost .app ----------------------------------------
d = case_dir("c")
make_app(os.path.join(d, "Payload", "Demo.app"))
make_app(os.path.join(d, "Payload", "Other.app"))
zip_tree(d, os.path.join(d, "Demo.ipa"))
code, out = run_checker(os.path.join(d, "Demo.ipa"), d)
print("case c (two .app): exit=%d" % code)
print("   " + "\n   ".join(l for l in out.splitlines() if l.startswith("[fail]")))
if code != 6:
    failures.append("case c: expected exit 6, got %d" % code)

# --- case d: CFBundleExecutable is not Mach-O ---------------------------
d = case_dir("d")
app = os.path.join(d, "Payload", "Demo.app")
os.makedirs(app, exist_ok=True)
info_plist(os.path.join(app, "Info.plist"), executable="start")
with open(os.path.join(app, "start"), "w") as fh:
    fh.write("#!/bin/sh\necho hi\n")
os.chmod(os.path.join(app, "start"), 0o755)
zip_tree(d, os.path.join(d, "Demo.ipa"))
code, out = run_checker(os.path.join(d, "Demo.ipa"), d)
print("case d (non-Mach-O executable): exit=%d" % code)
print("   " + "\n   ".join(l for l in out.splitlines() if l.startswith("[fail]")))
if code != 6:
    failures.append("case d: expected exit 6, got %d" % code)

# --- case e: control - must pass ----------------------------------------
d = case_dir("e")
make_app(os.path.join(d, "Payload", "Demo.app"),
         dylibs=["/usr/lib/libSystem.dylib", "@rpath/libfoo.dylib"],
         rpaths=["@executable_path/Frameworks"],
         plist_extra={"CFBundleIconFile": "AppIcon"})
fw = os.path.join(d, "Payload", "Demo.app", "Frameworks")
os.makedirs(fw, exist_ok=True)
macho(os.path.join(fw, "libfoo.dylib"), filetype=MH_DYLIB,
      dylibs=["/usr/lib/libSystem.dylib"])
zip_tree(d, os.path.join(d, "Demo.ipa"))
code, out = run_checker(os.path.join(d, "Demo.ipa"), d)
print("case e (control, should pass): exit=%d" % code)
print("   " + "\n   ".join(l for l in out.splitlines()
                           if l.startswith(("[pass]", "WARN"))))
if code != 0:
    failures.append("case e: expected exit 0, got %d\n%s" % (code, out))

print()
if failures:
    print("FAILURES:\n" + "\n".join(failures))
    sys.exit(1)
print("ALL FAILURE-PATH TESTS PASS")
