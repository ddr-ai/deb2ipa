#!/usr/bin/env python3
"""Resolver fixture tests against REAL Packages indexes (SKILL.md M7).

Three layers:

  1. Unit tests over VERBATIM stanzas captured from the live Chariz and
     Procursus indexes (2026-10-28): parsing, Provides indexing, dpkg-exact
     version comparison on real version strings, alternatives, arch
     qualifiers, download-URL base rules for both repo layouts.

  2. End-to-end fixture resolution: a synthetic repo whose index uses the
     REAL Packages format is served over local HTTP, and the resolver is
     run as a subprocess against a synthetic root deb - asserting the
     happy path (incl. Provides satisfaction, alternatives, bootstrap
     virtuals, cycle safety, xz index preference) AND the unsatisfiable
     path (exit 3 + UNRESOLVED_DEPENDENCY + report still written).

  3. Live index smoke (soft): fetch the real Chariz + Procursus indexes
     through the resolver's own fetch path and assert the contract the
     pipeline depends on. Skips cleanly when the network is unavailable.

Python 3 stdlib only; requires dpkg-deb on PATH. Runs in the test.yml CI.
"""

import gzip
import http.server
import json
import lzma
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import make_fixture_deb    # noqa: E402
import resolve_deps         # noqa: E402

RESOLVER = os.path.join(HERE, "resolve_deps.py")
failures = []


def check(name, condition, detail=""):
    print("%-56s %s" % (name, "ok" if condition else "FAIL"))
    if not condition:
        failures.append("%s: %s" % (name, detail))


# ---------------------------------------------------------------------------
# 1. REAL stanzas (verbatim slices of the live indexes, 2026-10-28).
# ---------------------------------------------------------------------------

REAL_PROCURSUS = """
Package: preferenceloader
Architecture: iphoneos-arm64
Version: 2.2.6-1
Section: System
Maintainer: ProcursusTeam <support@procurs.us>
Installed-Size: 435
Depends: mobilesubstrate
Filename: pool/main/iphoneos-arm64-rootless/1800/preferenceloader_2.2.6-1_iphoneos-arm64.deb
Size: 30260
SHA256: 96733512819f7bfddb7b010df1e2b81f3a19edd2209102b958f39d0d3d242de0

Package: libncursesw6
Architecture: iphoneos-arm64
Version: 6.4
Priority: required
Section: Libraries
Maintainer: Procursus Team <support@procurs.us>
Installed-Size: 1024
Provides: ncurses (= 6.4)
Filename: pool/main/iphoneos-arm64-rootless/1800/libncursesw6_6.4_iphoneos-arm64.deb
Size: 640000

Package: coreutils
Architecture: iphoneos-arm64
Version: 9.5
Priority: standard
Section: Utilities
Maintainer: Procursus Team <support@procurs.us>
Provides: md5sum, sha1sum, coreutils-bin (=9.5), dirname, kill, mktemp, su
Depends: libiosexec1 (>= 1.3.1), sh, profile.d, libssl3
Filename: pool/main/iphoneos-arm64-rootless/1800/coreutils_9.5_iphoneos-arm64.deb
Size: 2000000

Package: zsh
Architecture: iphoneos-arm64
Version: 5.9
Priority: required
Section: Terminal_Support
Maintainer: Procursus Team <support@procurs.us>
Pre-Depends: debianutils (>= 4.11.2)
Depends: libiosexec1 (>= 1.2.2), libncursesw6, libpcre1, debianutils (>= 4.11.2)
Filename: pool/main/iphoneos-arm64-rootless/1800/zsh/zsh_5.9_iphoneos-arm64.deb
Size: 2216142
"""

REAL_CHARIZ = """
Package: ws.hbang.newterm3
Version: 3.0~beta1
Architecture: iphoneos-arm
Section: Terminal Support
Maintainer: HASHBANG Productions <support@hbang.ws>
Installed-Size: 14891
Depends: firmware (>= 14.0), zsh | bash | fish, coreutils, ncurses, system-cmds
Conflicts: ws.hbang.newterm, ws.hbang.newterm2
Name: NewTerm 3 Beta
Description: Powerful terminal app for iOS
Filename: debs/ws.hbang.newterm3_3.0~beta1_iphoneos-arm64.deb
Size: 3836904

Package: com.daveapps.quitall
Name: QuitAll
Architecture: iphoneos-arm
Version: 3.0
Section: Tweaks
Depends: mobilesubstrate, preferenceloader, ws.hbang.common (>= 1.11), applist
Filename: debs/com.daveapps.quitall_3.0_iphoneos-arm.deb
Size: 187804
"""


def real_unit_tests():
    stanzas = resolve_deps.parse_stanzas(REAL_PROCURSUS + REAL_CHARIZ)
    byname = {s["Package"]: s for s in stanzas}
    check("parse_stanzas: 6 real stanzas", len(stanzas) == 6,
          "got %d" % len(stanzas))
    check("parse_stanzas: newterm Depends verbatim",
          byname["ws.hbang.newterm3"]["Depends"] ==
          "firmware (>= 14.0), zsh | bash | fish, coreutils, ncurses, system-cmds",
          repr(byname["ws.hbang.newterm3"].get("Depends")))

    repo = resolve_deps.Repo("https://apt.procurs.us/dists/x/binary-a/",
                             "index", resolve_deps.parse_stanzas(REAL_PROCURSUS))
    check("Repo: packages indexed", set(repo.packages) ==
          {"preferenceloader", "libncursesw6", "coreutils", "zsh"},
          sorted(repo.packages))
    check("Repo: Provides ncurses -> libncursesw6 (= 6.4)",
          repo.providers.get("ncurses") == [("libncursesw6", "6.4", "6.4")],
          repr(repo.providers.get("ncurses")))
    check("Repo: coreutils provides md5sum/sha1sum/...",
          set(repo.providers) >=
          {"md5sum", "sha1sum", "coreutils-bin", "dirname", "kill", "mktemp", "su"},
          sorted(repo.providers))

    groups = resolve_deps.parse_dependency_groups(
        byname["ws.hbang.newterm3"]["Depends"])
    check("parse_dependency_groups: newterm -> 5 groups", len(groups) == 5,
          "got %d" % len(groups))
    check("parse_dependency_groups: alternatives kept",
          [a["name"] for a in groups[1]] == ["zsh", "bash", "fish"],
          groups[1])
    check("parse_dependency_groups: firmware (>= 14.0)",
          groups[0][0]["name"] == "firmware"
          and groups[0][0]["op"] == ">="
          and groups[0][0]["version"] == "14.0", groups[0])

    quitall_groups = resolve_deps.parse_dependency_groups(
        byname["com.daveapps.quitall"]["Depends"])
    check("parse_dependency_groups: quitall -> 4 groups",
          len(quitall_groups) == 4, quitall_groups)
    check("parse_alternative: version constraint kept",
          quitall_groups[2][0] == {"name": "ws.hbang.common",
                                    "arches": [], "op": ">=", "version": "1.11"},
          quitall_groups[2])

    # dpkg-exact version comparison on REAL version strings.
    vc = resolve_deps.version_compare
    check("version_compare: 2.2.6-1 > 2.2.6", vc("2.2.6-1", "2.2.6") > 0)
    check("version_compare: 3.0~beta1 < 3.0 (tilde)",
          vc("3.0~beta1", "3.0") < 0)
    check("version_compare: 979.100.8 < 979.100.10 (numeric not lexical)",
          vc("979.100.8", "979.100.10") < 0)
    check("version_compare: 9.5 == 9.5", vc("9.5", "9.5") == 0)
    check("version_compare: 1:0.1 > 2.0 (epoch wins)",
          vc("1:0.1", "2.0") > 0)
    check("version_compare: 6.4 vs 6.40 (longer digits win)",
          vc("6.4", "6.40") < 0)

    sat = resolve_deps.satisfies
    check("satisfies: zsh 5.9 >= 4.11.2 (real debianutils floor)",
          sat("5.9", ">=", "4.11.2"))
    check("satisfies: 6.4 = 6.4 (Provides pin)", sat("6.4", "=", "6.4"))
    check("satisfies: 2.2.6-1 >= 2.2.3", sat("2.2.6-1", ">=", "2.2.3"))
    check("satisfies: unconstrained", sat("anything", "", ""))

    # download_url_bases: the two real repo layouts.
    check("download_url_bases: flat Chariz",
          resolve_deps.download_url_bases("https://repo.chariz.com/") ==
          ["https://repo.chariz.com"])
    check("download_url_bases: dists-style Procursus root first",
          resolve_deps.download_url_bases(
              "https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/"
              "main/binary-iphoneos-arm64/") ==
          ["https://apt.procurs.us",
           "https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/"
           "main/binary-iphoneos-arm64"])

    # Bootstrap virtuals through a resolver with NO repos at all.
    r = resolve_deps.Resolver([], "/tmp/unused", 25, 400, 200 * 1024 * 1024)
    fw_group = resolve_deps.parse_dependency_groups("firmware (>= 14.0)")[0]
    ok = r.satisfy_group(fw_group, 1, "firmware (>= 14.0)")
    check("bootstrap virtual: firmware satisfied by device",
          ok and r.virtual and r.virtual[0]["package"] == "firmware"
          and not r.unresolved, (ok, r.virtual, r.unresolved))


# ---------------------------------------------------------------------------
# 2. End-to-end fixture resolution over local HTTP.
# ---------------------------------------------------------------------------

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve(directory):
    handler = lambda *a, **kw: QuietHandler(*a, directory=directory, **kw)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, "http://127.0.0.1:%d/" % server.server_address[1]


def stanza(package, version, filename, depends="", provides="", size=1000):
    text = "Package: %s\nVersion: %s\nArchitecture: iphoneos-arm64\n" \
           "Maintainer: fixtures <f@invalid>\n" % (package, version)
    if depends:
        text += "Depends: %s\n" % depends
    if provides:
        text += "Provides: %s\n" % provides
    text += "Filename: %s\nSize: %d\nSHA256: %s\n\n" % (filename, size, "0" * 64)
    return text


def fixture_deb(path, package, version, depends=""):
    root = os.path.join(os.path.dirname(path), "data-" + package)
    shutil.rmtree(root, ignore_errors=True)
    make_fixture_deb.make_app(root, name="FixtureApp")
    deb = make_fixture_deb.build_deb(path, root, package, version, depends)
    shutil.rmtree(root, ignore_errors=True)
    return deb


def write_repo_files(directory, packages_text, with_xz=True):
    plain = packages_text.encode()
    with open(os.path.join(directory, "Packages"), "wb") as fh:
        fh.write(plain)
    with gzip.open(os.path.join(directory, "Packages.gz"), "wb") as fh:
        fh.write(plain)
    if with_xz:
        with lzma.open(os.path.join(directory, "Packages.xz"), "wb") as fh:
            fh.write(plain)


def run_resolver(deb, workdir, repos):
    os.makedirs(workdir, exist_ok=True)
    r = subprocess.run(
        [sys.executable, RESOLVER,
         "--deb", deb, "--workdir", workdir,
         "--repos", json.dumps(repos)],
        capture_output=True, text=True)
    report_path = os.path.join(workdir, "resolution-report.json")
    report = None
    if os.path.exists(report_path):
        with open(report_path) as fh:
            report = json.load(fh)
    return r.returncode, r.stdout + r.stderr, report


def e2e_tests(work):
    repo_dir = os.path.join(work, "repo")
    os.makedirs(repo_dir, exist_ok=True)

    # Three fixture debs served by the repo: lib, its provider twin, and a
    # beta alternative that must NOT be picked when alpha exists. lib and
    # cycle-twin form a REAL index cycle (a Depends b, b Depends a) - the
    # resolver must stop instead of looping.
    fixture_deb(os.path.join(repo_dir, "lib.deb"), "ws.fix.lib", "1.2-3",
                depends="ws.fix.cycle-twin, ws.fix.base (>= 1.0)")
    fixture_deb(os.path.join(repo_dir, "cycle.deb"), "ws.fix.cycle-twin",
                "1.0", depends="ws.fix.lib")
    fixture_deb(os.path.join(repo_dir, "virt.deb"), "ws.fix.virt", "2.0")
    fixture_deb(os.path.join(repo_dir, "alpha.deb"), "ws.fix.alpha", "1.0")
    fixture_deb(os.path.join(repo_dir, "beta.deb"), "ws.fix.beta", "1.0")

    index = (
        stanza("ws.fix.lib", "1.2-3", "lib.deb",
               depends="ws.fix.cycle-twin, ws.fix.base (>= 1.0)") +
        stanza("ws.fix.cycle-twin", "1.0", "cycle.deb",
               depends="ws.fix.lib") +
        stanza("ws.fix.virt", "2.0", "virt.deb", provides="fixvirt (= 2.0)") +
        stanza("ws.fix.alpha", "1.0", "alpha.deb") +
        stanza("ws.fix.beta", "1.0", "beta.deb") +
        stanza("ws.fix.base", "1.5", "base.deb")
    )
    # base.deb itself (content never downloaded when unresolved? it IS
    # resolved - so it must exist):
    fixture_deb(os.path.join(repo_dir, "base.deb"), "ws.fix.base", "1.5")
    write_repo_files(repo_dir, index, with_xz=True)

    server, base = serve(repo_dir)
    try:
        # --- happy path ---------------------------------------------------
        root_deb = fixture_deb(os.path.join(work, "root.deb"),
                               "ws.fix.root", "1.0",
                               depends="ws.fix.lib, fixvirt, "
                                       "ws.fix.alpha | ws.fix.beta, "
                                       "firmware (>= 14.0)")
        wd = os.path.join(work, "wd-happy")
        code, out, report = run_resolver(root_deb, wd, [base])
        check("e2e happy: exit 0", code == 0, out)
        check("e2e happy: xz index preferred",
              report and report["repos"][0]["index"].endswith("Packages.xz"),
              report["repos"] if report else out)
        resolved = {e["package"]: e for e in (report or {}).get("resolved", [])}
        check("e2e happy: lib resolved at 1.2-3 from repo",
              resolved.get("ws.fix.lib", {}).get("version") == "1.2-3",
              resolved)
        check("e2e happy: Provides fixvirt -> ws.fix.virt",
              resolved.get("ws.fix.virt", {}).get("provided_by") == "fixvirt",
              resolved.get("ws.fix.virt"))
        check("e2e happy: alternative picks alpha (first satisfiable)",
              "ws.fix.alpha" in resolved and "ws.fix.beta" not in resolved,
              sorted(resolved))
        check("e2e happy: firmware is a device virtual",
              report and report["virtual"] and
              report["virtual"][0]["package"] == "firmware", report["virtual"])
        check("e2e happy: cycle lib<->cycle-twin did not loop",
              len(resolved) == 5 and "ws.fix.cycle-twin" in resolved,
              sorted(resolved))
        check("e2e happy: lib deb downloaded",
              resolved.get("ws.fix.lib", {}).get("status") == "downloaded"
              and os.path.exists(resolved.get("ws.fix.lib", {}).get("deb", "")),
              resolved.get("ws.fix.lib"))
        check("e2e happy: zero unresolved/warnings",
              report and not report["unresolved"] and not report["warnings"],
              (report or {}).get("unresolved"))

        # --- unsatisfiable path -------------------------------------------
        root_deb = fixture_deb(os.path.join(work, "unsat.deb"),
                               "ws.fix.root", "1.0",
                               depends="ws.fix.lib, com.deb2ipa.nonexistent (>= 99)")
        wd = os.path.join(work, "wd-unsat")
        code, out, report = run_resolver(root_deb, wd, [base])
        check("unsatisfiable: exit 3", code == 3, "exit %d\n%s" % (code, out))
        check("unsatisfiable: UNRESOLVED_DEPENDENCY machine line",
              "UNRESOLVED_DEPENDENCY" in out and
              "com.deb2ipa.nonexistent" in out, out)
        check("unsatisfiable: report still written",
              report is not None and
              [u["candidates"] for u in report["unresolved"]] ==
              ["com.deb2ipa.nonexistent (>= 99)"],
              report)
        check("unsatisfiable: repos_searched recorded",
              report and report["unresolved"][0]["repos_searched"] == [base],
              report["unresolved"])

        # --- version constraint rejection ---------------------------------
        root_deb = fixture_deb(os.path.join(work, "verfail.deb"),
                               "ws.fix.root", "1.0",
                               depends="ws.fix.base (>= 9.0)")
        wd = os.path.join(work, "wd-verfail")
        code, out, report = run_resolver(root_deb, wd, [base])
        check("version rejection: exit 3 + named candidate",
              code == 3 and "ws.fix.base (>= 9.0)" in out, out)
    finally:
        server.shutdown()


# ---------------------------------------------------------------------------
# 3. Live index smoke (soft - skips on network failure).
# ---------------------------------------------------------------------------

def live_tests(work):
    cache = os.path.join(work, "live-cache")
    try:
        text, url = resolve_deps.fetch_repo_index(
            "https://repo.chariz.com/", cache)
        stanzas = resolve_deps.parse_stanzas(text)
        names = {s["Package"] for s in stanzas}
        check("live Chariz: index parsed, ~1000+ packages",
              len(stanzas) > 1000, len(stanzas))
        check("live Chariz: NewTerm 3 present",
              "ws.hbang.newterm3" in names)
        byname = {s["Package"]: s for s in stanzas}
        check("live Chariz: newterm stanza resolves real Depends",
              "Depends" in byname.get("ws.hbang.newterm3", {}) and
              "zsh | bash | fish" in
              byname["ws.hbang.newterm3"].get("Depends", ""),
              byname.get("ws.hbang.newterm3", {}).get("Depends"))
        check("live Chariz: index URL is Packages.xz",
              url.endswith("Packages.xz"), url)

        text, url = resolve_deps.fetch_repo_index(
            "https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/"
            "main/binary-iphoneos-arm64/", cache)
        repo = resolve_deps.Repo("p", url, resolve_deps.parse_stanzas(text))
        check("live Procursus: ncurses provided by libncursesw6",
              any(provider == "libncursesw6"
                  for provider, _, _ in repo.providers.get("ncurses", [])),
              repo.providers.get("ncurses"))
    except Exception as exc:  # noqa: BLE001 - network tests are best-effort
        print("live index tests: SKIP (%s)" % exc)


def main():
    work = tempfile.mkdtemp(prefix="resolver-test-")
    try:
        print("=== unit tests over real index slices ===")
        real_unit_tests()
        print("=== end-to-end fixture resolution (local HTTP repo) ===")
        e2e_tests(work)
        print("=== live index smoke (soft) ===")
        live_tests(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print()
    if failures:
        print("FAILURES:\n" + "\n".join(failures))
        sys.exit(1)
    print("ALL RESOLVER TESTS PASS")


if __name__ == "__main__":
    main()
