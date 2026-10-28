#!/usr/bin/env python3
"""deb2ipa dependency resolver (SKILL.md section 8).

Given a main .deb and a list of apt repository base URLs, this script:
  1. reads the main deb's control stanza (via dpkg-deb),
  2. fetches each repo's Packages index (Packages.xz, then Packages.gz, then
     Packages - lzma/gzip are stdlib), caching it under the workdir,
  3. resolves Depends and Pre-Depends recursively: pipe alternatives pick the
     first satisfiable candidate, virtual names are satisfied through
     Provides, resolution is cycle-safe, depth-capped and count-capped,
  4. downloads every chosen deb into <workdir>/debs/,
  5. writes <workdir>/resolution-report.json (the tree, providers, virtuals,
     warnings).

On an unsatisfiable dependency it prints a machine-parseable line
(UNRESOLVED_DEPENDENCY name=... constraint=... repos=[...]), still writes
the report, and exits 3, so the workflow log maps to a human missing-deps
screen (SKILL.md 7.D).

Python 3 stdlib only. Runs on the ubuntu-24.04 Actions runner.
"""

import argparse
import gzip
import hashlib
import json
import lzma
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

USER_AGENT = "deb2ipa-resolver/1.0"
HTTP_TIMEOUT = 60

# Virtual packages that are provided by the device bootstrap itself, not by
# any installable deb. "firmware (>= 14.0)" is the classic example: it is
# satisfied by the phone, no repo ships it, and treating it as unresolved
# would wrongly fail every app deb. Checked only after exact names and
# Provides have failed.
BOOTSTRAP_VIRTUALS = {"firmware", "cy", "cydia"}

MAX_DEPTH_DEFAULT = 25
MAX_PACKAGES_DEFAULT = 400
MAX_PACKAGE_BYTES_DEFAULT = 200 * 1024 * 1024

# Dependency arch qualifiers we accept. Anything else (amd64, i386...) makes
# the dependency irrelevant for an arm64 bundle.
GOOD_ARCHES = {"arm64", "iphoneos-arm64", "iphoneos-arm", "all", "any", "native"}


# ---------------------------------------------------------------------------
# Debian version comparison (dpkg verrevcmp port - same rules as the Swift
# DebianVersion from M1: epoch, upstream, revision; tilde before empty,
# letters before non-letters).
# ---------------------------------------------------------------------------

def _order(c):
    if not c:
        return 0
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    if c == "~":
        return -1
    return ord(c) + 256


def _verrevcmp(a, b):
    ia, ib = 0, 0
    la, lb = len(a), len(b)
    while ia < la or ib < lb:
        first_diff = 0
        # Non-digit segment.
        while (ia < la and not a[ia].isdigit()) or (ib < lb and not b[ib].isdigit()):
            ac = _order(a[ia]) if ia < la else 0
            bc = _order(b[ib]) if ib < lb else 0
            if ac != bc:
                return -1 if ac < bc else 1
            if ia < la and not a[ia].isdigit():
                ia += 1
            if ib < lb and not b[ib].isdigit():
                ib += 1
        # Digit segment: skip leading zeros, compare lengths, then content.
        while ia < la and a[ia] == "0":
            ia += 1
        while ib < lb and b[ib] == "0":
            ib += 1
        while ia < la and a[ia].isdigit() and ib < lb and b[ib].isdigit():
            if first_diff == 0:
                first_diff = int(a[ia]) - int(b[ib])
            ia += 1
            ib += 1
        if ia < la and a[ia].isdigit():
            return 1
        if ib < lb and b[ib].isdigit():
            return -1
        if first_diff:
            return -1 if first_diff < 0 else 1
    return 0


def version_split(v):
    v = v.strip()
    epoch = 0
    if ":" in v:
        head, _, rest = v.partition(":")
        if head.isdigit():
            epoch, v = int(head), rest
    if "-" in v:
        upstream, _, revision = v.rpartition("-")
    else:
        upstream, revision = v, "0"
    return epoch, upstream, revision


def version_compare(a, b):
    ea, ua, ra = version_split(a)
    eb, ub, rb = version_split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = _verrevcmp(ua, ub)
    if c:
        return c
    c = _verrevcmp(ra, rb)
    return c


def satisfies(version, op, reference):
    if not op:
        return True
    c = version_compare(version, reference)
    if op in ("<<", "<"):
        return c < 0
    if op == "<=":
        return c <= 0
    if op == "=":
        return c == 0
    if op == ">=":
        return c >= 0
    if op in (">>", ">"):
        return c > 0
    return False


# ---------------------------------------------------------------------------
# Control-stanza and Depends parsing.
# ---------------------------------------------------------------------------

def parse_stanzas(text):
    stanzas = []
    cur = {}
    last_key = None
    for line in text.splitlines():
        if not line.strip():
            if cur:
                stanzas.append(cur)
                cur = {}
                last_key = None
            continue
        if line[0] in " \t" and last_key is not None:
            cur[last_key] += "\n" + line.strip()
        else:
            key, sep, value = line.partition(":")
            if not sep:
                continue
            cur[key] = value.strip()
            last_key = key
    if cur:
        stanzas.append(cur)
    return stanzas


def split_top_commas(s):
    """Split on commas that are not inside parentheses."""
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        parts.append(tail)
    return parts


ALT_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9][A-Za-z0-9.+-]*?)(?::(?P<suffix>[a-z0-9]+))?"
    r"(?:\[(?P<arches>[^\]]*)\])?"
    r"(?:\s*\(\s*(?P<op><<|<=|=|>=|>>|<|>)\s*(?P<version>[^)]+?)\s*\))?$"
)


def parse_alternative(text):
    m = ALT_RE.match(text.strip())
    if not m:
        return None
    name = m.group("name")
    suffix = m.group("suffix") or ""
    if suffix in ("any", "native"):
        name = m.group("name")
    elif suffix:
        return None  # explicit non-default arch like foo:amd64 - irrelevant
    arches = (m.group("arches") or "").split()
    return {
        "name": name,
        "arches": arches,
        "op": m.group("op"),
        "version": (m.group("version") or "").strip(),
    }


def parse_dependency_groups(field):
    """Depends/Pre-Depends -> list of groups; each group is a list of
    alternatives (the first satisfiable one wins)."""
    groups = []
    for group_text in split_top_commas(field):
        group = []
        for alt_text in split_top_commas_pipe(group_text):
            alt = parse_alternative(alt_text)
            if alt is None:
                continue
            if alt["arches"] and not any(a in GOOD_ARCHES for a in alt["arches"]):
                continue
            group.append(alt)
        if group:
            groups.append(group)
    return groups


def split_top_commas_pipe(s):
    """Split a group on '|' while respecting parentheses."""
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "|" and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        parts.append(tail)
    return parts


def parse_provides(field):
    """Provides -> list of (name, provided_version_or_None)."""
    out = []
    for item in split_top_commas(field):
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9.+-]*?)(?:\s*\(=\s*([^)]+?)\s*\))?$", item.strip())
        if m:
            out.append((m.group(1), (m.group(2) or "").strip() or None))
    return out


# ---------------------------------------------------------------------------
# Repo index handling.
# ---------------------------------------------------------------------------

def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def fetch_repo_index(repo_base, cache_dir):
    """Returns the decoded text of a repo's Packages index, trying
    Packages.xz, Packages.gz, then Packages (SKILL.md section 8)."""
    repo_base = repo_base.rstrip("/")
    os.makedirs(cache_dir, exist_ok=True)
    for candidate in ("Packages.xz", "Packages.gz", "Packages"):
        url = repo_base + "/" + candidate
        cache_path = os.path.join(cache_dir, hashlib.sha1(url.encode()).hexdigest())
        try:
            if os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
                with open(cache_path, "rb") as f:
                    data = f.read()
            else:
                data = http_get(url)
                with open(cache_path, "wb") as f:
                    f.write(data)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError):
            continue
        try:
            if candidate.endswith(".xz"):
                text = lzma.decompress(data).decode("utf-8", "replace")
            elif candidate.endswith(".gz"):
                text = gzip.decompress(data).decode("utf-8", "replace")
            else:
                text = data.decode("utf-8", "replace")
            if "Package:" in text:
                return text, url
        except (lzma.LZMAError, OSError, UnicodeDecodeError):
            continue
    raise RuntimeError("no Packages index found under " + repo_base)


def download_url_bases(repo_base):
    """URL bases to try when joining a stanza's relative Filename.

    Flat jailbreak repos (Chariz, Havoc...) serve debs relative to the repo
    root. Dists-style repos (Procursus) keep the index deep under
    /dists/.../binary-<arch>/ but reference files relative to the repo ROOT
    (pool/...). So for a /dists/ URL the root goes first, then the index dir.
    """
    repo_base = repo_base.rstrip("/")
    if "/dists/" in repo_base:
        root = repo_base[: repo_base.index("/dists/")]
        return [root, repo_base]
    return [repo_base]


class Repo:
    def __init__(self, base, index_url, stanzas):
        self.base = base
        self.index_url = index_url
        self.packages = {}      # name -> highest-version stanza
        self.providers = {}      # provided name -> [(provider, provider_version, provided_version)]
        for s in stanzas:
            name = s.get("Package")
            if not name:
                continue
            current = self.packages.get(name)
            if current is None or version_compare(
                    s.get("Version", "0"), current.get("Version", "0")) > 0:
                self.packages[name] = s
            for provided, provided_version in parse_provides(s.get("Provides", "")):
                self.providers.setdefault(provided, []).append(
                    (name, s.get("Version", ""), provided_version))


# ---------------------------------------------------------------------------
# Resolution.
# ---------------------------------------------------------------------------

class Resolver:
    def __init__(self, repos, workdir, max_depth, max_packages, max_package_bytes):
        self.repos = repos
        self.workdir = workdir
        self.max_depth = max_depth
        self.max_packages = max_packages
        self.max_package_bytes = max_package_bytes
        self.chosen = {}          # name -> report entry (resolved)
        self.virtual = []         # bootstrap-virtual entries
        self.warnings = []
        self.unresolved = []
        self._in_progress = []

    def fail_unresolved(self, group, requested):
        names = " | ".join(alt["name"] + ("" if not alt["op"] else
                         " (%s %s)" % (alt["op"], alt["version"])) for alt in group)
        entry = {
            "requested": requested,
            "candidates": names,
            "repos_searched": [r.base for r in self.repos],
        }
        self.unresolved.append(entry)
        print("UNRESOLVED_DEPENDENCY candidates='%s' repos=%s" %
              (names, [r.base for r in self.repos]))
        sys.stdout.flush()

    def satisfy_group(self, group, depth, requested):
        """Tries alternatives left to right; the first satisfiable one wins.
        Returns True when the group is satisfied (including as virtual)."""
        for alt in group:
            if self.try_satisfy_alternative(alt, depth, requested, group):
                return True
        # Nothing satisfiable: bootstrap virtuals still pass (device-provided).
        if all(alt["name"] in BOOTSTRAP_VIRTUALS for alt in group):
            name = group[0]["name"]
            if name not in {v["package"] for v in self.virtual}:
                self.virtual.append({"package": name, "satisfied_by": "device-bootstrap",
                                     "depth": depth})
            return True
        self.fail_unresolved(group, requested)
        return False

    def try_satisfy_alternative(self, alt, depth, requested, group):
        name, op, ref = alt["name"], alt["op"], alt["version"]
        # This alternative's own request, e.g. "libssl3 (>= 3.0.0)" or "sh".
        # The group string may carry constraints belonging to OTHER names,
        # so any re-check of an already-chosen package must use this spec.
        alt_spec = name + ((" (%s %s)" % (op, ref)) if op else "")

        # Exact package name in any repo (repos are searched in order).
        for repo in self.repos:
            stanza = repo.packages.get(name)
            if stanza is None:
                continue
            version = stanza.get("Version", "")
            if not satisfies(version, op, ref):
                continue
            self.take_package(name, stanza, repo, depth, requested,
                              chosen_alternative=None if len(group) == 1 else alt["name"],
                              provided_by=None, constraint=alt_spec)
            return True

        # Virtual: satisfied through Provides.
        for repo in self.repos:
            for provider, provider_version, provided_version in repo.providers.get(name, []):
                version_to_check = provided_version or provider_version
                if not satisfies(version_to_check, op, ref):
                    continue
                stanza = repo.packages.get(provider)
                if stanza is None:
                    continue
                self.take_package(provider, stanza, repo, depth, requested,
                                  chosen_alternative=None if len(group) == 1 else alt["name"],
                                  provided_by=name, constraint=alt_spec)
                return True

        # Bootstrap virtual (e.g. firmware): satisfied by the device itself.
        if name in BOOTSTRAP_VIRTUALS:
            if name not in {v["package"] for v in self.virtual}:
                self.virtual.append({"package": name, "satisfied_by": "device-bootstrap",
                                     "depth": depth})
            return True
        return False

    def take_package(self, name, stanza, repo, depth, requested,
                     chosen_alternative, provided_by, constraint=None):
        if name in self.chosen:
            existing = self.chosen[name]
            # Already chosen (maybe under another constraint): warn if the
            # earlier pick now conflicts with THIS alternative's constraint.
            # Only the per-alternative spec is checked - the group string
            # may carry constraints belonging to other names, and full SAT
            # conflict resolution is out of scope (SKILL.md 7.K).
            if constraint:
                m = re.search(r"\((\S+)\s+(\S+)\)", constraint)
                if m and not satisfies(existing["version"], m.group(1), m.group(2)):
                    self.warnings.append(
                        "%s was already chosen at version %s, which does not satisfy %s" %
                        (name, existing["version"], constraint))
            return

        if len(self.chosen) >= self.max_packages:
            raise RuntimeError("package count cap exceeded (%d)" % self.max_packages)

        size_bytes = int(stanza.get("Size") or 0)
        if size_bytes > self.max_package_bytes:
            raise RuntimeError("package %s exceeds the %d-byte per-package cap" %
                               (name, self.max_package_bytes))

        filename = stanza.get("Filename", "")
        if not filename:
            self.warnings.append("no Filename for %s in %s" % (name, repo.base))
            return

        deb_path = self.download(name, stanza.get("Version", ""), filename, repo)

        entry = {
            "package": name,
            "version": stanza.get("Version", ""),
            "repo": repo.base,
            "deb": deb_path,
            "size_bytes": size_bytes,
            "depth": depth,
            "requested": requested,
            "chosen_alternative": chosen_alternative,
            "provided_by": provided_by,
            "status": "downloaded",
        }
        self.chosen[name] = entry
        print("resolved %-28s %-16s %s" % (name, stanza.get("Version", ""), repo.base))
        sys.stdout.flush()

        # Recurse into this package's own dependency closure.
        self.resolve_dependencies_of(deb_path, name, depth + 1)

    def download(self, name, version, filename, repo):
        deb_dir = os.path.join(self.workdir, "debs")
        os.makedirs(deb_dir, exist_ok=True)
        safe = "%s_%s.deb" % (name, (version or "0").replace("/", "_"))
        dest = os.path.join(deb_dir, safe)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            return dest
        last_error = None
        for base in download_url_bases(repo.base):
            url = base + "/" + filename.lstrip("/")
            try:
                data = http_get(url)
                if not data.startswith(b"!<arch>\n"):
                    raise ValueError("not a deb (bad magic)")
                with open(dest, "wb") as f:
                    f.write(data)
                return dest
            except (urllib.error.URLError, urllib.error.HTTPError,
                    ValueError, OSError) as exc:
                last_error = exc
                continue
        raise RuntimeError("download failed for %s (%s): %s" % (name, filename, last_error))

    def resolve_dependencies_of(self, deb_path, name, depth):
        if depth > self.max_depth:
            self.warnings.append("depth cap reached under %s (>%d)" % (name, self.max_depth))
            return
        if name in self._in_progress:
            return
        self._in_progress.append(name)
        try:
            control = subprocess.check_output(
                ["dpkg-deb", "-f", deb_path, "Depends", "Pre-Depends"],
                text=True, stderr=subprocess.DEVNULL)
            # Output is one "Field: value" line per non-empty field (empty
            # fields are omitted). Long values may fold; continuation lines
            # start with whitespace.
            current_field = None
            current_value = ""
            for line in control.splitlines():
                if line[:1] in (" ", "\t") and current_field:
                    current_value += "," + line.strip()
                    continue
                key, sep, value = line.partition(":")
                if not sep:
                    continue
                self._flush_field(current_field, current_value, depth)
                current_field = key.strip()
                current_value = value.strip()
            self._flush_field(current_field, current_value, depth)
        finally:
            self._in_progress.pop()

    def _flush_field(self, field, value, depth):
        if field not in ("Depends", "Pre-Depends") or not value:
            return
        for group in parse_dependency_groups(value):
            self.satisfy_group(group, depth, value)


def main():
    ap = argparse.ArgumentParser(description="deb2ipa dependency resolver")
    ap.add_argument("--deb", required=True, help="path to the main .deb (already downloaded)")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--repos", required=True, help="JSON array of repo base URLs")
    ap.add_argument("--extra-debs", default="", help="JSON array of extra deb URLs (already downloaded)")
    ap.add_argument("--max-depth", type=int, default=MAX_DEPTH_DEFAULT)
    ap.add_argument("--max-packages", type=int, default=MAX_PACKAGES_DEFAULT)
    ap.add_argument("--max-package-bytes", type=int, default=MAX_PACKAGE_BYTES_DEFAULT)
    args = ap.parse_args()

    workdir = args.workdir
    os.makedirs(os.path.join(workdir, "debs"), exist_ok=True)

    repo_urls = json.loads(args.repos)
    if isinstance(repo_urls, str):
        repo_urls = [repo_urls]

    # The main deb is expected at <workdir>/debs/main.deb (workflow convention).
    main_path = args.deb
    control_raw = subprocess.check_output(
        ["dpkg-deb", "-f", main_path, "Package", "Version", "Architecture", "Depends",
         "Pre-Depends", "Name", "Description"],
        text=True)
    main_control = {}
    for line in control_raw.splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            main_control[key.strip()] = value.strip()

    print("=== Main package ===")
    print("Package: %s  Version: %s  Architecture: %s" %
          (main_control.get("Package"), main_control.get("Version"),
           main_control.get("Architecture")))

    print("=== Fetching repo indexes ===")
    repos = []
    cache_dir = os.path.join(workdir, "index-cache")
    for url in repo_urls:
        try:
            text, index_url = fetch_repo_index(url, cache_dir)
            repo = Repo(url, index_url, parse_stanzas(text))
            repos.append(repo)
            print("index %-80s %6d packages" % (url, len(repo.packages)))
        except Exception as exc:  # noqa: BLE001 - a dead repo is a warning, not a failure
            print("WARN repo unreachable: %s (%s)" % (url, exc))
    if not repos:
        print("UNRESOLVED_DEPENDENCY candidates='(any)' repos=%s reason='no reachable repo'" % repo_urls)
        sys.exit(3)

    resolver = Resolver(repos, workdir, args.max_depth, args.max_packages,
                        args.max_package_bytes)

    print("=== Resolving dependencies ===")
    try:
        for field_name in ("Depends", "Pre-Depends"):
            value = main_control.get(field_name, "").strip()
            if not value:
                continue
            for group in parse_dependency_groups(value):
                resolver.satisfy_group(group, 1, value)
    except RuntimeError as exc:
        print("RESOLVER_ERROR message='%s'" % exc)
        sys.exit(3)

    # Extra debs requested by the user (already downloaded by the workflow):
    # their dependency closures get resolved too.
    if args.extra_debs:
        extras = json.loads(args.extra_debs)
        for name in extras:
            resolver.resolve_dependencies_of(name, name, 1)

    report = {
        "root": {
            "package": main_control.get("Package", ""),
            "version": main_control.get("Version", ""),
            "architecture": main_control.get("Architecture", ""),
            "name": main_control.get("Name", ""),
            "deb": main_path,
        },
        "repos": [
            {"url": r.base, "index": r.index_url, "packages": len(r.packages)}
            for r in repos
        ],
        "resolved": [resolver.chosen[k] for k in sorted(resolver.chosen)],
        "virtual": resolver.virtual,
        "warnings": resolver.warnings,
        "unresolved": resolver.unresolved,
    }
    report_path = os.path.join(workdir, "resolution-report.json")
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    print("=== Report ===")
    print("resolved=%d virtual=%d warnings=%d unresolved=%d" %
          (len(report["resolved"]), len(report["virtual"]),
           len(report["warnings"]), len(report["unresolved"])))
    print("report: %s" % report_path)
    if report["unresolved"]:
        sys.exit(3)
    sys.exit(0)


if __name__ == "__main__":
    main()
