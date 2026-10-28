#!/usr/bin/env bash
# deb2ipa - hardening_scenario.sh - M7 end-to-end scenario runner
# (SKILL.md M7 mandate, line 80). One script so the exact same code paths
# run locally and in CI (.github/workflows/hardening.yml).
#
# Four scenarios over the REAL pipeline scripts (not mocks):
#   app-with-deps     real NewTerm 3 app deb -> pre-check pass, real repo
#                     resolution, assembly, launchability checklist pass.
#   tweak-rejected    real QuitAll tweak deb -> convertibility pre-check
#                     rejects it BEFORE resolution (exit 2, class=tweak).
#   unsatisfiable-dep synthetic convertible app deb depending on a package
#                     no repo ships -> resolver exit 3 with a named
#                     UNRESOLVED_DEPENDENCY machine line + report.
#   large-deb         ~60 MB incompressible synthetic app deb uploaded as a
#                     DRAFT release asset, re-downloaded through the
#                     fallback path (constraint 7.C), then full green path.
#
# Expected-FAILURE scenarios go green only when the failure is the
# expected, explained one - assertions, not bare exit codes.

set -euo pipefail

SCENARIO="${SCENARIO:?SCENARIO env var required (app-with-deps|tweak-rejected|unsatisfiable-dep|large-deb)}"
WORKDIR="${WORKDIR:?WORKDIR env var required}"

REPOS="${REPOS:-[\"https://repo.chariz.com/\", \"https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/main/binary-iphoneos-arm64/\"]}"
NEWTERM_DEB_URL="${NEWTERM_DEB_URL:-https://repo.chariz.com/debs/ws.hbang.newterm3_3.0~beta1_iphoneos-arm64.deb}"
QUITALL_DEB_URL="${QUITALL_DEB_URL:-https://repo.chariz.com/debs/com.daveapps.quitall_3.0_iphoneos-arm.deb}"
# Local testing can point the large-deb leg at an http URL instead of the
# release-asset upload; remember that so cleanup skips the gh delete.
LARGE_DEB_URL_WAS_SET="${LARGE_DEB_URL:+yes}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fetch_deb.sh
source "$HERE/fetch_deb.sh"

step() { echo; echo "=== $* ==="; }

# ----------------------------------------------------------- helpers ----

run_precheck() { # $1 deb path -> machine line on stdout
  python3 "$HERE/check_convertibility.py" --deb "$1"
}

expect_convertible() { # $1 deb
  local out
  out="$(run_precheck "$1")" || { echo "FAIL: pre-check exited non-zero"; return 1; }
  echo "$out"
  case "$out" in
    CONVERTIBLE\ class=*) ;;
    *) echo "FAIL: expected CONVERTIBLE machine line, got: $out"; return 1 ;;
  esac
}

expect_rejected() { # $1 deb, $2 expected class
  local out code=0
  out="$(run_precheck "$1")" || code=$?
  echo "$out"
  [ "$code" -eq 2 ] || { echo "FAIL: expected pre-check exit 2, got $code"; return 1; }
  case "$out" in
    "NOT_CONVERTIBLE class=$2 "*) ;;
    *) echo "FAIL: expected NOT_CONVERTIBLE class=$2, got: $out"; return 1 ;;
  esac
  echo "PASS: rejected pre-dispatch as $2 with an explanation"
}

run_resolver() { # $1 deb path; resolver exit code becomes the return code
  set +e
  python3 "$HERE/resolve_deps.py" \
    --deb "$1" --workdir "$WORKDIR" --repos "$REPOS" 2>&1 | tee "$WORKDIR/resolve.log"
  local rc="${PIPESTATUS[0]}"
  set -e
  return "$rc"
}

assemble_and_verify() { # $1 deb path, $2 display name
  local deb="$1" name="$2" pkg ver ipa bundle
  pkg="$(dpkg-deb -f "$deb" Package)"
  ver="$(dpkg-deb -f "$deb" Version)"
  step "assemble unsigned IPA ($pkg $ver)"
  bash "$HERE/make_ipa.sh" \
    --debs-dir "$WORKDIR/debs" \
    --workdir "$WORKDIR" \
    --display-name "$name" \
    --version "$ver" \
    --package-name "$pkg" \
    | tee "$WORKDIR/build.log"
  ipa="$(sed -n 's/^IPA_PATH=//p' "$WORKDIR/build.log")"
  bundle="$(sed -n 's/^BUNDLE=//p' "$WORKDIR/build.log")"
  [ -n "$ipa" ] && [ -n "$bundle" ] \
    || { echo "FAIL: no IPA_PATH/BUNDLE in make_ipa output"; return 1; }
  step "launchability checklist"
  python3 "$HERE/check_launchability.py" \
    --ipa "$ipa" \
    --payload-dir "$WORKDIR/ipa/Payload" \
    --report "$WORKDIR/launchability-report.json" \
    --resolution-report "$WORKDIR/resolution-report.json"
  [ -s "$ipa" ] || { echo "FAIL: IPA missing: $ipa"; return 1; }
  [ "$(stat -c%s "$ipa")" -gt $((1024 * 1024)) ] \
    || { echo "FAIL: IPA suspiciously small"; return 1; }
  echo "PASS: $(basename "$ipa") is $(du -h "$ipa" | cut -f1), checklist green"
}

# -------------------------------------------------------- scenarios ----

app_with_deps() {
  step "download real app deb (NewTerm 3)"
  fetch_deb "$NEWTERM_DEB_URL" "$WORKDIR/debs/main.deb"
  expect_convertible "$WORKDIR/debs/main.deb"
  step "resolve against the real Chariz + Procursus indexes"
  run_resolver "$WORKDIR/debs/main.deb"
  step "assemble + verify (full green path, with dependencies)"
  assemble_and_verify "$WORKDIR/debs/main.deb" "NewTerm 3"
}

tweak_rejected() {
  step "download real tweak deb (QuitAll)"
  fetch_deb "$QUITALL_DEB_URL" "$WORKDIR/debs/main.deb"
  step "convertibility pre-check must reject it BEFORE any resolution"
  expect_rejected "$WORKDIR/debs/main.deb" "tweak"
  step "resolution is never reached"
  echo "PASS: pipeline stops pre-dispatch; the workflow's pre-check step"
  echo "turns exit 2 into ::error and the run fails with the explanation."
}

unsatisfiable_dep() {
  step "build synthetic CONVERTIBLE app deb with an unsatisfiable dependency"
  python3 "$HERE/make_fixture_deb.py" \
    --kind unsatisfiable \
    --package com.deb2ipa.hardening --version 1.0 \
    --missing-package com.deb2ipa.nonexistent \
    --out "$WORKDIR/debs/main.deb"
  expect_convertible "$WORKDIR/debs/main.deb"
  step "resolver must fail fast with a named, explained candidate"
  local code=0
  run_resolver "$WORKDIR/debs/main.deb" || code=$?
  [ "$code" -eq 3 ] || { echo "FAIL: expected resolver exit 3, got $code"; return 1; }
  grep -Fq "UNRESOLVED_DEPENDENCY candidates='com.deb2ipa.nonexistent" "$WORKDIR/resolve.log" \
    || { echo "FAIL: UNRESOLVED_DEPENDENCY machine line missing from log"; return 1; }
  # The resolver normalizes version references ("99" -> "99.0"), so assert
  # the named candidate, not an exact version string.
  grep -Fq '"candidates": "com.deb2ipa.nonexistent' "$WORKDIR/resolution-report.json" \
    || { echo "FAIL: resolution report lacks the missing package"; return 1; }
  echo "PASS: unsatisfiable dependency -> exit 3, named candidate, report written"
}

large_deb() {
  step "build ~60 MB incompressible synthetic app deb"
  python3 "$HERE/make_fixture_deb.py" \
    --kind large-app --padding-mb 60 \
    --package com.deb2ipa.hardening --version 2.0 \
    --out "$WORKDIR/large.deb"
  local size
  size="$(stat -c%s "$WORKDIR/large.deb")"
  [ "$size" -gt $((55 * 1024 * 1024)) ] \
    || { echo "FAIL: fixture too small ($size bytes)"; return 1; }
  echo "fixture: $size bytes"

  step "upload as a DRAFT release asset (constraint 7.C fallback)"
  if [ -n "${LARGE_DEB_URL:-}" ]; then
    echo "LARGE_DEB_URL is set - skipping the release upload ($LARGE_DEB_URL)"
  else
    gh release delete hardening-fixtures --cleanup-tag --yes 2>/dev/null || true
    gh release create hardening-fixtures --draft \
      --title "hardening fixtures (auto-deleted by the large-deb scenario)" \
      "$WORKDIR/large.deb"
    LARGE_DEB_URL="https://github.com/${GITHUB_REPOSITORY:?}/releases/download/hardening-fixtures/$(basename "$WORKDIR/large.deb")"
    echo "draft asset: $LARGE_DEB_URL"
  fi

  step "download it back through the draft-asset fallback path"
  rm -f "$WORKDIR/large.deb"   # prove the download, not the local file, feeds the pipeline
  fetch_deb "$LARGE_DEB_URL" "$WORKDIR/debs/main.deb"
  [ "$(stat -c%s "$WORKDIR/debs/main.deb")" -gt $((55 * 1024 * 1024)) ] \
    || { echo "FAIL: downloaded deb too small"; return 1; }
  expect_convertible "$WORKDIR/debs/main.deb"

  step "resolve (fixture has no deps) + assemble + verify"
  run_resolver "$WORKDIR/debs/main.deb"
  assemble_and_verify "$WORKDIR/debs/main.deb" "Hardening Large App"
  local ipa
  ipa="$(sed -n 's/^IPA_PATH=//p' "$WORKDIR/build.log")"
  [ "$(stat -c%s "$ipa")" -gt $((50 * 1024 * 1024)) ] \
    || { echo "FAIL: large scenario IPA should exceed 50 MB"; return 1; }

  step "cleanup draft release"
  if [ -z "$LARGE_DEB_URL_WAS_SET" ]; then
    gh release delete hardening-fixtures --cleanup-tag --yes 2>/dev/null || true
  fi
  echo "PASS: ~60 MB deb survived the full pipeline via the release-asset fallback"
}

# ---------------------------------------------------------- dispatch ----

mkdir -p "$WORKDIR/debs"
case "$SCENARIO" in
  app-with-deps)      app_with_deps ;;
  tweak-rejected)     tweak_rejected ;;
  unsatisfiable-dep)  unsatisfiable_dep ;;
  large-deb)          large_deb ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 64 ;;
esac

echo
echo "HARDENING SCENARIO PASSED: $SCENARIO"
