# deb2ipa

An iOS app that takes **any Debian package (.deb)**, reads its metadata, resolves its full dependency tree against jailbreak apt repositories, and builds an installable **unsigned .ipa** via **GitHub Actions** - ready for TrollStore, AltStore, or Sideloadly.

    +--------+   parse ar +      +----------------+   workflow_dispatch   +------------------+
| deb    |   control.tar   | Classification |  ------------------>  | GitHub Actions   |
| file   | ------------->  | + metadata view |                      | (ubuntu-latest)  |
+--------+                 +----------------+                      | download deps    |
      ^                                                             | assemble Payload |
      |                                                             | zip unsigned ipa |
   import or URL                                                    +--------+---------+
      |                                                                      |
      |                                                            publish Release
      |                                                                      v
      |                                                            +------------------+
      +----------------------------------------------------------- | download + hand  |
         TrollStore (apple-magnifier://) / AltStore / share sheet   | off to install   |
                                                                    +------------------+

## What it does

- **Parses every deb** - even debs that cannot be converted get full metadata, dependency tree, and an explanation of why not.
- **Classifies**: iOS app-type debs (contain a .app bundle) are convertible; tweak debs and Linux debs are not, and the app tells you exactly why.
- **Resolves dependencies** - the Actions runner fetches Packages indexes from Chariz, Havoc, Procursus, Sileo, BigBoss and any custom repos you add, picks correct versions with real apt version-comparison, and downloads them.
- **Builds unsigned IPAs** - no developer certificate anywhere in the pipeline: pure dpkg-deb extraction plus zip on a Linux runner. TrollStore installs as-is; AltStore/Sideloadly re-sign at install.
- **Self-hosting**: a second workflow (tags only) builds deb2ipa itself into an unsigned ipa on a macOS runner, so the app is installed exactly like its own output.

## Status

Planning complete - see SKILL.md for the governing build plan and milestone breakdown. Build in progress.

## Credits

- Precedent for the deb-to-ipa technique: itsnebulalol/deb-to-ipa and sourcelocation/DebToIPA.
- Archive parsing in-app: tsolomko/SWCompression (MIT).
- MIT licensed.
