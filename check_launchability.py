#!/usr/bin/env python3
"""check_launchability.py - deb2ipa M5 hard launchability checklist.

Runs over a staged, packed-but-unsigned IPA build and decides whether the
artifact can be expected to INSTALL and LAUNCH after a normal sideload
(AltStore / Sideloadly / any signer) on a stock, non-jailbroken iPhone.

What "launchable" means here (all enforced, per the deb2ipa plan M5):
  1. zip_root_payload       - every archive entry sits under Payload/ and
                              Payload/ is at the zip root
  2. single_outermost_app   - exactly one *.app directly under Payload/
  3. info_plist_parses      - the bundle's Info.plist is a readable plist
  4. executable_arm64_macho - CFBundleExecutable exists on disk and contains
                              an arm64/arm64_32 Mach-O slice
  5. dylib_resolution       - every LC_LOAD_DYLIB of the executable and of
                              every bundled Mach-O (Frameworks/, PlugIns/,
                              app root) is either a system library or
                              resolves to a file inside the IPA
  6. bundle_symlink_chains  - every symlink in Frameworks/, PlugIns/ and the
                              app root resolves, inside the bundle

Anything jailbroken-only that cannot work jailed (MobileSubstrate tweaks,
dangling /var/jb symlinks, unresolved WEAK dylibs, missing icons, non-PIE
executables) is reported as a WARNING, not a failure - those affect runtime
quality, not the launch gate.

Results land in launchability-report.json and (when --resolution-report is
given) are merged into resolution-report.json as the "launchability" key.
Any failed check blocks the Release: the workflow publishes a draft with the
report instead of a public release.

Exit codes: 0 checklist passed, 6 LAUNCHABILITY_FAILED, 2 usage/tooling.
"""

import argparse
import json
import os
import plistlib
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import macho  # noqa: E402  (scripts/macho.py, same directory)

SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
RECORD_PREFIXES = ("/Developer/",)          # jailbreak tooling; warn only

# Directories inside the bundle whose symlinks are launch-critical.
CHAIN_DIRS = ("Frameworks", "PlugIns")

MAX_SYMLINK_HOPS = 20


def fail_line(*parts):
    print(*parts)
    sys.stdout.flush()


class Check:
    def __init__(self, check_id):
        self.id = check_id
        self.status = "pass"
        self.detail = ""
        self.failures = []
        self.warnings = []

    def ok(self, detail):
        self.status = "pass"
        self.detail = detail

    def fail(self, detail, failures):
        self.status = "fail"
        self.detail = detail
        self.failures = failures

    def to_dict(self):
        out = {"id": self.id, "status": self.status, "detail": self.detail}
        if self.failures:
            out["failures"] = self.failures
        if self.warnings:
            out["warnings"] = self.warnings
        return out


def _expand(prefix_paths, token, binary_dir, exe_dir, rpaths, depth=0):
    """Expand one dylib path against the given expansion contexts.

    Returns (resolved_path_or_None, reason). rpaths themselves may contain
    @executable_path/@loader_path, hence the recursion (capped).
    """
    if depth > 8:
        return None, "rpath nesting too deep"
    if token.startswith("@executable_path"):
        rest = token[len("@executable_path"):]
        rest = rest[1:] if rest.startswith("/") else rest
        return _expand([], exe_dir + "/" + rest, binary_dir, exe_dir, [], depth + 1)
    if token.startswith("@loader_path"):
        rest = token[len("@loader_path"):]
        rest = rest[1:] if rest.startswith("/") else rest
        return _expand([], binary_dir + "/" + rest, binary_dir, exe_dir, [], depth + 1)
    if token.startswith("@rpath/"):
        name = token[len("@rpath/"):]
        for rpath in rpaths:
            candidate, _ = _expand([], rpath.rstrip("/") + "/" + name,
                                   binary_dir, exe_dir, rpaths, depth + 1)
            if candidate and os.path.exists(candidate):
                return candidate, None
            # The expansion may land in a system location (e.g. rpath
            # /usr/lib/swift + libswiftCore.dylib): that path exists on the
            # device even though the staging machine has no /usr/lib/swift,
            # so hand it back for the caller to classify as system.
            if candidate and candidate.startswith(SYSTEM_PREFIXES):
                return candidate, None
        return None, "no LC_RPATH resolves @rpath/%s" % name
    if token.startswith("/"):
        return token, None                      # absolute, caller classifies
    if token == "":
        return None, "empty load path"
    # Bare relative name: dyld would resolve against the process CWD - only
    # acceptable when it also happens to sit next to the loading binary.
    candidate = binary_dir.rstrip("/") + "/" + token
    if os.path.exists(candidate):
        return candidate, None
    return None, "relative path not next to loader"


def check_zip(ipa_path):
    c = Check("zip_root_payload")
    with zipfile.ZipFile(ipa_path) as zf:
        names = zf.namelist()
    outside = [n for n in names if not n.startswith("Payload/")]
    if outside:
        c.fail("archive entries outside Payload/",
               outside[:10] + (["..."] if len(outside) > 10 else []))
        return c, names
    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and len(n.split("/")) > 2
                   and n.split("/")[1].endswith(".app")
                   and n.count("/") == 2 and n.endswith("/")})
    c.ok("%d entries, all under Payload/" % len(names))
    return c, names


def check_single_app(names):
    c = Check("single_outermost_app")
    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and n.split("/")[1].endswith(".app")
                   and ("/" + n.split("/")[1] + "/") in n})
    if len(apps) != 1:
        c.fail("expected exactly one outermost .app, found %d" % len(apps), apps)
    else:
        c.ok("single app: %s" % apps[0])
    return c, (apps[0] if len(apps) == 1 else None)


def check_plist(app_dir):
    c = Check("info_plist_parses")
    path = os.path.join(app_dir, "Info.plist")
    if not os.path.isfile(path):
        c.fail("Info.plist missing from %s" % app_dir, [path])
        return c, {}
    try:
        with open(path, "rb") as f:
            plist = plistlib.load(f)
    except Exception as exc:
        c.fail("Info.plist does not parse: %s" % exc, [path])
        return c, {}
    if not isinstance(plist.get("CFBundleExecutable"), str):
        c.fail("Info.plist has no CFBundleExecutable", [path])
        return c, plist
    icon_keys = ("CFBundleIconFiles", "CFBundleIcons", "CFBundleIcons~ipad",
                 "CFBundleIconName")
    if not any(k in plist for k in icon_keys):
        c.warnings.append("no icon key in Info.plist (CFBundleIcons etc.)")
    if "MinimumOSVersion" not in plist:
        c.warnings.append("Info.plist has no MinimumOSVersion")
    c.ok("parsed: %d keys" % len(plist))
    return c, plist


def check_executable(app_dir, plist, warnings):
    c = Check("executable_arm64_macho")
    exe_name = plist.get("CFBundleExecutable", "")
    exe_path = os.path.join(app_dir, exe_name)
    if not os.path.lexists(exe_path):
        c.fail("CFBundleExecutable %r not on disk" % exe_name, [exe_path])
        return c, None
    with open(exe_path, "rb") as f:
        data = f.read(16 * 1024 * 1024)       # cap: load commands live early
    info = macho.analyze(data)
    if not info["arm64"]:
        c.fail("CFBundleExecutable is not an arm64 Mach-O "
               "(arm64=%s)" % info["arm64"], [exe_path])
        return c, info
    if not info["pie"]:
        warnings.append("executable is not PIE; some sideload tools refuse it")
    c.ok("arm64%s Mach-O, %d load_dylibs, min_ios=%s" %
         ("" if info["pie"] else " (no PIE flag)", len(info["load_dylibs"]),
          info["min_ios"] or "?"))
    return c, info


def _walk_macho_files(app_dir):
    """Yield absolute paths of Mach-O files in launch-critical locations."""
    seen = set()

    def probe(path):
        try:
            with open(path, "rb") as f:
                head = f.read(16 * 1024 * 1024)
        except OSError:
            return None
        if not macho.looks_like_macho(head):
            return None
        info = macho.analyze(head)
        return info if info["arm64"] or info["load_dylibs"] else None

    # App root (the main executable, login helpers, alias binaries).
    try:
        for entry in sorted(os.listdir(app_dir)):
            path = os.path.join(app_dir, entry)
            if os.path.isfile(path):
                info = probe(path)
                if info:
                    seen.add(path)
                    yield path, info
    except OSError:
        pass
    # Frameworks/ and PlugIns/, recursively.
    for sub in CHAIN_DIRS:
        base = os.path.join(app_dir, sub)
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base, followlinks=False):
            for name in sorted(files):
                path = os.path.join(root, name)
                if path in seen:
                    continue
                info = probe(path)
                if info:
                    seen.add(path)
                    yield path, info


def check_dylibs(app_dir, exe_info, warnings, max_binaries=200):
    c = Check("dylib_resolution")
    payload_dir = os.path.dirname(app_dir.rstrip("/")) + "/"
    failures = []
    exe_dir = app_dir
    exe_rpaths = (exe_info or {}).get("rpaths", [])
    checked = 0
    binaries = []
    try:
        binaries = list(_walk_macho_files(app_dir))
    except OSError as exc:
        c.fail("could not walk bundle: %s" % exc, [str(exc)])
        return c, 0
    for path, info in binaries[:max_binaries]:
        checked += 1
        binary_dir = os.path.dirname(path)
        # dyld semantics: @rpath is resolved with the loading image's
        # LC_RPATH entries, falling back to the MAIN EXECUTABLE's - a
        # bundled framework dylib without its own LC_RPATH resolves through
        # the app's (e.g. @executable_path/Frameworks, /usr/lib/swift).
        rpaths = list(dict.fromkeys(info["rpaths"] + exe_rpaths))
        for dep in info["load_dylibs"]:
            resolved, reason = _expand([], dep, binary_dir, exe_dir, rpaths)
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            if resolved and resolved.startswith("/"):
                if resolved.startswith(payload_dir) or resolved.startswith(app_dir):
                    # An expansion that landed inside the staged bundle:
                    # dyld will find it inside the IPA - fine.
                    if os.path.exists(resolved):
                        continue
                    failures.append({"binary": os.path.relpath(path, app_dir),
                                     "dylib": dep,
                                     "reason": "expansion target missing from the bundle"})
                    continue
                if resolved.startswith(SYSTEM_PREFIXES):
                    # @rpath expansion into a system location (or an
                    # absolute system path): present on every device.
                    continue
                # Device-absolute, non-system: dyld resolves it against the
                # real device filesystem; on a stock iPhone it will not exist.
                if resolved.startswith(RECORD_PREFIXES):
                    warnings.append("%s: %s only exists on jailbroken devices"
                                    % (os.path.basename(path), dep))
                    continue
                failures.append({"binary": os.path.relpath(path, app_dir),
                                 "dylib": dep,
                                 "reason": "absolute non-system path; missing on a stock device"})
            elif resolved and os.path.exists(resolved):
                continue                      # resolves inside the IPA - fine
            else:
                failures.append({"binary": os.path.relpath(path, app_dir),
                                 "dylib": dep,
                                 "reason": reason or "unresolvable"})
        for dep in info["weak_dylibs"]:
            resolved, reason = _expand([], dep, binary_dir, exe_dir, rpaths)
            ok = (dep.startswith(SYSTEM_PREFIXES)
                  or (resolved and resolved.startswith(SYSTEM_PREFIXES))
                  or (resolved
                      and (resolved.startswith(payload_dir)
                           or resolved.startswith(app_dir))
                      and os.path.exists(resolved)))
            if not ok:
                warnings.append("%s: WEAK dylib unresolved (%s): %s"
                                % (os.path.basename(path), dep, reason))
    if len(binaries) > max_binaries:
        c.warnings.append("only first %d of %d Mach-O binaries analyzed"
                          % (max_binaries, len(binaries)))
    if failures:
        c.fail("%d unresolvable LC_LOAD_DYLIB entries in %d binaries"
               % (len(failures), checked), failures)
    else:
        c.ok("%d binaries, all LC_LOAD_DYLIB entries resolve" % checked)
    return c, checked


def check_symlink_chains(app_dir, payload_dir):
    c = Check("bundle_symlink_chains")
    failures = []
    warnings = []
    checked = 0

    def chain_ok(link_path):
        """Follow a symlink chain; return (ok, inside, reason)."""
        current = link_path
        for _ in range(MAX_SYMLINK_HOPS):
            target = os.readlink(current)
            if target.startswith("/"):
                # Absolute target: only acceptable when it points inside the
                # bundle itself (rare) - it will dangle on a stock device.
                real = os.path.normpath(os.path.join(payload_dir, target.lstrip("/")))
                # Zip layout: payload/<app>/... so try both interpretations.
                alt = os.path.normpath(os.path.join(app_dir, target.lstrip("/")))
                for cand in (alt, real):
                    if os.path.exists(cand):
                        return True, True, None
                return False, False, "absolute target %s" % target
            nxt = os.path.normpath(os.path.join(os.path.dirname(current), target))
            if not nxt.startswith(payload_dir):
                return False, False, "escapes the bundle via %s" % target
            if not os.path.lexists(nxt):
                return False, False, "dangles at %s" % nxt
            if not os.path.islink(nxt):
                return True, True, None
            current = nxt
        return False, False, "symlink chain longer than %d hops" % MAX_SYMLINK_HOPS

    targets = []
    for sub in CHAIN_DIRS:
        base = os.path.join(app_dir, sub)
        if os.path.isdir(base):
            for root, _dirs, files in os.walk(base, followlinks=False):
                for name in files:
                    p = os.path.join(root, name)
                    if os.path.islink(p):
                        targets.append(p)
    # Direct app-root symlinks (alias dylibs, helpers).
    try:
        for entry in sorted(os.listdir(app_dir)):
            p = os.path.join(app_dir, entry)
            if os.path.islink(p):
                targets.append(p)
    except OSError:
        pass

    for link in targets:
        checked += 1
        ok, _inside, reason = chain_ok(link)
        if not ok:
            failures.append({"symlink": os.path.relpath(link, app_dir),
                             "reason": reason})
    if failures:
        c.fail("%d of %d launch-critical symlinks broken" % (len(failures), checked),
               failures)
    else:
        c.ok("%d symlinks in %s resolve inside the bundle" %
             (checked, "/".join(CHAIN_DIRS)))
    return c, warnings


def scan_warnings(app_dir, payload_dir, plist):
    """Global (non-gating) warnings."""
    out = []
    # Files that cannot function jailed.
    substrate = []
    for root, _dirs, files in os.walk(payload_dir, followlinks=False):
        if "MobileSubstrate" in root.split(os.sep):
            substrate.extend(os.path.join(root, f) for f in files)
        for f in files:
            if f.endswith(".substrate") or f.endswith(".dylib") and \
               "MobileSubstrate" in root:
                substrate.append(os.path.join(root, f))
    for p in substrate[:10]:
        out.append("cannot function jailed: %s" % os.path.relpath(p, payload_dir))
    if len(substrate) > 10:
        out.append("... and %d more MobileSubstrate files" % (len(substrate) - 10))
    # Dangling symlinks under .jbroot (bootstrap relocation leftovers).
    jbroot = os.path.join(app_dir, ".jbroot")
    if os.path.isdir(jbroot):
        dangling = 0
        for root, _dirs, files in os.walk(jbroot, followlinks=False):
            for name in files:
                p = os.path.join(root, name)
                if os.path.islink(p) and not os.path.exists(p):
                    dangling += 1
        if dangling:
            out.append("%d dangling symlinks under .jbroot (absolute "
                       "/var/jb targets that were not rewritten)" % dangling)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ipa", required=True, help="path to the packed .ipa")
    ap.add_argument("--payload-dir", required=True,
                    help="staging Payload/ directory (real files on disk)")
    ap.add_argument("--report", required=True,
                    help="where to write launchability-report.json")
    ap.add_argument("--resolution-report", default="",
                    help="optional resolution-report.json to merge results into")
    ap.add_argument("--max-binaries", type=int, default=200)
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        print("ERROR: no ipa at %s" % args.ipa)
        sys.exit(2)
    if not os.path.isdir(args.payload_dir):
        print("ERROR: no payload dir at %s" % args.payload_dir)
        sys.exit(2)

    warnings = []
    checks = []

    print("=== Launchability checklist ===")

    zc, names = check_zip(args.ipa)
    checks.append(zc)
    sc, app_name = check_single_app(names)
    checks.append(sc)

    app_dir = os.path.join(args.payload_dir, app_name) if app_name else ""
    if not app_dir or not os.path.isdir(app_dir):
        # Cannot continue meaningfully; emit and fail.
        for check in checks:
            print("[%s] %s: %s" % (check.status, check.id, check.detail))
        with open(args.report, "w") as f:
            json.dump({"ipa": args.ipa, "result": "fail", "checks":
                       [c.to_dict() for c in checks], "warnings": []}, f, indent=2)
        print("LAUNCHABILITY_FAILED reason=no app bundle to check")
        sys.exit(6)

    pc, plist = check_plist(app_dir)
    checks.append(pc)
    ec, exe_info = check_executable(app_dir, plist, warnings)
    checks.append(ec)
    warnings.extend(scan_warnings(app_dir, args.payload_dir, plist))

    binaries_checked = 0
    if exe_info is not None:
        dc, binaries_checked = check_dylibs(app_dir, exe_info, warnings,
                                            args.max_binaries)
        checks.append(dc)
        yc, chain_warns = check_symlink_chains(app_dir, args.payload_dir)
        checks.append(yc)
        warnings.extend(chain_warns)

    for check in checks:
        line = "[%s] %s: %s" % (check.status, check.id, check.detail)
        print(line)
        for f in check.failures[:5]:
            print("    FAIL %s" % json.dumps(f))
    for w in warnings:
        print("WARN %s" % w)

    result = "pass" if all(c.status == "pass" for c in checks) else "fail"
    report = {
        "ipa": os.path.basename(args.ipa),
        "bundle": app_name,
        "result": result,
        "checks": [c.to_dict() for c in checks],
        "warnings": warnings,
        "stats": {
            "macho_binaries_analyzed": binaries_checked,
            "min_ios": (exe_info or {}).get("min_ios"),
        },
    }
    with open(args.report, "w") as f:
        json.dump(report, f, indent=2)
    print("report: %s" % args.report)

    if args.resolution_report and os.path.isfile(args.resolution_report):
        with open(args.resolution_report) as f:
            merged = json.load(f)
        merged["launchability"] = {
            "result": result,
            "failed_checks": [c.id for c in checks if c.status == "fail"],
            "warnings": warnings,
            "report": "launchability-report.json",
        }
        with open(args.resolution_report, "w") as f:
            json.dump(merged, f, indent=2)
        print("merged into %s" % args.resolution_report)

    print("RESULT=%s" % result)
    sys.exit(0 if result == "pass" else 6)


if __name__ == "__main__":
    main()
