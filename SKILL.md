---
name: deb2ipa
description: Governing build plan for deb2ipa - a SwiftUI iOS app that parses any .deb package, resolves its full dependency tree against jailbreak apt repositories, and builds an installable unsigned .ipa via GitHub Actions for TrollStore or AltStore/Sideloadly sideloading. Follow this document for every build, fix, or extension of deb2ipa.
---

# deb2ipa - Project Build Plan (governing document)

## 1. What deb2ipa is

**Purpose.** deb2ipa is an iOS app that lets its owner take any Debian package (.deb), read its metadata, understand its dependency tree, and - when the package is an iOS-targeted app package - convert it into an installable unsigned .ipa by dispatching a GitHub Actions build. The Actions runner downloads the deb, downloads every dependency at a correct version from jailbreak apt repositories, and repackages everything into a Payload-based ipa published as a GitHub Release.

**Core features.**
1. On-device parsing of any .deb: package, name, version, architecture, maintainer, description, Depends/Pre-Depends.
2. Dependency tree inspection with apt-style version constraints.
3. Convertibility classification: iOS app-type deb / iOS tweak-type deb / non-iOS deb.
4. One-tap dispatch of a GitHub Actions build with the deb URL and repo list as inputs.
5. Live build status, logs, and a machine-readable resolution report.
6. Download of the finished unsigned .ipa from the Release, with handoff to TrollStore or AltStore, or the share sheet.
7. Parses ALL debs even when unconvertible - unconvertible ones get metadata + a clear explanation.

**Target users.** The owner (a jailbreak/TrollStore user) converting legitimately obtained free packages for personal sideloading. Not a distribution or piracy tool; the repo stays private.

## 2. Tech stack and platforms (decided - do not relitigate without user request)

- **Primary: Swift 5.9+ / SwiftUI**, deployment target iOS 16.0, Swift Package Manager. Native wins for a single-platform iOS tool: first-class file handling, Swift concurrency for parsing large debs off the main actor, and no bridging overhead. Performance/stability first.
- **Sole third-party Swift dependency: SWCompression (MIT)** for TAR/XZ/GZip reads. The ar container format is parsed by ~100 lines of in-house Swift. No other dependencies.
- **Build side: GitHub Actions on ubuntu-latest** + bash + dpkg-deb (preinstalled) + Python 3 (stdlib only) resolver. No macOS runner on the deb-to-ipa path, no Xcode, no signing.
- **Rejected fallback: Flutter/Dart** - no mature TAR/XZ parsing; only reconsider if Android becomes a target.
- **Platforms.** App: iOS 16+ (TrollStore device compatibility reaches iOS 14-17.x). Builds: GitHub-hosted Linux runners. Output: unsigned .ipa consumed by TrollStore (direct install) or AltStore/Sideloadly (re-signs at install).

## 3. Repository layout

    deb2ipa/
      app/
        Sources/
          DebParser/            # ar reader, control.tar extraction, DebControl model
          AptVersion/           # Debian version comparison port (Swift)
          Classifier/           # app-type vs tweak vs non-iOS detection
          GitHubAPI/            # PAT store, dispatch, polling, logs, releases
          Views/                # SwiftUI screens
        appTests/               # unit tests incl. real deb fixtures
      .github/workflows/
        build-ipa.yml           # workflow_dispatch: deb -> unsigned ipa (ubuntu-latest)
        build-app.yml           # builds the deb2ipa app itself as unsigned ipa (macos-latest, tags only)
      scripts/
        resolve_deps.py         # dependency resolver + version comparison
        make_ipa.sh             # Payload assembly, Info.plist rules, zip --symlinks
      docs/
        PAT-SETUP.md            # fine-grained PAT instructions
        REPOS.md                # known jailbreak apt repo URLs
      SKILL.md                  # this document
      README.md

## 4. Core data flow

1. User imports a .deb via the Files app or pastes a URL.
2. App parses ar -> control.tar.xz/.gz -> control file, shows metadata and the Depends tree.
3. App classifies convertibility (see M2). Unconvertible -> explanation screen, no dispatch.
4. App POSTs a workflow_dispatch with inputs: deb_url, package_name, version, bundle_id, display_name, repos (JSON list), extra_debs (optional URLs).
5. Workflow: download deb -> resolver fetches repo Packages indexes -> picks and downloads dependency debs -> extracts all file trees -> locates the .app bundle -> merges files -> generates/validates Info.plist -> zips Payload -> creates a Release with the unsigned .ipa + resolution-report.json + build log.
6. App polls the run, then downloads the .ipa asset and offers TrollStore/AltStore/share-sheet handoff.

## 5. Phased build plan (milestones - build in order)

- **M0 - Scaffold.** README, SKILL.md, .gitignore, directory layout, empty workflow skeletons. Done: when this commit lands.
- **M1 - Deb parser (Swift).** ArReader (global header !<arch>, member size fields, note the 60-char name / 10-byte size format), ControlExtractor supporting control.tar.xz/.gz/plain via SWCompression, DebControl model, Depends parsing (comma groups, pipe alternatives, version operators << <= = >= >>), Debian version comparison port. Acceptance: unit tests parse a real Chariz deb and pass a version-comparison table (epoch, upstream, debian revision, tilde-sorts-before-everything).
- **M2 - Classifier.** List data.tar.* entries; app-type = contains Applications/*.app or var/jb/Applications/*.app; tweak-type = has Library/MobileSubstrate or dylibs but no .app; non-iOS = arch amd64/i386/all with Linux ELF binaries. Acceptance: three fixture debs classified correctly.
- **M3 - GitHub API client (Swift).** Keychain PAT store; dispatch with retry-once after 5 s on 404/422 (workflow not on default branch yet); run polling with exponential backoff (2->30 s cap) and ETag caching; log fetch on failure; release asset download to Files app. Acceptance: dispatches a hello-world workflow and observes completion from an iOS unit test.
- **M4 - The build workflow.** .github/workflows/build-ipa.yml: workflow_dispatch with the inputs above, permissions: contents: write, timeout-minutes: 30; steps: apt-get install zip -> download main deb -> scripts/resolve_deps.py (downloads deps) -> make_ipa.sh (assemble + zip) -> verify Payload/ is at archive root -> gh release create with the ipa, report JSON and log. Acceptance: a known free app deb converts into a TrollStore-installable ipa on the first real run.
- **M5 - IPA assembly quality.** Info.plist generation rules (CFBundleIdentifier sanitized from package name, CFBundleExecutable detected from the bundle, MinimumOSVersion default 14.0, CFBundleName from Name field); zip with --symlinks to preserve dylib symlinks; nested .app handling (outermost wins); strip rootless prefix var/jb/ when relocating into the bundle; emit warnings for files that cannot function jailed (MobileSubstrate dylibs etc.).
- **M6 - SwiftUI app.** Screens: Import, Metadata/Depends tree, Build status, Releases/downloads, Settings (PAT, repos, default install target). Handoffs: TrollStore scheme apple-magnifier://install-url=<ipa url>, AltStore scheme altstore://install?url=<ipa url>, share-sheet fallback. Never let a parser error crash - map every failure to a typed, explained state.
- **M7 - Tests and hardening.** Resolver fixture tests against real Packages indexes; workflow smoke-tested on: app deb with deps, tweak deb (rejected pre-dispatch), unsatisfiable dependency (clear failure log), large deb via the release-asset fallback path.
- **M8 - Self-hosting release.** build-app.yml on macos-latest, triggered by version tags only: xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO build, collect the .app from DerivedData, zip into Payload, attach the app's own unsigned ipa to a GitHub Release so deb2ipa can be TrollStore-installed exactly like its own output. Still certificate-free.

## 6. Unsigned IPA strategy (no certificates, ever)

- The deb-to-ipa path runs entirely on ubuntu-latest: dpkg-deb extraction plus zip. No codesigning, no provisioning profiles, no Xcode.
- TrollStore installs the unsigned ipa directly (perma-signs via CoreTrust).
- AltStore/Sideloadly re-sign at install time; the same unsigned artifact serves both paths.
- The only macOS-runner step is M8 (building the app itself) and it is still signing-free via CODE_SIGNING_ALLOWED=NO.

## 7. Pre-empted build errors and baked-in solutions

- **A. workflow_dispatch 404/422** - the workflow file must be on the default branch before first dispatch; the app retries once after 5 s and surfaces "workflow not synced yet" if it still fails.
- **B. PAT 401/403** - fine-grained PAT scoped to ONLY this repository with Contents: read+write and Actions: read+write (docs/PAT-SETUP.md); the app validates the token with GET /user and a repo workflow list before first use.
- **C. Large deb input** - the Contents API hard limit is 100 MB (warn at 50 MB). Primary path passes a direct deb URL (from a repo Packages index or a release asset). Fallback: upload the deb as a draft release asset (2 GiB limit) and pass that URL. Never commit debs to git.
- **D. Unsatisfiable dependency** - the resolver exits non-zero naming the package, the constraint, and every repo searched; the workflow log line is machine-parseable so the app shows a human missing-deps screen.
- **E. macOS runner cost on a private repo** - macOS bills at 10x minutes; M8 runs on tags only (~200 macOS minutes/month within the free 2000-minute allotment). If build volume grows, either make the repo public (unlimited free minutes; the code is open-source anyway) or build locally in Xcode. User decision; default: tags only.
- **F. zip and symlinks** - explicit apt-get install -y zip step; zip with --symlinks so dylib symlinks survive; verify Payload/ sits at the archive root before upload.
- **G. Missing Info.plist / tweak debs** - generate a minimal Info.plist when one is absent; reject tweak-type debs on-device before dispatch with an explanation (they inject into other apps and cannot run standalone).
- **H. Non-iOS architectures** - metadata still parses and displays; building is blocked with an explicit reason (Linux ELF binaries cannot run on iOS).
- **I. HTTP-only apt repos (e.g. BigBoss)** - only the Linux runner fetches repo indexes; the iOS app exclusively talks to api.github.com over HTTPS and never fetches repo indexes itself.
- **J. API rate limits** - polling uses exponential backoff with ETag caching; dispatch and polling are the only unauthenticated-adjacent calls (all use the PAT).
- **K. Pathological dependency trees** - resolver depth cap 25, 200 MB per-package cap, 400 packages max; timeout-minutes: 30 on the job.

## 8. Dependency resolution spec (scripts/resolve_deps.py)

- Fetch each repo's Packages index; try Packages.xz, then Packages.gz, then Packages (lzma/gzip from stdlib).
- Parse control stanzas; index by Package name.
- Version comparison: the full Debian algorithm (numeric prefix, optional epoch, upstream, debian revision; tilde sorts before empty; letters sort before non-letters). Same code ported to Swift for M1.
- Resolve Depends and Pre-Depends; for pipe alternatives pick the first satisfiable candidate; recursive, cycle-safe, depth-capped. Ignore Recommends/Suggests unless a flag includes them.
- Download chosen debs; emit resolution tree JSON (package, version, repo, chosen alternative, depth) for the report artifact.
- Rootless awareness: files under var/jb/ are relocated into the .app container; paths that cannot function jailed are copied but flagged in the report.

## 9. Constraints

- Free/open-source only. SWCompression (MIT) is the only third-party code in the app; the resolver is Python stdlib; the app code is MIT.
- Performance: parse off the main actor; stream anything over 50 MB; cache repo indexes on the runner, not the device.
- Stability: every malformed-deb case maps to a typed failure the UI explains; no force-unwraps on parsed data.
- Personal-use tooling: convert only packages you are entitled to; never redistribute repacked ipas.

## 10. Known jailbreak apt repos (seed for docs/REPOS.md)

- Chariz: https://repo.chariz.com/
- Havoc: https://havoc.app/
- Procursus (rootless bootstrap): https://apt.procurs.us/
- Sileo: https://repo.getsileo.app/
- BigBoss: http://apt.thebigboss.org/repofiles/cydia/
- roothide Procursus mirror: https://roothide.github.io/procursus/

The user may add custom repos in app settings; they are passed per-dispatch as workflow inputs.
