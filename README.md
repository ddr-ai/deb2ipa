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

## Credits

- Precedent for the deb-to-ipa technique: itsnebulalol/deb-to-ipa and sourcelocation/DebToIPA.
- Archive parsing in-app: tsolomko/SWCompression (MIT).
- MIT licensed.
