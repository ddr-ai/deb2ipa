#!/usr/bin/env python3
"""deb2ipa convertibility pre-check (SKILL.md M7, constraint 7.G).

Workflow-side port of the M2 classifier's core rule: a deb is convertible
iff an arm64 MH_EXECUTE sits inside a .app bundle (outermost wins). Tweak
debs inject into other apps and cannot run standalone; the on-device M6
classifier stops them BEFORE dispatch - this script is the guard for
dispatches that bypass the app (a URL pasted straight into workflow_dispatch).

Exits fast on the runner, BEFORE dependency resolution and assembly, with
a machine line + a human explanation:

  CONVERTIBLE class=app bundle=NewTerm.app executable=NewTerm
  NOT_CONVERTIBLE class=tweak reasons="MobileSubstrate dylib; no .app bundle"

Exit codes: 0 convertible; 2 not convertible (expected rejection);
1 any other error (unreadable deb, bad arguments).

Python 3 stdlib only. Runs on the ubuntu-24.04 Actions runner and locally.
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import macho  # noqa: E402 - the M5 stdlib Mach-O reader

MH_EXECUTE = 0x02

# M2's tweak-signature paths (SKILL.md M2 / DebClassifier).
TWEAK_PATH_MARKERS = ("MobileSubstrate", "TweakInject", "PreferenceBundles")

# Sanity caps: a hostile or huge payload must not stall the check.
MAX_FILES_SCANNED = 50_000
MAGIC_READ_BYTES = 4096

# Human explanations, kept in sync with the M6 verdict sentences
# (Views/DebOverview.verdictSentence) so the runner log and the app
# say the same thing.
EXPLANATIONS = {
    "tweak": "Not convertible on its own - this is a MobileSubstrate tweak "
             "that injects into other apps.",
    "iosTools": "Not convertible - these are iOS command-line tools with no "
                ".app bundle to launch from.",
    "nonIOS": "Not convertible - the binaries inside are built for Linux "
              "or desktop platforms.",
    "themePack": "Not convertible - this package only carries themes or "
                 "data files, no executable.",
    "app": "Not convertible - a .app bundle is present but no arm64 main "
           "executable was found inside.",
}


def fail_error(message):
    print("CHECK_ERROR message=%s" % message)
    print("error: %s" % message, file=sys.stderr)
    sys.exit(1)


def extract(deb_path, dest):
    """dpkg-deb -x; any failure is a hard error (not a typed rejection)."""
    result = subprocess.run(
        ["dpkg-deb", "-x", deb_path, dest],
        capture_output=True, text=True)
    if result.returncode != 0:
        fail_error("dpkg-deb -x failed (%d): %s" %
                   (result.returncode, (result.stderr or "").strip()[:500]))


def scan_tree(root):
    """One walk collecting outermost .app dirs, Mach-O/ELF evidence and
    tweak-path evidence. Returns (app_dirs, arm64_execs, has_macho,
    has_elf, has_substrate)."""
    app_dirs = []
    arm64_execs = []          # paths of arm64 MH_EXECUTE Mach-O files
    has_macho = has_elf = has_substrate = False
    scanned = 0

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel = os.path.relpath(dirpath, root)

        # Outermost-.app rule: a .app counts only if no ancestor within the
        # payload is itself a .app (M2: outermost wins). rel INCLUDES this
        # dir's own name, so a dir that IS a .app sees itself and skips
        # adding its nested bundles.
        inside_app = any(part.endswith(".app")
                          for part in rel.split(os.sep))
        for d in list(dirnames):
            if inside_app:
                continue  # do not descend into nested .app bundles
            if d.endswith(".app"):
                app_dirs.append(os.path.join(dirpath, d))
        if inside_app:
            # Prune .app discovery inside a .app; keep walking the rest of
            # the bundle for executable evidence.
            dirnames[:] = [d for d in dirnames if not d.endswith(".app")]

        for name in filenames:
            if scanned >= MAX_FILES_SCANNED:
                return app_dirs, arm64_execs, has_macho, has_elf, has_substrate
            scanned += 1
            full = os.path.join(dirpath, name)
            if any(marker in full for marker in TWEAK_PATH_MARKERS):
                has_substrate = True
            try:
                with open(full, "rb") as fh:
                    head = fh.read(MAGIC_READ_BYTES)
            except OSError:
                continue
            if head[:4] == b"\x7fELF":
                has_elf = True
                continue
            if not macho.looks_like_macho(head):
                continue
            has_macho = True
            info = macho.analyze(head)
            if info.get("arm64") and info.get("filetype") == MH_EXECUTE:
                arm64_execs.append(os.path.relpath(full, root))

    return app_dirs, arm64_execs, has_macho, has_elf, has_substrate


def bundle_executable(app_dir):
    """The arm64 MH_EXECUTE of a .app: CFBundleExecutable when its Info.plist
    names a valid one; otherwise any arm64 executable directly in the
    bundle root (a bundle without an Info.plist can still be convertible -
    make_ipa.sh generates the plist)."""
    plist_path = os.path.join(app_dir, "Info.plist")
    if os.path.isfile(plist_path):
        try:
            with open(plist_path, "rb") as fh:
                plist = plistlib.load(fh)
        except Exception:  # noqa: BLE001 - unparseable plist = no plist
            plist = {}
        name = plist.get("CFBundleExecutable", "")
        if name and is_arm64_execute(os.path.join(app_dir, name)):
            return name, True

    # No (usable) Info.plist: accept any arm64 executable in the root.
    try:
        entries = sorted(os.listdir(app_dir))
    except OSError:
        return None, False
    for name in entries:
        if is_arm64_execute(os.path.join(app_dir, name)):
            return name, False
    return None, False


def is_arm64_execute(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(MAGIC_READ_BYTES)
    except OSError:
        return False
    if not macho.looks_like_macho(head):
        return False
    info = macho.analyze(head)
    return bool(info.get("arm64")) and info.get("filetype") == MH_EXECUTE


def classify(app_dirs, arm64_execs, has_macho, has_elf, has_substrate):
    """(class, reasons, convertible_app) mirroring the M2 class rules."""
    for app_dir in app_dirs:
        exe, from_plist = bundle_executable(app_dir)
        if exe is not None:
            return ("app", [os.path.basename(app_dir)], app_dir, exe, from_plist)
    if app_dirs:
        return ("app", ["no arm64 MH_EXECUTE inside the .app bundle(s)"],
                None, None, False)
    if has_substrate:
        return ("tweak", ["MobileSubstrate/TweakInject/PreferenceBundles "
                         "content, no .app bundle"], None, None, False)
    if has_elf:
        return ("nonIOS", ["ELF binaries, no .app bundle"], None, None, False)
    if has_macho:
        return ("iosTools", ["bare arm64 binaries, no .app bundle"],
                None, None, False)
    return ("themePack", ["no executable content"], None, None, False)


def main():
    ap = argparse.ArgumentParser(description="deb2ipa convertibility pre-check")
    ap.add_argument("--deb", required=True, help="path to the root .deb")
    args = ap.parse_args()

    if not os.path.isfile(args.deb):
        fail_error("no such file: %s" % args.deb)

    tmp = tempfile.mkdtemp(prefix="deb2ipa-convert-")
    try:
        extract(args.deb, tmp)
        app_dirs, arm64_execs, has_macho, has_elf, has_substrate = \
            scan_tree(tmp)
        cls, reasons, app_dir, exe, from_plist = classify(
            app_dirs, arm64_execs, has_macho, has_elf, has_substrate)

        if app_dir is not None:
            bundle = os.path.basename(app_dir)
            extra = ""
            if has_substrate:
                extra = " note=substrate content alongside the app bundle" \
                        " (jailbreak runtime may be required)"
            print("CONVERTIBLE class=app bundle=%s executable=%s%s"
                  % (bundle, exe, extra))
            print("bundle %s carries arm64 executable %r%s"
                  % (bundle, exe,
                     " (from Info.plist)" if from_plist else " (bundle root)"))
            if has_substrate:
                print("WARN %s also ships MobileSubstrate/TweakInject/"
                      "PreferenceBundles content; the IPA will install but "
                      "runtime hooks only work with a jailbreak runtime"
                      % bundle)
            sys.exit(0)

        print("NOT_CONVERTIBLE class=%s reasons=%s"
              % (cls, "; ".join(reasons)))
        print(EXPLANATIONS[cls])
        if cls == "tweak":
            print("This deb injects code into OTHER apps via MobileSubstrate. "
                  "It cannot be turned into a standalone IPA that launches.")
        sys.exit(2)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
