#!/usr/bin/env bash
#
# deb2ipa - make_ipa.sh - assemble an unsigned .ipa from resolved .debs.
# Milestone M4 of the deb2ipa plan (see SKILL.md in the repo root).
#
# Takes a directory of .deb files (root package + resolved dependencies),
# extracts them into one merged rootfs, finds the outermost .app bundle,
# and packs it into Payload/ with the jailbreak bootstrap relocated inside
# the bundle. Unsigned by design: the user sideloads with their own tool
# (AltStore, Sideloadly, ...). No signing, no TrollStore assumption.
#
# Runtime deps: bash, dpkg-deb, python3 (stdlib only), zip, unzip, file.
#
# Exit codes (machine-readable lines are printed before failure):
#   0  success            - IPA_PATH=/BUNDLE=/EXECUTABLE= lines emitted
#   2  usage / tooling
#   3  NO_APP_BUNDLE      - no *.app directory in the merged root
#   4  MISSING_EXECUTABLE - Info.plist CFBundleExecutable absent on disk
#   5  ZIP_VERIFY_FAILED  - archive does not have Payload/ at its root
#
set -euo pipefail

DEBS_DIR=""
WORKDIR=""
BUNDLE_ID=""
DISPLAY_NAME=""
VERSION="1.0"
MIN_IOS="14.0"
PACKAGE_NAME=""
HUMAN_NAME=""

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'
Usage:
  make_ipa.sh --debs-dir <dir> --workdir <dir> \
              [--bundle-id <id>] [--display-name <name>] \
              [--version <v>] [--min-ios <v>] \
              [--package-name <id>] [--name <human name>]
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debs-dir)     DEBS_DIR="$2";     shift 2 ;;
    --workdir)      WORKDIR="$2";      shift 2 ;;
    --bundle-id)    BUNDLE_ID="$2";    shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --version)      VERSION="$2";       shift 2 ;;
    --min-ios)      MIN_IOS="$2";      shift 2 ;;
    --package-name) PACKAGE_NAME="$2"; shift 2 ;;
    --name)         HUMAN_NAME="$2";   shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$DEBS_DIR" && -n "$WORKDIR" ]] || usage
[[ -d "$DEBS_DIR" ]] || { echo "debs dir not found: $DEBS_DIR"; exit 2; }
for tool in dpkg-deb python3 zip unzip file; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool missing: $tool"; exit 2; }
done

mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"   # absolute: we pushd around below
DEBS_DIR="$(cd "$DEBS_DIR" && pwd)"

log()  { printf '[make_ipa] %s\n' "$*"; }
fail() { printf '%s\n' "$2"; exit "$1"; }

ROOT="$WORKDIR/merged"          # merged rootfs extracted from all debs
IPA_DIR="$WORKDIR/ipa"          # staging dir; contains exactly Payload/
OUT_DIR="$WORKDIR/out"
rm -rf "$ROOT" "$IPA_DIR" "$OUT_DIR"
mkdir -p "$ROOT" "$IPA_DIR/Payload" "$OUT_DIR"

# ---------------------------------------------------------------- 1. extract
shopt -s nullglob
debs=("$DEBS_DIR"/*.deb)
[[ ${#debs[@]} -gt 0 ]] || fail 3 "NO_APP_BUNDLE found=no .deb files in $DEBS_DIR"
for d in "${debs[@]}"; do
  dpkg-deb -x "$d" "$ROOT"
done
log "extracted ${#debs[@]} deb(s) into merged root"

# ------------------------------------------- 2. find the outermost .app dir
app_rel="$(cd "$ROOT" && find . -type d -name '*.app' -print \
           | awk -F/ '{print NF-1, $0}' | sort -n | head -n1 | cut -d' ' -f2-)"
[[ -n "$app_rel" ]] || fail 3 "NO_APP_BUNDLE found=no *.app directory in merged root"
app_rel="${app_rel#./}"
app_name="$(basename "$app_rel")"        # e.g. NewTerm.app
bundle="${app_name%.app}"                # e.g. NewTerm
log "app bundle: /$app_rel"

other_apps="$(cd "$ROOT" && find . -type d -name '*.app' -print \
             | { grep -v -F "./$app_rel" || true; } | wc -l)"
if [[ "$other_apps" -gt 0 ]]; then
  log "WARNING: $other_apps additional .app bundle(s) present; only $app_name will be packaged"
fi

# ------------------------------------- 3. copy the bundle into Payload/ ----
cp -a "$ROOT/$app_rel" "$IPA_DIR/Payload/$app_name"

# ------- 4. relocate the bootstrap root that surrounds the application -----
# Rootless layout  /var/jb/Applications/X.app : everything else under /var/jb
# Classic layout   /Applications/X.app       : everything else under /
# Nonstandard spot (Library/Custom/X.app ...) : bootstrap root is the merged
# root itself. In every case the leftover bootstrap lands inside the bundle
# at .jbroot/ so nothing is thrown away. The pieces that actually matter for
# launch (dylib relocation, RPATH, shell lookup) are milestone M5's
# launchability work; M4 keeps the mechanical move.
parent_name="$(basename "$(dirname "$app_rel")")"
if [[ "$parent_name" == "Applications" ]]; then
  jb_rel="$(dirname "$(dirname "$app_rel")")"   # "" means the merged root itself
else
  jb_rel=""
fi
# Path of the app relative to the bootstrap root (""-safe).
app_in_jb="${app_rel#"$jb_rel"}"
app_in_jb="${app_in_jb#/}"
DEST="$IPA_DIR/Payload/$app_name/.jbroot"
mkdir -p "$DEST"
moved=0
shopt -s dotglob
pushd "$ROOT${jb_rel:+/$jb_rel}" >/dev/null
for entry in *; do
  [[ "$entry" == "Applications" ]] && continue   # other .app bundles: skipped above
  cp -a "$entry" "$DEST/"
  moved=$((moved + 1))
done
popd >/dev/null
shopt -u dotglob
# Never keep a duplicate of the app itself under .jbroot/ (happens when the
# bundle sits at the root of the merged rootfs, or under a nonstandard dir
# that gets copied wholesale).
if [[ -n "$app_in_jb" && -e "$DEST/$app_in_jb" ]]; then
  rm -rf "$DEST/$app_in_jb"
  log "removed self-duplicate $app_in_jb from .jbroot/"
fi
# Recount what actually remains after the removal.
moved="$(find "$DEST" -mindepth 1 -maxdepth 1 | wc -l)"
if [[ "$moved" -gt 0 ]]; then
  log "relocated $moved bootstrap entr(y/ies) into $app_name/.jbroot/"
else
  log "no bootstrap content to relocate"
fi

# M5: strip the rootless prefix from symlink targets inside .jbroot/ so the
# relocated bootstrap is self-contained: /var/jb/usr/bin/cat becomes a
# relative ../usr/bin/cat that resolves INSIDE the bundle instead of
# dangling on a stock device. Unmappable targets are left in place - the
# launchability checklist (check_launchability.py) reports them.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sr_out="$(python3 - "$DEST" "$SCRIPT_DIR" <<'PYEOF'
import os, sys

dest, _script_dir = sys.argv[1], sys.argv[2]
rewritten = dangling = 0
for root, dirs, files in os.walk(dest, followlinks=False):
    for name in dirs + files:
        p = os.path.join(root, name)
        if not os.path.islink(p):
            continue
        target = os.readlink(p)
        if not target.startswith("/"):
            continue                        # already relative: leave it alone
        # Strip known bootstrap prefixes: rootless /var/jb first, then the
        # classic rootfs / - then re-point inside .jbroot when the target
        # file was relocated too.
        for prefix in ("/var/jb/", "/"):
            if target.startswith(prefix):
                stripped = target[len(prefix.rstrip("/")):] if prefix != "/" else target
                candidate = os.path.join(dest, stripped.lstrip("/"))
                if os.path.exists(candidate):
                    rel = os.path.relpath(candidate, os.path.dirname(p))
                    os.unlink(p)
                    os.symlink(rel, p)
                    rewritten += 1
                else:
                    dangling += 1
                break
print("symlink rewrite: %d rewritten, %d left dangling (reported by the checker)" %
      (rewritten, dangling))
PYEOF
)"
log "$sr_out"

substrate_n="$(find "$IPA_DIR/Payload" -path '*MobileSubstrate*' | wc -l)"
if [[ "$substrate_n" -gt 0 ]]; then
  log "WARNING: $substrate_n MobileSubstrate path(s) relocated into the bundle; they cannot function jailed (checker reports details)"
fi

# ------------------------------------------------------- 5. Info.plist -----
# M5 generation rules (only when the bundle has no Info.plist of its own):
#   CFBundleIdentifier  --bundle-id > control Package (sanitized) > fallback
#   CFBundleExecutable  detected from the bundle (the .app name; validated
#                       on disk in stage 6)
#   CFBundleName/       --display-name > control Name > bundle name
#     CFBundleDisplayName
#   MinimumOSVersion    --min-ios, but never below what the executable's
#                       LC_BUILD_VERSION/LC_VERSION_MIN_IPHONEOS declares
PLIST="$IPA_DIR/Payload/$app_name/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  log "no Info.plist in bundle; generating a minimal one"
  python3 - "$PLIST" "$bundle" "$BUNDLE_ID" "$DISPLAY_NAME" "$VERSION" \
              "$MIN_IOS" "$PACKAGE_NAME" "$HUMAN_NAME" \
              "$IPA_DIR/Payload/$app_name" "$SCRIPT_DIR" <<'PYEOF'
import os, plistlib, re, sys

sys.path.insert(0, sys.argv[10])
import macho

(path, bundle, bundle_id, display, version, min_ios,
 package, human, app_dir) = sys.argv[1:10]


def sanitize(s):
    return re.sub(r"[^A-Za-z0-9.-]+", "-", s or "").strip("-.")


# CFBundleIdentifier priority: explicit --bundle-id > control Package >
# deterministic fallback from the bundle name.
if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id or ""):
    cand = sanitize(package)
    if cand and "." in cand:
        bundle_id = cand
    else:
        bundle_id = "io.github.ddr-ai.deb2ipa." + (sanitize(bundle) or "app")

name = display or human or bundle

# MinimumOSVersion: honor --min-ios unless the arm64 slice demands more.
try:
    with open(os.path.join(app_dir, bundle), "rb") as f:
        info = macho.analyze(f.read(1 << 20))
    declared = info.get("min_ios")
    if declared:
        want = [int(x) for x in min_ios.split(".")[:2]]
        have = [int(x) for x in declared.split(".")[:2]]
        if have > want:
            min_ios = declared
except OSError:
    pass

plist = {
    "CFBundleName":            name,
    "CFBundleDisplayName":     name,
    "CFBundleIdentifier":      bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType":     "APPL",
    "CFBundleExecutable":      bundle,
    "CFBundleVersion":         "1",
    "CFBundleShortVersionString": version,
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "MinimumOSVersion":        min_ios,
}
with open(path, "wb") as f:
    plistlib.dump(plist, f)
PYEOF
else
  log "using the bundle's own Info.plist"
fi

# --------------------------------------------------- 6. validate launcher --
EXE="$(python3 - "$PLIST" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
print(d.get("CFBundleExecutable", ""))
PYEOF
)"
[[ -n "$EXE" ]] || fail 4 "MISSING_EXECUTABLE bundle=$app_name reason=Info.plist has no CFBundleExecutable"
[[ -e "$IPA_DIR/Payload/$app_name/$EXE" ]] \
  || fail 4 "MISSING_EXECUTABLE bundle=$app_name executable=$EXE reason=not on disk"

exe_real="$(readlink -f "$IPA_DIR/Payload/$app_name/$EXE")"
exe_info="$(file "$exe_real")"
if grep "Mach-O" <<<"$exe_info" >/dev/null; then
  if ! grep "arm64" <<<"$exe_info" >/dev/null; then
    log "WARNING: CFBundleExecutable is Mach-O but not arm64; sideload will likely fail"
  fi
else
  log "WARNING: CFBundleExecutable is not a Mach-O binary: $exe_info"
fi

# ------------------------------------------------------------- 7. zip ------
IPA="$OUT_DIR/$bundle.ipa"
rm -f "$IPA"
( cd "$IPA_DIR" && zip -q -r -y "$IPA" . )
log "packed $IPA ($(du -h "$IPA" | cut -f1))"

# ---------------------------------------------------------- 8. verify ------
# Listing captured once: grep -q would exit at the first match and leave
# unzip dying on a SIGPIPE, which pipefail would report as a failure.
listing="$(unzip -Z1 "$IPA")"
first_bad="$(printf '%s\n' "$listing" | { grep -v '^Payload/' || true; } | head -n1)"
[[ -z "$first_bad" ]] || fail 5 "ZIP_VERIFY_FAILED reason=entry outside Payload/: $first_bad"
printf '%s\n' "$listing" | grep -xF "Payload/$app_name/Info.plist" >/dev/null \
  || fail 5 "ZIP_VERIFY_FAILED reason=Payload/$app_name/Info.plist missing from archive"

# ------------------------------------------------------------ 9. outputs ---
echo "IPA_PATH=$IPA"
echo "BUNDLE=$app_name"
echo "EXECUTABLE=$EXE"
if [[ "$moved" -gt 0 ]]; then
  echo "JBROOT=$app_name/.jbroot"
fi
