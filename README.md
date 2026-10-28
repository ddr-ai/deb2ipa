# deb2ipa

An iOS app that takes **any mobile arm64 .deb** - jailbreak-repo apps, GitHub-release debs, or any deb containing an arm64 `.app` bundle - reads its metadata, resolves its dependency tree, and builds an **unsigned .ipa that actually runs** via **GitHub Actions** - for you to sideload on your own iPhone with your preferred tool (AltStore, Sideloadly, or any other).

    +--------+   parse ar +      +----------------+   workflow_dispatch   +------------------+
| deb    |   control.tar   | Classification |  ------------------>  | GitHub Actions   |
| file   | ------------->  | + metadata view |                      | (ubuntu-24.04)  |
+--------+                 +----------------+                      | download deps    |
      ^                                                             | assemble Payload |
      |                                                             | zip unsigned ipa |
   import or URL                                                    +--------+---------+
      |                                                                      |
      |                                                            publish Release
      |                                                                      v
      |                                                            +------------------+
      +----------------------------------------------------------- | download + hand  |
         AltStore / share sheet / your sideloading tool   | off to install   |
                                                                    +------------------+

## What it does

- **Parses every deb** - even debs that cannot be converted get full metadata, dependency tree, and an explanation of why not.
- **Classifies** (content-based, source-agnostic): any deb with an arm64 `.app` bundle is convertible, wherever it came from; tweak-only debs, theme packs and Linux debs are not, and the app tells you exactly why.
- **Resolves dependencies** - the Actions runner fetches Packages indexes from Chariz, Havoc, Procursus, Sileo, BigBoss and any custom repos you add, picks correct versions with real apt version-comparison, and downloads them.
- **Builds unsigned IPAs** - no developer certificate anywhere in the pipeline: pure dpkg-deb extraction plus zip on a Linux runner. AltStore/Sideloadly re-sign at install time; the same artifact works with any sideloading tool you prefer.
- **Self-hosting**: a second workflow (tags only) builds deb2ipa itself into an unsigned ipa on a macOS runner, so the app is installed exactly like its own output.

## Status

Planning complete - see SKILL.md for the governing build plan and milestone breakdown.

**M1 complete:** the on-device parser package (**DebKit**) is implemented - ar reader, control extraction, DebControl parsing, Depends expressions, and a dpkg-exact Debian version comparator. All unit tests (including real dpkg-deb fixtures for xz/gzip) run green in CI on every push.

**M2 complete:** the classifier reads data.tar, sniffs binaries from their magic numbers (thin arm64 Mach-O, fat Mach-O with an arm64 slice, ELF), finds .app bundles anywhere in the payload, and sorts every deb into five content-based classes - app (convertible when an arm64 executable sits in the bundle), tweak, iOS CLI tools, desktop binaries, or data-only - with a human-readable reason list for every verdict. Tested against 8 real dpkg-deb fixtures in CI.

**M3 complete:** the GitHub API client is in - Keychain-backed PAT storage (protocol-based, with an in-memory store for tests and Linux CI), workflow dispatch with the automatic once-only retry on 404/422 (workflow not synced yet), run polling with 2-30 s exponential backoff and ETag caching (304 responses are rate-limit free), failure-log and release-asset download, and typed, human-readable errors for every failure mode. The workflow input contract with the M4 build (deb_url, package_name, version, bundle_id, display_name, repos, extra_debs) is fixed and tested. 18 tests replay real GitHub API payloads through a scripted transport, and a live test dispatches a real no-op hello workflow whenever a PAT is available (repo secret DEB2IPA_TOKEN or on-device run; see docs/PAT-SETUP.md).

**M4 complete:** the build pipeline is live. `.github/workflows/build-ipa.yml` turns a deb URL into an unsigned `.ipa` on GitHub's ubuntu-24.04 runner: it downloads the root deb, resolves the full dependency closure with the in-repo Python resolver (dpkg-exact version comparison, Provides/alternatives, device-bootstrap virtuals) against Chariz, Procursus and any custom repos you pass, merges every deb's file tree, relocates the surrounding jailbreak bootstrap into the `.app` bundle, generates or validates Info.plist, and packs a Payload-rooted zip that is verified twice before anything is published. The Release carries the `.ipa`, a machine-readable `resolution-report.json` and the full build log - plus an in-workflow asset gate that fails the build if they are missing. Since `GITHUB_TOKEN` cannot start runs but a push can, every change to the pipeline also runs a smoke conversion of NewTerm 3 (a real rootless app; 19 dependencies resolved from Chariz + Procursus, 0 warnings) that publishes only a *draft* release - latest output: a 24 MB `NewTerm.ipa`, all 5021 entries under `Payload/`, arm64 executable and 1111 symlinks intact.

## Credits

- Precedent for the deb-to-ipa technique: itsnebulalol/deb-to-ipa and sourcelocation/DebToIPA.
- Archive parsing in-app: tsolomko/SWCompression (MIT).
- MIT licensed.
