#!/usr/bin/env bash
# deb2ipa - fetch_deb.sh - shared deb downloader (M7, constraint 7.C).
#
# Public URLs go through plain curl. Draft-release asset URLs (the
# large-deb fallback: upload the deb as a DRAFT release asset, pass that
# URL) need authentication, and the redirect they return is signed -
# `curl -L` would resend the Authorization header to the signed
# objects.githubusercontent.com target and get rejected. So release-asset
# URLs on github.com go through `gh release download`, which handles the
# two-step auth dance correctly.
#
# Sourced (not executed): provides fetch_deb <url> <dest-path>.
# Env: GH_TOKEN or GITHUB_TOKEN enables the draft-asset path.

fetch_deb() { # $1 = url, $2 = destination path
  local url="$1" dest="$2"
  case "$url" in
    https://github.com/*/releases/download/*)
      if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        # https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
        local rest owner repo tag file
        rest="${url#https://github.com/}"
        owner="${rest%%/*}"
        rest="${rest#*/}"
        repo="${rest%%/*}"
        file="${url##*/}"
        tag="$(basename "$(dirname "$url")")"
        if gh release view "$tag" --repo "$owner/$repo" >/dev/null 2>&1; then
          echo "fetch_deb: release asset '$file' from $owner/$repo tag '$tag' (draft-asset path)"
          gh release download "$tag" --repo "$owner/$repo" \
            --pattern "$file" --output "$dest"
          return 0
        fi
        # Not a release in this repo (or gh failed): fall through to curl
        # so public release assets still work without the token dance.
        echo "fetch_deb: '$tag' is not a release in $owner/$repo; trying plain curl"
      fi
      ;;
  esac
  echo "fetch_deb: $url"
  curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
}
