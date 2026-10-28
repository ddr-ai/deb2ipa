# Known apt repositories for dependency resolution

deb2ipa's resolver (`scripts/resolve_deps.py`) fetches a repository's
`Packages` index, resolves the dependency closure with dpkg-exact version
comparison, and downloads the chosen debs. Repos come in two layout shapes and
the resolver supports both; the difference is *where the index lives* versus
*what the `Filename` field is relative to*.

## Layouts

- **Flat repos** - base URL is the repo root; the index sits directly at
  `<root>/Packages.xz` (falls back to `.gz`, then plain) and `Filename`
  values are relative to the same root.
- **dists-style repos** - the base URL points at a suite/component/binary
  directory like `.../dists/<suite>/<component>/binary-<arch>/`; the index is
  `<that dir>/Packages.xz`. CAUTION: `Filename` values are usually relative
  to the **repo root** (`https://host/`), not the index directory. The
  resolver's `download_url_bases()` tries the repo root first, then the index
  directory, so either convention works - but always pass the full
  `dists/.../binary-.../` path, not just the host.

## Verified repositories (used by the M4 smoke build)

- **Chariz** (flat): `https://repo.chariz.com/`
  Apps (NewTerm 3 and friends); ~180 packages in the flat index.
- **Procursus, rootless bootstrap, iOS 18.0 suite** (dists-style):
  `https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/main/binary-iphoneos-arm64/`
  The bootstrap toolchain (zsh, coreutils, bash, fish, ncurses, openssl, and
  their libraries). `Filename` is relative to `https://apt.procurs.us/`.
  Under `dists/iphoneos-arm64-rootless/` only the `1800` suite exists.

The default repo list passed by the build workflow is exactly these two;
add or replace entries per dispatch via the `repos` input (JSON array).

## Seed list (not yet verified against the resolver)

- Havoc: `https://havoc.app/`
- Sileo: `https://repo.getsileo.app/`
- BigBoss: `http://apt.thebigboss.org/repofiles/cydia/` (HTTP-only; only the
  Linux runner ever fetches it, never the iOS app)
- roothide Procursus mirror: `https://roothide.github.io/procursus/`

Verify a new repo by running the resolver against a real deb before adding
it to the defaults:

    python3 scripts/resolve_deps.py \
      --deb <downloaded.deb> --workdir <dir> \
      --repos '["<repo-base-url>"]'
