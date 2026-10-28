#!/usr/bin/env python3
"""Unit tests for check_convertibility.py (SKILL.md M7).

Builds the synthetic deb classes the hardening legs do not cover on real
data (themePack, iosTools, nonIOS, app-without-arm64-executable, tweak,
nested .app) plus the two real debs when the network allows, and asserts
the exit code + machine line of each.

Pure python3 stdlib + dpkg-deb; runs in the test.yml CI job.
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_convertibility  # noqa: E402
import make_fixture_deb      # noqa: E402

WORK = os.path.join(tempfile.mkdtemp(prefix="convert-test-"))

failures = []


def run_check(deb):
    r = subprocess.run(
        [sys.executable, os.path.join(HERE, "check_convertibility.py"),
         "--deb", deb],
        capture_output=True, text=True)
    return r.returncode, r.stdout


def build(data_rel, control, files):
    """files: list of (relative_path, bytes, executable?)"""
    root = os.path.join(WORK, data_rel.replace("/", "-"))
    for path, blob, executable in files:
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:
            fh.write(blob)
        if executable:
            os.chmod(full, 0o755)
    return make_fixture_deb.build_deb(
        os.path.join(WORK, data_rel.replace("/", "-") + ".deb"),
        root, "ws.example." + data_rel.replace("/", "."), "1.0",
        depends=control)


def expect(name, deb, want_code, want_line_prefix):
    code, out = run_check(deb)
    first = out.splitlines()[0] if out else ""
    print("%-34s exit=%d %s" % (name, code, first))
    if code != want_code:
        failures.append("%s: expected exit %d, got %d\n%s" %
                        (name, want_code, code, out))
    elif not first.startswith(want_line_prefix):
        failures.append("%s: expected %r line, got %r" %
                        (name, want_line_prefix, first))


# --- synthetic classes ----------------------------------------------------

ELF = b"\x7fELF" + bytes(60)

# Control: a convertible app (real arm64 executable in a .app bundle).
make_fixture_deb.make_app(os.path.join(WORK, "app2"))
expect("app (control, convertible)", make_fixture_deb.build_deb(
           os.path.join(WORK, "app2.deb"), os.path.join(WORK, "app2"),
           "ws.example.app2", "1.0"),
       0, "CONVERTIBLE")

expect("tweak (substrate dylib, no .app)",
       build("tweak", "mobilesubstrate",
             [("Library/MobileSubstrate/DynamicLibraries/T.dylib",
               b"\x00\x01\x02", True)]),
       2, "NOT_CONVERTIBLE class=tweak")

expect("themePack (data only)",
       build("theme", "", [("Library/Themes/Cool.theme/bg.png",
                            b"\x89PNG", False)]),
       2, "NOT_CONVERTIBLE class=themePack")

expect("nonIOS (ELF binaries)",
       build("nonios", "", [("usr/bin/tool", ELF, True)]),
       2, "NOT_CONVERTIBLE class=nonIOS")

# iosTools: a bare arm64 Mach-O binary outside any .app bundle.
make_fixture_deb.arm64_execute(
    os.path.join(WORK, "tools2", "usr", "bin", "ioscli"))
expect("iosTools (bare arm64 binary, no .app)", make_fixture_deb.build_deb(
           os.path.join(WORK, "tools2.deb"), os.path.join(WORK, "tools2"),
           "ws.example.tools2", "1.0"),
       2, "NOT_CONVERTIBLE class=iosTools")

expect("app without arm64 executable",
       build("appnoexec", "", [("Applications/Empty.app/Info.plist",
                                b"not a plist", False)]),
       2, "NOT_CONVERTIBLE class=app")

expect("nested .app is not outermost",
       build("nested", "",
             [("Applications/Outer.app/Nested.app/Nested",
               b"", False)]),
       2, "NOT_CONVERTIBLE class=app")

# nested with a REAL executable inside the outer bundle (Info.plist names it)
data = os.path.join(WORK, "nested-ok")
app = os.path.join(data, "Applications", "Outer.app")
os.makedirs(os.path.join(app, "Nested.app"), exist_ok=True)
import plistlib  # noqa: E402
with open(os.path.join(app, "Info.plist"), "wb") as fh:
    plistlib.dump({"CFBundleExecutable": "Outer"}, fh)
make_fixture_deb.arm64_execute(os.path.join(app, "Outer"))
expect("outer .app wins over nested", make_fixture_deb.build_deb(
           os.path.join(WORK, "nested-ok.deb"), data,
           "ws.example.nestedok", "1.0"),
       0, "CONVERTIBLE")

expect("convertible app WITH substrate content warns",
       build("appsubstrate", "",
             [("Applications/Demo.app/Demo", b"", False),
              ("Library/MobileSubstrate/DynamicLibraries/T.dylib",
               b"\x00\x01", True)]),
       2, "NOT_CONVERTIBLE class=app")

# ... with a real executable next to the substrate content: convertible,
# with the jailbreak-runtime warning in the output.
data = os.path.join(WORK, "appsubstrate2")
make_fixture_deb.make_app(data)
sub = os.path.join(data, "Library/MobileSubstrate/DynamicLibraries")
os.makedirs(sub, exist_ok=True)
with open(os.path.join(sub, "T.dylib"), "wb") as fh:
    fh.write(b"\x00\x01")
code, out = run_check(make_fixture_deb.build_deb(
    os.path.join(WORK, "appsubstrate2.deb"), data,
    "ws.example.appsubstrate2", "1.0"))
print("%-34s exit=%d %s" % ("app+substrate (real exec)", code,
                            out.splitlines()[0]))
if code != 0:
    failures.append("app+substrate: expected convertible, got %d" % code)
if "WARN" not in out and "note=substrate" not in out:
    failures.append("app+substrate: expected substrate warning, got:\n" + out)

expect("unreadable file is an error, not a crash",
       "/nonexistent.deb", 1, "CHECK_ERROR")

# --- real debs (optional; the hardening legs run them for real) -----------

for name, url in (("real NewTerm 3 (app)",
                   "https://repo.chariz.com/debs/"
                   "ws.hbang.newterm3_3.0~beta1_iphoneos-arm64.deb"),
                  ("real QuitAll (tweak)",
                   "https://repo.chariz.com/debs/"
                   "com.daveapps.quitall_3.0_iphoneos-arm.deb")):
    dest = os.path.join(WORK, os.path.basename(url))
    r = subprocess.run(["curl", "-fsSL", "-o", dest, url],
                       capture_output=True)
    if r.returncode != 0:
        print("%-34s SKIP (network)" % name)
        continue
    want = "CONVERTIBLE" if "newterm" in url else "NOT_CONVERTIBLE class=tweak"
    expect(name, dest, 0 if want.startswith("CONVERTIBLE") else 2, want)

# ---------------------------------------------------------------------------

shutil.rmtree(WORK, ignore_errors=True)
print()
if failures:
    print("FAILURES:\n" + "\n".join(failures))
    sys.exit(1)
print("ALL CONVERTIBILITY TESTS PASS")
