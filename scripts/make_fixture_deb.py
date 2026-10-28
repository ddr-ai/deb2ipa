#!/usr/bin/env python3
"""Build the synthetic fixture debs used by the M7 hardening tests.

Two kinds (SKILL.md 7.C - never commit debs to git; build them on demand):

  unsatisfiable  a CONVERTIBLE app deb (minimal .app + hand-packed arm64
                 Mach-O executable) whose control Depends on a package that
                 exists in no repo - so the resolver must exit 3 with a
                 clear UNRESOLVED_DEPENDENCY line, exactly like a real
                 missing dependency.

  large-app      the same convertible app deb padded with a --padding-mb
                 data file so the artifact is large (50+ MB), for the
                 release-asset fallback leg of hardening.yml: the deb is
                 uploaded as a DRAFT release asset and the pipeline
                 downloads it from that URL (constraint 7.C's fallback).

The arm64 Mach-O builder is the struct-packing approach proven by
test_failure_paths.py (M5) - no toolchain needed.

Python 3 stdlib only; requires dpkg-deb on PATH.
"""

import argparse
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_PIE = 0x200000
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2


def _lc_str(s):
    data = s.encode() + b"\x00"
    return data + b"\x00" * ((-len(data)) % 8)


def _build_version_cmd(major, minor):
    minos = (major << 16) | (minor << 8)
    return struct.pack("<IIIIII", LC_BUILD_VERSION, 24,
                       PLATFORM_IOS, minos, minos, 0)


def arm64_execute(path, min_ios=(14, 0)):
    """A minimal thin arm64 PIE MH_EXECUTE Mach-O (load commands only)."""
    cmd = _build_version_cmd(*min_ios)
    header = struct.pack("<IIIIIIII", MH_MAGIC_64, CPU_TYPE_ARM64, 0,
                         MH_EXECUTE, 1, len(cmd), MH_PIE, 0)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(header + cmd)
    os.chmod(path, 0o755)


def make_app(root, bundle_id="ws.example.fixtures", name="FixtureApp"):
    """<root>/Applications/<name>.app with a real arm64 executable."""
    app = os.path.join(root, "Applications", name + ".app")
    os.makedirs(app, exist_ok=True)
    with open(os.path.join(app, "Info.plist"), "wb") as fh:
        plistlib.dump({
            "CFBundleExecutable": name,
            "CFBundleIdentifier": bundle_id,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "MinimumOSVersion": "14.0",
        }, fh)
    arm64_execute(os.path.join(app, name))
    return app


def build_deb(dest, data_root, package, version, depends="", architecture="iphoneos-arm64"):
    """dpkg-deb a control stanza + data tree into dest.
    dpkg-deb --build packs <data_root>/DEBIAN/control into control.tar and
    everything else into data.tar."""
    ctrl = os.path.join(data_root, "DEBIAN")
    os.makedirs(ctrl, exist_ok=True)
    with open(os.path.join(ctrl, "control"), "w") as fh:
        fh.write("Package: %s\n" % package)
        fh.write("Name: Fixture App\n")
        fh.write("Version: %s\n" % version)
        fh.write("Architecture: %s\n" % architecture)
        fh.write("Maintainer: deb2ipa fixtures <fixtures@deb2ipa.invalid>\n")
        fh.write("Installed-Size: 1\n")
        if depends:
            fh.write("Depends: %s\n" % depends)
        fh.write("Description: synthetic deb2ipa fixture deb\n")
    subprocess.run(["dpkg-deb", "-Z", "gzip", "-b", data_root, dest],
                   check=True, capture_output=True)
    return dest


def main():
    ap = argparse.ArgumentParser(description="build synthetic fixture debs")
    ap.add_argument("--kind", required=True,
                    choices=("unsatisfiable", "large-app"))
    ap.add_argument("--out", required=True, help="destination .deb path")
    ap.add_argument("--padding-mb", type=int, default=60,
                    help="padding size for large-app (default 60)")
    ap.add_argument("--package", default="ws.example.fixture")
    ap.add_argument("--version", default="1.0")
    ap.add_argument("--missing-package", default="com.deb2ipa.nonexistent",
                    help="the unsatisfiable dependency name")
    args = ap.parse_args()

    root = tempfile.mkdtemp(prefix="fixture-deb-")
    try:
        data = os.path.join(root, "data")
        make_app(data)
        if args.kind == "unsatisfiable":
            depends = "%s (>= 99.0)" % args.missing_package
        else:
            # A real dependency so the resolution step also works on this
            # leg: firmware is the device-bootstrap virtual.
            depends = "firmware (>= 14.0)"
            pad = os.path.join(data, "Library", "FixtureData")
            os.makedirs(pad, exist_ok=True)
            # Incompressible padding (random bytes): the .deb itself must
            # stay ~padding MB after gzip, so the leg really moves a large
            # file through the release-asset fallback.
            with open(os.path.join(pad, "padding.bin"), "wb") as fh:
                for _ in range(args.padding_mb):
                    fh.write(os.urandom(1024 * 1024))
        build_deb(args.out, data, args.package, args.version, depends)
        print("FIXTURE_DEB kind=%s path=%s bytes=%d" %
              (args.kind, args.out, os.path.getsize(args.out)))
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
