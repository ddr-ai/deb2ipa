"""macho.py - minimal Mach-O reader for the deb2ipa build side.

Python 3 stdlib only (no external deps, no Swift, runs on the ubuntu runner
and in the dev sandbox). Parses fat/universal headers and the slice load
commands deb2ipa's launchability checklist cares about:

  LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB / LC_ID_DYLIB
  LC_RPATH
  LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS   (minimum iOS version)

Scope: read-only, arm64/arm64_32 slices of interest; enough of a parser to
classify dylib dependencies as system, bundle-resolvable, or missing - it is
NOT a general disassembler and deliberately ignores what it does not need.
"""

import struct

FAT_MAGIC = 0xCAFEBABE      # big-endian on disk
FAT_MAGIC_64 = 0xCAFEBABF   # big-endian on disk
MH_MAGIC_64 = 0xFEEDFACF    # little-endian on disk (arm64)
MH_MAGIC = 0xFEEDFACE       # little-endian on disk (armv7)

CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64_32 = 0x0100000B

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32

PLATFORM_IOS = 2
MH_PIE = 0x00200000
MH_DYLIB = 0x06
MH_DYLIB_STUB = 0x08
MH_BUNDLE = 0x0C
MH_EXECUTE = 0x02

_DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_ID_DYLIB)


def looks_like_macho(data):
    """True when the bytes start with any Mach-O or fat magic we know."""
    if len(data) < 4:
        return False
    magic_be, = struct.unpack_from(">I", data, 0)
    magic_le, = struct.unpack_from("<I", data, 0)
    return magic_be in (FAT_MAGIC, FAT_MAGIC_64) or magic_le in (MH_MAGIC_64, MH_MAGIC)


def _slices(data):
    """Return [(cputype, offset, size)] for fat files; [(None, 0, len)] thin."""
    if len(data) < 8:
        return []
    magic_be, = struct.unpack_from(">I", data, 0)
    if magic_be == FAT_MAGIC:
        count, = struct.unpack_from(">I", data, 4)
        out = []
        pos = 8
        for _ in range(min(count, 32)):            # sanity cap
            if pos + 20 > len(data):
                break
            cputype, _cpusub, off, size, _align = struct.unpack_from(">iiIII", data, pos)
            out.append((cputype, off, size))
            pos += 20
        return out
    if magic_be == FAT_MAGIC_64:
        count, = struct.unpack_from(">I", data, 4)
        out = []
        pos = 8
        for _ in range(min(count, 32)):
            if pos + 32 > len(data):
                break
            cputype, _cpusub, off, size, _align, _res = struct.unpack_from(">iiQQII", data, pos)
            out.append((cputype, off, size))
            pos += 32
        return out
    return [(None, 0, len(data))]


def _cstr(data, start, end):
    nul = data.find(b"\x00", start, end)
    if nul == -1:
        nul = end
    return data[start:nul].decode("utf-8", "replace")


def _parse_slice(data, offset, size):
    """Parse one mach header (64-bit preferred; 32-bit tolerated for armv7)."""
    if offset + 28 > len(data):
        return None
    magic, cputype, _cpusub, filetype, ncmds, sizeofcmds, flags = \
        struct.unpack_from("<IiIIIII", data, offset)
    if magic == MH_MAGIC_64:
        header_size = 32           # includes trailing 'reserved'
        pie = bool(flags & MH_PIE)
    elif magic == MH_MAGIC:
        header_size = 28
        pie = False
    else:
        return None
    cmds = []
    pos = offset + header_size
    end = min(offset + header_size + sizeofcmds, offset + size, len(data))
    for _ in range(min(ncmds, 4096)):              # sanity cap
        if pos + 8 > end:
            break
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8 or pos + cmdsize > len(data):
            break
        entry = {"cmd": cmd}
        if cmd in _DYLIB_CMDS:
            name_off, = struct.unpack_from("<I", data, pos + 8)
            if 0 < name_off < cmdsize:
                entry["path"] = _cstr(data, pos + name_off, pos + cmdsize)
        elif cmd == LC_RPATH:
            path_off, = struct.unpack_from("<I", data, pos + 8)
            if 0 < path_off < cmdsize:
                entry["path"] = _cstr(data, pos + path_off, pos + cmdsize)
        elif cmd == LC_BUILD_VERSION:
            platform, minos, _sdk, _ntools = struct.unpack_from("<IIII", data, pos + 8)
            entry["platform"] = platform
            entry["minos_packed"] = minos
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            version, _sdk = struct.unpack_from("<II", data, pos + 8)
            entry["platform"] = PLATFORM_IOS
            entry["minos_packed"] = version
        cmds.append(entry)
        pos += cmdsize
    return {
        "cputype": cputype,
        "filetype": filetype,
        "pie": pie,
        "flags": flags,
        "cmds": cmds,
    }


def _unpack_version(packed):
    return "%d.%d" % (packed >> 16, (packed >> 8) & 0xFF)


def analyze(data):
    """Analyze Mach-O bytes. Returns a dict (empty when not parseable).

    { "arm64": bool, any arm64/arm64_32 slice present
      "filetype": int of the best (arm64) slice,
      "pie": bool of the best slice,
      "load_dylibs": [...], "weak_dylibs": [...],
      "reexport_dylibs": [...], "id_dylib": str|None,
      "rpaths": [...],
      "min_ios": "14.0"|None }   # from LC_BUILD_VERSION (platform iOS) or
                                 # LC_VERSION_MIN_IPHONEOS, arm64 slices only
    """
    out = {
        "arm64": False, "filetype": None, "pie": False,
        "load_dylibs": [], "weak_dylibs": [], "reexport_dylibs": [],
        "id_dylib": None, "rpaths": [], "min_ios": None,
    }
    if not looks_like_macho(data):
        return out
    slices = []
    for cputype, off, size in _slices(data):
        parsed = _parse_slice(data, off, size)
        if parsed is None:
            continue
        # Trust the parsed header's cputype: for thin files the fat-list
        # placeholder is None.
        slices.append((parsed["cputype"], parsed))
    if not slices:
        return out
    is_arm = lambda c: c in (CPU_TYPE_ARM64, CPU_TYPE_ARM64_32)
    arm_slices = [p for c, p in slices if is_arm(c)]
    if arm_slices:
        out["arm64"] = True
        best = arm_slices[0]
        out["filetype"] = best["filetype"]
        out["pie"] = best["pie"]
    else:
        best = slices[0][1]
    for p in arm_slices or [best]:
        if not is_arm(p["cputype"]):
            continue
        for entry in p["cmds"]:
            cmd = entry["cmd"]
            path = entry.get("path")
            if cmd == LC_LOAD_DYLIB:
                if path:
                    out["load_dylibs"].append(path)
            elif cmd == LC_LOAD_WEAK_DYLIB:
                if path:
                    out["weak_dylibs"].append(path)
            elif cmd == LC_REEXPORT_DYLIB:
                if path:
                    out["reexport_dylibs"].append(path)
            elif cmd == LC_ID_DYLIB:
                out["id_dylib"] = path
            elif cmd == LC_RPATH:
                if path:
                    out["rpaths"].append(path)
            elif cmd in (LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS):
                if entry.get("platform") == PLATFORM_IOS and "minos_packed" in entry:
                    v = _unpack_version(entry["minos_packed"])
                    if out["min_ios"] is None or v > out["min_ios"]:
                        out["min_ios"] = v
    return out
