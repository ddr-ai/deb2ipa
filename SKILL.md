---
name: deb2ipa
description: Governing build plan for deb2ipa - a SwiftUI iOS app that parses any .deb (primary target: mobile/iOS arm64 debs from ANY source - jailbreak-repo apps such as com.a7m.abdownloadmanager-ios_0.1.0-53 iphoneos-arm64, GitHub-release debs, or any deb containing an arm64 .app bundle), resolves its dependency tree against apt repositories, and builds an unsigned .ipa that actually runs via GitHub Actions for the owner to sideload onto his own iPhone with his preferred tool (AltStore, Sideloadly, or any other). Follow this document for every build, fix, or extension of deb2ipa.
---

# deb2ipa - Project Build Plan (governing document)

## 1. What deb2ipa is

**Purpose.** deb2ipa is an iOS app that lets its owner take any Debian package (.deb), read its metadata, understand its dependency tree, and - when the package is an iOS-targeted app package - convert it into an installable unsigned .ipa by dispatching a GitHub Actions build. The Actions runner downloads the deb, downloads every dependency at a correct version from apt repositories, and repackages everything into a Payload-based ipa published as a GitHub Release.

**Primary input - mobile arm64 debs, from ANY source (clarified Oct 2026).** The package type deb2ipa is built to convert is any deb targeting iOS-on-arm64, regardless of where it comes from: jailbreak-repo apps (Sileo/Zebra naming like `com.a7m.abdownloadmanager-ios_0.1.0-53_iphoneos-arm64.deb`, `Architecture: iphoneos-arm64` rootless era or `iphoneos-arm` legacy rootful), debs attached to GitHub releases, or any other direct .deb download. The convertibility gate is CONTENT, not origin: if data.tar contains a `.app` bundle with arm64 Mach-O executables, the package is convertible and the output ipa must actually run (installs AND launches), not merely install. Tweak-only debs (MobileSubstrate addons with no .app), theme packs, and Linux debs still parse with full metadata plus an explanation of why they cannot run standalone.

**Core features.**
1. On-device parsing of any .deb: package, name, version, architecture, maintainer, description, Depends/Pre-Depends.
2. Dependency tree inspection with apt-style version constraints.
3. Convertibility classification (content-based, source-agnostic): arm64 app deb (convertible - a .app bundle with arm64 Mach-O present, wherever the deb came from) / tweak-type deb / theme-pack deb / non-iOS deb (last three parsed + explained, never dispatched).
4. One-tap dispatch of a GitHub Actions build with the deb URL and repo list as inputs.
5. Live build status, logs, and a machine-readable resolution report.
6. Download of the finished unsigned .ipa from the Release: save to Files, share sheet, or hand off to a sideloading app. deb2ipa assumes no particular installer.
7. Parses ALL debs even when unconvertible - unconvertible ones get metadata + a clear explanation.

**Target users.** The owner converting legitimately obtained free packages into ipas he sideloads onto his own iPhone with his preferred method. Not a distribution or piracy tool. Note: the repository was created public, which conveniently unlocks free unlimited GitHub Actions minutes (Linux and macOS) - flip it to private any time if preferred.

## 2. Tech stack and platforms (decided - do not relitigate without user request)

- **Primary: Swift 5.9+ / SwiftUI**, deployment target iOS 16.0, Swift Package Manager. Native wins for a single-platform iOS tool: first-class file handling, Swift concurrency for parsing large debs off the main actor, and no bridging overhead. Performance/stability first.
- **Sole third-party Swift dependency: SWCompression (MIT)** for TAR/XZ/GZip reads. The ar container format is parsed by ~100 lines of in-house Swift. No other dependencies.
- **Build side: GitHub Actions on ubuntu-24.04 (pinned; ubuntu-latest resolves to the broken-for-Swift Ubuntu 26 image since Oct 2026 - see 7.L)** + bash + dpkg-deb (preinstalled) + Python 3 (stdlib only) resolver. No macOS runner on the deb-to-ipa path, no Xcode, no signing.
- **Rejected fallback: Flutter/Dart** - no mature TAR/XZ parsing; only reconsider if Android becomes a target.
- **Platforms.** App: iOS 16+ (TrollStore device compatibility reaches iOS 14-17.x). Builds: GitHub-hosted Linux runners. Output: a standard unsigned .ipa; the user sideloads it himself and deb2ipa assumes no particular installer (AltStore/Sideloadly re-sign at install, or any other tool).

## 3. Repository layout

    deb2ipa/
      app/                      # Swift package "DebKit" (SPM); the iOS app links it locally
        Package.swift
        Sources/DebKit/
          DebParser/            # ar reader, control.tar extraction, DebControl model
          AptVersion/           # Debian version comparison port, Depends parsing
          Classifier/           # content-based classification + binary sniffing (M2)
          GitHubAPI/            # PAT store, dispatch, polling, logs, releases (M3)
          Views/                # SwiftUI screens (M6)
        Tests/DebKitTests/      # unit tests with real dpkg-deb fixtures (base64-embedded)
      .github/workflows/
        test.yml                # swift test on ubuntu-24.04; failed logs auto-published to ci-logs branch
        build-ipa.yml           # workflow_dispatch: deb -> unsigned ipa (ubuntu-24.04, M4)
        build-app.yml           # builds the deb2ipa app itself as unsigned ipa (macos-latest, tags only, M8)
        hello-m3.yml           # M3 dispatch acceptance target (no-op, workflow_dispatch)
      scripts/
        resolve_deps.py         # dependency resolver + version comparison
        make_ipa.sh             # Payload assembly, Info.plist rules, zip --symlinks
      docs/
        PAT-SETUP.md            # fine-grained PAT instructions
        REPOS.md                # known jailbreak apt repo URLs
      SKILL.md                  # this document
      README.md

## 4. Core data flow

1. User imports a .deb via the Files app or pastes a URL from anywhere (jailbreak repo, GitHub release, any direct download). The standard repo filename pattern {id}_{version}_{arch}.deb is parsed to prefill package, version, and architecture.
2. App parses ar -> control.tar.xz/.gz -> control file, shows metadata and the Depends tree.
3. App classifies convertibility (see M2). Unconvertible -> explanation screen, no dispatch.
4. App POSTs a workflow_dispatch with inputs: deb_url, package_name, version, bundle_id, display_name, repos (JSON list), extra_debs (optional URLs).
5. Workflow: download deb -> resolver fetches repo Packages indexes -> picks and downloads dependency debs -> extracts all file trees -> locates the .app bundle -> merges files -> generates/validates Info.plist -> zips Payload -> creates a Release with the unsigned .ipa + resolution-report.json + build log.
6. App polls the run, then downloads the .ipa asset and offers TrollStore/AltStore/share-sheet handoff.

## 5. Phased build plan (milestones - build in order)

- **M0 - Scaffold. [DONE]** README, SKILL.md, .gitignore, repository layout.
- **M1 - Deb parser (Swift). [DONE - CI green]** ArReader (global magic, 60-byte member headers, even-byte padding, BSD extended names), ControlExtractor (control.tar.xz/.gz/none via SWCompression), DebControl + DebControlParser (RFC 822 folding, case-insensitive fields), Depends parsing (comma groups, pipe alternatives, version operators, arch qualifiers), DebianVersion (dpkg-exact comparison incl. tilde/epoch/numeric rules). Acceptance met with stronger evidence than planned: unit tests parse REAL debs built by dpkg-deb (xz and gzip fixtures embedded as base64) plus a full version-comparison table; all tests run in CI on ubuntu-24.04.
- **M2 - Classifier. [DONE - CI green]** Data.tar entry scan with binary sniffing (thin arm64 Mach-O, fat Mach-O containing an arm64 slice, non-arm64 Mach-O, ELF) and .app-bundle discovery anywhere in the tree (outermost wins). Five content classes, source-agnostic, control Architecture advisory: app (convertible iff an arm64 MH_EXECUTE sits inside a .app bundle - fat binaries with an arm64 slice count), tweak (MobileSubstrate/TweakInject/PreferenceBundles paths, no .app), iosTools (bare arm64 binaries: CLI tools/daemons, no .app), nonIOS (ELF or non-arm64 Mach-O), themePack (no executable content). App bundles without an arm64 executable classify as app but stay unconvertible (the "must actually run" bar); convertible apps that also carry substrate files get a jailbreak-runtime warning reason. DebPackage.classify() is the facade. Acceptance exceeded: 8 real dpkg-deb fixtures (standard app, nonstandard-location app, rootless var/jb app, fat-binary app, tweak, theme pack, amd64 deb with a real ELF binary, and an .app with no native executable) all classified correctly, plus direct sniffer unit tests; CI green on ubuntu-24.04.
- **M3 - GitHub API client (Swift). [DONE - CI green]** GitHubTransport abstraction (production URLSessionTransport; compiles on the Linux CI via FoundationNetworking); GitHubClient actor - token validation via GET /user + the repo workflow list (7.B), workflow dispatch, run fetch with ETag caching (304 responses do not count against the rate limit, 7.J), run logs, releases, and asset download via the API URL with the octet-stream Accept; KeychainTokenStore (ThisDeviceOnly accessibility) and InMemoryTokenStore behind a GitHubTokenStore protocol; GitHubDispatcher with retry-once-after-5-s on 404/422 surfacing .workflowNotSyncedYet (7.A); GitHubRunPoller with 2->30 s exponential backoff, tolerance for the run-visibility 404 right after dispatch, and a typed pollingTimeout; BuildDispatchRequest encoding the workflow input contract (deb_url, package_name, version, bundle_id, display_name, repos JSON array, extra_debs JSON array - optional keys unset when empty); GitHubAPIError with a userMessage for every failure, ready for the M6 screens. Acceptance adapted: GitHub events triggered by GITHUB_TOKEN never start workflow runs (recursion prevention, lesson 7.N), so the hello-m3 workflow (.github/workflows/hello-m3.yml, workflow_dispatch no-op) is dispatched live by HelloWorkflowLiveTests only when a PAT is present - through the DEB2IPA_TOKEN env var in CI (repo secret, docs/PAT-SETUP.md) or on-device/Mac; without a token the test skips cleanly and 18 mock-transport tests replay REAL API payloads (run 40650691548, actions/runner v2.338.2) through every code path: dispatch request contract, 404 and 422 retry-once, 401 no-retry, not-synced-yet surfacing, ETag If-None-Match + 304 cache serving, backoff sequence 2,4,8,16,30,30, visibility-404 tolerance, polling timeout, failure-run log fetch, rate-limit reset epoch, release/asset decode and octet-stream download, input encoding contract, token store round-trip.
- **M4 - The build workflow. [DONE - CI green; first real on-device sideload still pending]** .github/workflows/build-ipa.yml runs the whole pipeline on ubuntu-24.04 (pinned, 7.L): a first step maps dispatch inputs onto smoke defaults via GITHUB_ENV (7.O) -> apt-get install zip unzip xz-utils -> curl the root deb (--retry 3) plus any extra_debs -> scripts/resolve_deps.py: dpkg-exact version comparison, comma-group/pipe-alternative Depends parsing with parens and arch qualifiers, Provides virtuals (ncurses via libncursesw6 Provides), device-bootstrap virtuals (firmware/cy/cydia - warning, not failure), cycle-safe closure with depth-25 / 400-package / 200-MB-per-package caps, downloads each dep with an ar-magic check, writes resolution-report.json -> scripts/make_ipa.sh: dpkg-deb -x every deb into a merged rootfs, find the outermost .app, cp -a into Payload/, relocate the surrounding bootstrap root (var/jb for rootless, / for classic, merged root for nonstandard spots) into <App>.app/.jbroot/ with self-duplicate removal, generate a minimal Info.plist via python3 plistlib only when absent (CFBundleIdentifier sanitized from --bundle-id or fallback io.github.ddr-ai.deb2ipa.<bundle>, MinimumOSVersion default 14.0), validate CFBundleExecutable exists on disk + Mach-O/arm64 sniff, zip -q -r -y (symlinks preserved), verify every entry sits under Payload/ -> a second workflow-level Payload re-verification -> gh release create with the .ipa, resolution-report.json and build.log -> a hard asset gate asserts all three assets attached and the IPA > 1 MB. Trigger design (no PAT exists in CI and GITHUB_TOKEN cannot dispatch, 7.N): workflow_dispatch (real path: published Release, inputs exactly per the M3 BuildDispatchRequest contract) AND push to main touching scripts/resolve_deps.py, scripts/make_ipa.sh or the workflow itself (smoke path: fixed default deb NewTerm 3 3.0~beta1 from Chariz, DRAFT release tagged smoke-<run_number> so public releases stay clean; each smoke run deletes the previous smoke draft). Smoke evidence (run 40664921213, green): ws.hbang.newterm3 3.0~beta1 resolved 19 debs + 1 device virtual from Chariz + Procursus rootless-1800 (zsh, coreutils, system-cmds, libiosexec1, libssl3, ncurses-term, profile.d ...), 0 warnings, 0 unresolved; output NewTerm.ipa 24 MB, 5021 zip entries all under Payload/, arm64 PIE executable intact, 1111 symlinks preserved, bootstrap usr/etc/bin/sbin/Library relocated under NewTerm.app/.jbroot/. Development method: the upgraded sandbox has dpkg-deb 1.22.22, zip, unzip, file, python3 - the entire resolver and assembler were built and tested locally against the real Chariz/Procursus indexes (including synthetic failure-path debs) before any CI push, and every workflow revision is linted with actionlint 1.7.7 before pushing (7.O). Acceptance adapted: "installs AND launches on the user's iPhone" requires the user's own sideload, which no CI can perform - M4's gate is the verified pipeline output (structure, arm64, assets attached, all enforced in-workflow); the launchability checklist that hard-blocks publishing is M5, and the user's first real dispatch + sideload remains the ultimate proof.
- **M5 - IPA assembly quality.** Info.plist generation rules (CFBundleIdentifier sanitized from package name, CFBundleExecutable detected from the bundle, MinimumOSVersion default 14.0, CFBundleName from Name field); zip with --symlinks to preserve dylib symlinks; nested .app handling (outermost wins); strip rootless prefix var/jb/ when relocating into the bundle; emit warnings for files that cannot function jailed (MobileSubstrate dylibs etc.); and a hard LAUNCHABILITY CHECKLIST enforced before the Release is published: Payload/ sits at the zip root, exactly one outermost .app, Info.plist parses, CFBundleExecutable exists on disk and is a valid arm64 Mach-O, Frameworks/ and PlugIns/ symlink chains intact - checklist results go into resolution-report.json and any failure blocks the Release. "Installs AND runs" is the acceptance bar for every output.
- **M6 - SwiftUI app.** Screens: Import, Metadata/Depends tree, Build status, Releases/downloads, Settings (PAT, repos, default install target). Handoffs: share sheet (primary), AltStore scheme altstore://install?url=<ipa url>; the artifact is a plain unsigned ipa, so any sideloading tool the user prefers works. Never let a parser error crash - map every failure to a typed, explained state.
- **M7 - Tests and hardening.** Resolver fixture tests against real Packages indexes; workflow smoke-tested on: app deb with deps, tweak deb (rejected pre-dispatch), unsatisfiable dependency (clear failure log), large deb via the release-asset fallback path.
- **M8 - Self-hosting release.** build-app.yml on macos-latest, triggered by version tags only: xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO build, collect the .app from DerivedData, zip into Payload, attach the app's own unsigned ipa to a GitHub Release so deb2ipa can be sideloaded exactly like its own output. Still certificate-free.

## 6. Unsigned IPA strategy (no certificates, ever)

- The deb-to-ipa path runs entirely on ubuntu-24.04 (pinned): dpkg-deb extraction plus zip. No codesigning, no provisioning profiles, no Xcode.
- The same unsigned artifact serves every sideloading tool: AltStore/Sideloadly re-sign at install time, and any other tool the user prefers works too. No assumption about a specific installer is baked in.
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
- **L. ubuntu-latest broke CI (hit during M1, Oct 2026)** - the ubuntu-latest label now resolves to the Ubuntu 26 runner image, whose Swift toolchain fails SPM builds within seconds. Every workflow pins runs-on: ubuntu-24.04 (known-good Swift 6.x image). CI self-diagnostics: the Tests workflow tees the swift test output to a file and pushes it to the ci-logs branch when the step fails, because the job-logs API requires admin scopes that the automation does not have.
- **M. Fat-binary slice offsets exceed any fixed prefix (caught in M2 review, Oct 2026)** - real fat Mach-O files built by lipo/Apple tools place the first slice at 4 KiB or beyond; a sniffer reading only a 68-byte header prefix sees the fat header but cannot reach the slice, and would misclassify genuine legacy rootful app debs as unconvertible. BinarySniffer follows the fat_arch offset anywhere inside the (bounds-checked) file; regression tests cover a slice at offset 4096 and a corrupt offset past EOF. Never assume a fat slice lives near the container header.
- **N. GITHUB_TOKEN cannot trigger workflow_dispatch (hit during M3, Oct 2026)** - events created by the repository's built-in GITHUB_TOKEN never start workflow runs (GitHub's recursion prevention), so CI cannot self-verify the dispatch acceptance with GITHUB_TOKEN. HelloWorkflowLiveTests instead consumes a real PAT via the DEB2IPA_TOKEN repo secret (docs/PAT-SETUP.md) and skips cleanly (XCTSkip) when absent. Ops note: the sandbox's web fetch of the runs-list REST endpoint served stale/rate-limited data; querying the actions REST endpoints with curl from the upgraded environment is the reliable polling method. M4 corollary: a push CAN trigger workflows, so push-to-main with a paths filter is the CI-verifiable smoke path (draft releases keep the public list clean).
- **O. Workflow env-context restrictions and gh CLI fields (hit during M4, Oct 2026)** - expressions in jobs.<job_id>.env may only use the github/inputs/matrix/needs/secrets/strategy/vars contexts; the env context is NOT among them, so `INPUT: ${{ github.event.inputs.x || env.DEFAULT }}` fails workflow validation. A workflow that fails validation produces a run with conclusion=failure and ZERO jobs, and unauthenticated API calls cannot read the logs/annotations (403/404) - so download actionlint and lint every workflow locally before pushing. Correct pattern: keep defaults in workflow-level env (inherited by all steps), map inputs in a first step writing GITHUB_ENV (multiline values need the <<EOT heredoc form; write every variable unconditionally - downstream steps run with set -u). Related gh CLI trap: `gh release list --json` fields are tagName/isDraft (not tag) and gh hard-errors on unknown fields. Draft releases create NO git tag/ref until published, so /releases/tags/<tag> 404s and only an owner-visible releases list sees the draft.
- **P. pipefail kills short-closing readers (hit during M4, Oct 2026)** - under set -euo pipefail: (1) `grep -v` with zero matches exits 1 inside a $( ) command substitution and terminates the whole script with no error message; (2) `grep -q` closes its stdin at the first match, SIGPIPE-killing the upstream unzip/file so a pipeline that just SUCCEEDED reports failure (141). Fix patterns: `{ grep -v ... || true; }` inside substitutions; capture the producer output into a variable or file once, then grep it without -q (or feed via <<<"$var"). bash -n catches neither class - always run the real data path locally before pushing.

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

## 10. Known jailbreak apt repos (in docs/REPOS.md)

- Chariz: https://repo.chariz.com/
- Havoc: https://havoc.app/
- Procursus (rootless bootstrap): https://apt.procurs.us/
- Sileo: https://repo.getsileo.app/
- BigBoss: http://apt.thebigboss.org/repofiles/cydia/
- roothide Procursus mirror: https://roothide.github.io/procursus/

The user may add custom repos in app settings; they are passed per-dispatch as workflow inputs.
