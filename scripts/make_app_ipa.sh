#!/usr/bin/env bash
# deb2ipa - make_app_ipa.sh - assemble deb2ipa's OWN unsigned .ipa (M8).
#
# Takes the iOS executable produced by `xcodebuild build` on the macos
# runner (SPM executable targets build as a bare Mach-O, NOT a .app),
# wraps it into a hand-assembled .app with a complete Info.plist, packs
# Payload/ with zip, and verifies the archive - so the app ships exactly
# like its own output: unsigned by design, sideloaded with the user's
# tool of choice (AltStore/Sideloadly/any signer). No codesigning.
#
# Info.plist follows the same generation rules as make_ipa.sh: only what
# a SwiftUI App-lifecycle iOS 16 app needs to install and launch.
#
# Runtime deps: bash, python3 (stdlib only), zip, unzip.
#
# Exit codes (machine-readable lines are printed before failure):
#   0  success            - IPA_PATH=/BUNDLE=/EXECUTABLE= lines emitted
#   2  usage / tooling
#   3  EXECUTABLE_NOT_ARM64 - the build product is not an arm64 Mach-O
#   4  ZIP_VERIFY_FAILED    - the archive is not a Payload-rooted IPA
#
# Usage:
#   make_app_ipa.sh --executable <path> --workdir <dir> \
#                   [--name deb2ipa] [--identifier <id>] \
#                   [--display-name <name>] [--version <v>] \
#                   [--build <b>] [--min-ios <v>]

set -euo pipefail

EXE=""
WORKDIR=""
NAME="deb2ipa"
IDENTIFIER=""
DISPLAY_NAME=""
VERSION="0.0.0"
BUILD="1"
MIN_IOS="16.0"

while [ $# -gt 0 ]; do
  case "$1" in
    --executable)    EXE="$2";          shift 2 ;;
    --workdir)      WORKDIR="$2";       shift 2 ;;
    --name)         NAME="$2";          shift 2 ;;
    --identifier)   IDENTIFIER="$2";    shift 2 ;;
    --display-name) DISPLAY_NAME="$2";  shift 2 ;;
    --version)      VERSION="$2";       shift 2 ;;
    --build)        BUILD="$2";         shift 2 ;;
    --min-ios)      MIN_IOS="$2";       shift 2 ;;
    -h|--help)      sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "make_ipa: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$EXE" ]      || { echo "make_app_ipa: --executable is required" >&2; exit 2; }
[ -n "$WORKDIR" ] || { echo "make_app_ipa: --workdir is required" >&2; exit 2; }
[ -f "$EXE" ]     || { echo "make_app_ipa: executable not found: $EXE" >&2; exit 2; }

# Default identifier mirrors make_ipa.sh's fallback scheme.
[ -n "$IDENTIFIER" ]   || IDENTIFIER="io.github.ddr-ai.deb2ipa"
[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$NAME"

STAGE="$WORKDIR/app-staging"    # the .app being assembled
PACK="$WORKDIR/ipa"             # Payload/ root, exactly like make_ipa.sh
OUT_DIR="$WORKDIR/out"
rm -rf "$STAGE" "$PACK" "$OUT_DIR"
mkdir -p "$STAGE/$NAME.app" "$PACK/Payload" "$OUT_DIR"

echo "[make_app_ipa] executable: $EXE ($(stat -f%z "$EXE" 2>/dev/null || stat -c%s "$EXE") bytes)"

# ------------------------------------------- 1. arm64 Mach-O sniff ----
ARM64_OK="$(python3 - "$EXE" <<'EOF'
import struct, sys
data = open(sys.argv[1], "rb").read(16)
if len(data) >= 4:
    magic = struct.unpack("<I", data[:4])[0]
    if magic == 0xFEEDFACF and struct.unpack("<I", data[4:8])[0] == 0x0100000C:
        print("thin-arm64"); sys.exit(0)
    if data[:4] == b"\xca\xfe\xba\xbe":
        nfat = struct.unpack(">I", data[4:8])[0]
        blob = open(sys.argv[1], "rb").read(nfat * 20 + 8)
        for i in range(nfat):
            off = 8 + i * 20
            if struct.unpack(">I", blob[off:off+4])[0] == 0x0100000C:
                print("fat-arm64"); sys.exit(0)
print("no")
EOF
)" || ARM64_OK="no"
if [ "$ARM64_OK" = "no" ]; then
  echo "EXECUTABLE_NOT_ARM64"
  echo "make_app_ipa: $EXE is not an arm64 Mach-O (thin or fat arm64 slice)" >&2
  exit 3
fi
echo "[make_app_ipa] arm64 Mach-O: $ARM64_OK"

# ------------------------------------------- 2. assemble the .app ----
cp "$EXE" "$STAGE/$NAME.app/$NAME"
chmod 755 "$STAGE/$NAME.app/$NAME"

python3 - "$STAGE/$NAME.app/Info.plist" <<EOF
import plistlib, sys
info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": """$DISPLAY_NAME""",
    "CFBundleExecutable": "$NAME",
    "CFBundleIdentifier": """$IDENTIFIER""",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "$NAME",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$VERSION",
    "CFBundleVersion": "$BUILD",
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "$MIN_IOS",
    "UIApplicationSceneManifest": {
        "UIApplicationSupportsMultipleScenes": False,
    },
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "ITSAppUsesNonExemptEncryption": False,
}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(info, fh)
EOF
echo "[make_app_ipa] Info.plist: identifier=$IDENTIFIER version=$VERSION build=$BUILD min-ios=$MIN_IOS"

# ------------------------------------------- 3. pack Payload/ ----
cp -a "$STAGE/$NAME.app" "$PACK/Payload/$NAME.app"
(
  cd "$PACK"
  zip -q -r -y "$OUT_DIR/${NAME}-${VERSION}-unsigned.ipa" Payload
)
IPA="$OUT_DIR/${NAME}-${VERSION}-unsigned.ipa"
echo "[make_app_ipa] packed $IPA ($(du -h "$IPA" | cut -f1))"

# ------------------------------------------- 4. verify the archive ----
unzip -Z1 "$IPA" > "$WORKDIR/ipa-listing.txt"
if bad="$(grep -v '^Payload/' "$WORKDIR/ipa-listing.txt" | head -n1)" && [ -n "$bad" ]; then
  echo "ZIP_VERIFY_FAILED"
  echo "make_app_ipa: entry outside Payload/: $bad" >&2
  exit 4
fi
grep -qx "Payload/$NAME.app/Info.plist" "$WORKDIR/ipa-listing.txt" \
  || { echo "ZIP_VERIFY_FAILED"; echo "make_app_ipa: Info.plist not at the bundle root" >&2; exit 4; }
grep -qx "Payload/$NAME.app/$NAME" "$WORKDIR/ipa-listing.txt" \
  || { echo "ZIP_VERIFY_FAILED"; echo "make_app_ipa: executable missing from the bundle" >&2; exit 4; }
echo "[make_app_ipa] verified: $(wc -l < "$WORKDIR/ipa-listing.txt") entries, all under Payload/"

echo "IPA_PATH=$IPA"
echo "BUNDLE=$NAME.app"
echo "EXECUTABLE=$NAME"
