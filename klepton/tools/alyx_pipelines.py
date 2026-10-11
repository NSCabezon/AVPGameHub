#!/usr/bin/env python3
"""alyx_pipelines.py: rebuild Half-Life: Alyx's Vulkan pipeline list (.foz, for KL_FOZ_REPLAY) from the player's
own game files, so no Valve shader code is ever in this repository.

Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox) engine/pipelines.py, engine/gb/foz.py,
engine/gb/vpk.py and engine/gb/vcs.py — Copyright (c) 2026 the Glovebox contributors, MIT License (the full
notice is in Glovebox's LICENSE). Folded into one stdlib-only file here.

A pipeline list is a Fossilize stream archive (github.com/ValveSoftware/Fossilize, MIT) recorded while playing
(KL_FOZ_RECORD). Its shader modules are the game's own SPIR-V, which may not be published; but each one is a
byte-identical slice of a .vcs shader file inside the game's shaders_vulkan_dir.vpk. A *recipe* is the archive
with every shader module replaced by where to find it (pack, .vcs file, static combo, offset, size, SHA-256); the
rest is Vulkan state (pipeline settings, layouts). Recipes and .foz files are kept OUT of git (BUILDING.md).

  alyx_pipelines.py make  <out.recipe> <game dir> <recorded.foz>... [--allow-missing]   recordings -> recipe
  alyx_pipelines.py build <recipe> <game dir> <out.foz>                                 recipe -> .foz
  alyx_pipelines.py merge <out.recipe> <recipe>...                                      union of recipes
  alyx_pipelines.py check <recipe>                                                      no shader code inside?

<game dir> is the content depot's game/ folder (core/ and hlvr/ with shaders_vulkan_dir.vpk), e.g.
game/content/game. Glovebox's own alyx.recipe (packages/alyx/pipelines/) is for Steam build 25487405, depot
manifests 546561=1436897171613240821 and 546564=9198205754520568813; `build` verifies every module's SHA-256
and fails by name on a different game build."""
import hashlib
import json
import lzma
import os
import struct
import sys
import zlib
from multiprocessing import Pool
from types import SimpleNamespace


# ---- Fossilize stream archives (Glovebox engine/gb/foz.py) ----
TAG_SHADER_MODULE = "04"
FORMAT_RAW, FORMAT_DEFLATE = 1, 2


def read(path):
    """(file header, [(name, format, crc, size, stored bytes)])"""
    d = open(path, "rb").read()
    out, off = [], 16
    while off + 56 <= len(d):
        name = d[off : off + 40].decode()
        stored, fmt, crc, size = struct.unpack_from("<4I", d, off + 40)
        end = off + 56 + stored
        if end > len(d):
            break  # a torn tail (the recorder was killed mid-write): Fossilize skips it too
        out.append((name, fmt, crc, size, d[off + 56 : end]))
        off = end
    return d[:16], out


def payload(fmt, stored):
    return zlib.decompress(stored) if fmt == FORMAT_DEFLATE else stored


def entry_bytes(name, payload_bytes):
    """A raw (uncompressed) entry with its CRC, as Fossilize itself writes one."""
    crc = zlib.crc32(payload_bytes) & 0xFFFFFFFF
    n = len(payload_bytes)
    return name.encode() + struct.pack("<4I", n, FORMAT_RAW, crc, n) + payload_bytes


def split_module(p):
    """A shader module payload -> (its JSON header, SPIR-V bytes). The code follows the JSON's NUL as LEB128
    varints, one per 32-bit word."""
    j = p.index(b"\0")
    meta = json.loads(p[:j])
    (_, m), = meta["shaderModules"].items()
    start = j + 1 + m["varintOffset"]
    words, v, s = [], 0, 0
    for x in p[start : start + m["varintSize"]]:
        v |= (x & 0x7F) << s
        s += 7
        if not x & 0x80:
            words.append(v)
            v, s = 0, 0
    code = struct.pack(f"<{len(words)}I", *words)
    if len(code) != m["codeSize"]:
        raise ValueError(f"shader module decodes to {len(code)} bytes, header says {m['codeSize']}")
    return p[:j], code


def join_module(json_header, code):
    meta = json.loads(json_header)
    (_, m), = meta["shaderModules"].items()
    words = struct.unpack(f"<{len(code) // 4}I", code)
    enc = bytearray()
    for w in words:
        while True:
            b = w & 0x7F
            w >>= 7
            if w:
                enc.append(b | 0x80)
            else:
                enc.append(b)
                break
    if len(enc) != m["varintSize"] or m["varintOffset"] != 0:
        raise ValueError("shader module re-encodes to a different size")
    return json_header + b"\0" + bytes(enc)


foz = SimpleNamespace(TAG_SHADER_MODULE=TAG_SHADER_MODULE, FORMAT_RAW=FORMAT_RAW, FORMAT_DEFLATE=FORMAT_DEFLATE,
                      read=read, payload=payload, entry_bytes=entry_bytes, split_module=split_module,
                      join_module=join_module)


# ---- Valve packs (Glovebox engine/gb/vpk.py) ----
class VPK:
    def __init__(self, dir_path):
        if not dir_path.endswith("_dir.vpk"):
            raise ValueError(f"{dir_path}: not a *_dir.vpk")
        self.dir_path = dir_path
        self.base = dir_path[: -len("_dir.vpk")]
        d = open(dir_path, "rb").read()
        sig, ver, tree = struct.unpack_from("<III", d, 0)
        if sig != 0x55AA1234:
            raise ValueError(f"{dir_path}: bad VPK signature")
        hdr = 12 if ver == 1 else 28
        self._inline_base = hdr + tree
        self._dir = d
        self.entries = {}
        off = hdr

        def rs():
            nonlocal off
            e = d.index(b"\0", off)
            s = d[off:e].decode("latin1")
            off = e + 1
            return s

        while True:
            ext = rs()
            if not ext:
                break
            while True:
                path = rs()
                if not path:
                    break
                while True:
                    name = rs()
                    if not name:
                        break
                    _crc, pre, arc, aoff, alen, _term = struct.unpack_from("<IHHIIH", d, off)
                    off += 18
                    full = (f"{path}/" if path.strip() else "") + f"{name}.{ext}"
                    self.entries[full] = (arc, aoff, alen, off, pre)
                    off += pre

    def read(self, name):
        arc, aoff, alen, poff, pre = self.entries[name]
        data = self._dir[poff : poff + pre]
        if alen:
            if arc == 0x7FFF:
                start = self._inline_base + aoff
                data += self._dir[start : start + alen]
            else:
                with open(f"{self.base}_{arc:03d}.vpk", "rb") as f:
                    f.seek(aoff)
                    data += f.read(alen)
        return data


# ---- compiled shader files (Glovebox engine/gb/vcs.py) ----
SPIRV_MAGIC = b"\x03\x02\x23\x07"
_LZMA_MAGIC = 0x414D5A4C  # "LZMA"


def static_table(d):
    """{static combo id: file offset} or None (a *_features.vcs file has no code). The table sits just before a
    field holding the file's length and is found by its shape: n, n int64 ids, n int32 offsets."""
    key = struct.pack("<i", len(d))
    q = d.find(key)
    while q >= 0:
        for n in range(1, 50000):
            p = q - 12 * n - 4
            if p < 0:
                break
            if struct.unpack_from("<i", d, p)[0] == n and struct.unpack_from("<i", d, p + 4 + 8 * n)[0] == q + 4:
                ids = struct.unpack_from(f"<{n}q", d, p + 4)
                offs = struct.unpack_from(f"<{n}i", d, p + 4 + 8 * n)
                return dict(zip(ids, offs))
        q = d.find(key, q + 1)
    return None


def static_blob(d, off):
    _, magic, usize, csize = struct.unpack_from("<4i", d, off)
    if magic != _LZMA_MAGIC:
        raise ValueError(f"static combo at {off}: not LZMA ({magic:#x})")
    props = d[off + 16 : off + 21]
    lc, lp, pb = props[0] % 9, (props[0] // 9) % 5, props[0] // 45
    dict_size = struct.unpack_from("<I", props, 1)[0]
    dec = lzma.LZMADecompressor(
        lzma.FORMAT_RAW,
        filters=[{"id": lzma.FILTER_LZMA1, "dict_size": dict_size, "lc": lc, "lp": lp, "pb": pb}],
    )
    return dec.decompress(d[off + 21 : off + 21 + csize], max_length=usize)


def spirv_starts(blob):
    pos = blob.find(SPIRV_MAGIC)
    while pos >= 0:
        yield pos
        pos = blob.find(SPIRV_MAGIC, pos + 4)


vcs = SimpleNamespace(SPIRV_MAGIC=SPIRV_MAGIC, static_table=static_table, static_blob=static_blob,
                      spirv_starts=spirv_starts)


# ---- the recipe (Glovebox engine/pipelines.py) ----
PACKS = ("core/shaders_vulkan_dir.vpk", "hlvr/shaders_vulkan_dir.vpk")
REF_MAGIC = b"GBREF"
KEY = 64  # bytes of SPIR-V that index a candidate match

_vpks, _keys = {}, {}


def _vpk(game, pack):
    k = (game, pack)
    if k not in _vpks:
        _vpks[k] = VPK(os.path.join(game, pack))
    return _vpks[k]


def _init_scan(keys):
    _keys.update(keys)


def _scan(job):
    game, pack, path = job
    d = _vpk(game, pack).read(path)
    table = vcs.static_table(d)
    found = []
    if not table:
        return found
    for sid, off in table.items():
        blob = vcs.static_blob(d, off)
        for pos in vcs.spirv_starts(blob):
            for size, sha1, name in _keys.get(blob[pos : pos + KEY], ()):
                if hashlib.sha1(blob[pos : pos + size]).digest() == sha1:
                    found.append((name, pack, path, sid, pos))
    return found


def make(out, game, inputs, allow_missing=False):
    header, merged, seen = None, [], set()
    for path in inputs:
        h, entries = foz.read(path)
        header = header or h
        for e in entries:
            if e[0] not in seen:
                seen.add(e[0])
                merged.append(e)
    modules = {}
    for name, fmt, _crc, _size, stored in merged:
        if name[22:24] == foz.TAG_SHADER_MODULE:
            modules[name] = foz.split_module(foz.payload(fmt, stored))
    keys = {}
    for name, (_, code) in modules.items():
        keys.setdefault(code[:KEY], []).append((len(code), hashlib.sha1(code).digest(), name))
    jobs = [(game, pack, p) for pack in PACKS for p in _vpk(game, pack).entries if p.endswith(".vcs")]
    jobs.sort(key=lambda j: -_vpk(game, j[1]).entries[j[2]][2])  # biggest first keeps the pool busy
    where = {}
    with Pool(min(24, os.cpu_count() or 4), initializer=_init_scan, initargs=(keys,)) as pool:
        for found in pool.imap_unordered(_scan, jobs):
            for name, pack, path, sid, pos in found:
                cand = (pack, path, sid, pos)
                if name not in where or cand < where[name]:
                    where[name] = cand  # the same module can sit in several combos: keep a stable choice
    missing = sorted(set(modules) - set(where))
    print(f"{len(merged)} entries, {len(modules)} shader modules, {len(where)} found in the game's shader files, "
          f"{len(missing)} missing")
    if missing and not allow_missing:
        for m in missing[:20]:
            print("  missing", m)
        return 1
    with open(out, "wb") as f:
        f.write(header)
        for name, fmt, crc, size, stored in merged:
            if name[22:24] != foz.TAG_SHADER_MODULE:
                f.write(name.encode() + struct.pack("<4I", len(stored), fmt, crc, size) + stored)
                continue
            if name not in where:
                continue
            pack, path, sid, pos = where[name]
            jh, code = modules[name]
            ref = {"json": jh.decode(), "pack": pack, "file": path, "static": sid, "offset": pos,
                   "size": len(code), "sha256": hashlib.sha256(code).hexdigest()}
            p = REF_MAGIC + json.dumps(ref, separators=(",", ":")).encode()
            f.write(name.encode() + struct.pack("<4I", len(p), foz.FORMAT_RAW, 0, len(p)) + p)
    print(f"recipe: {out} ({os.path.getsize(out)} bytes)")
    return 0


def _resolve(job):
    game, pack, path, sid, refs = job
    d = _vpk(game, pack).read(path)
    table = vcs.static_table(d)
    blob = vcs.static_blob(d, table[sid])
    out = []
    for name, off, size, sha in refs:
        code = blob[off : off + size]
        if hashlib.sha256(code).hexdigest() != sha:
            raise ValueError(f"{path} static {sid} @{off}: not the expected shader (game files changed?)")
        out.append((name, code))
    return out


def build(recipe, game, out):
    header, entries = foz.read(recipe)
    groups, refs = {}, {}
    for name, fmt, _crc, _size, stored in entries:
        p = foz.payload(fmt, stored)
        if p.startswith(REF_MAGIC):
            r = json.loads(p[len(REF_MAGIC):])
            refs[name] = r
            groups.setdefault((r["pack"], r["file"], r["static"]), []).append((name, r["offset"], r["size"], r["sha256"]))
    codes = {}
    jobs = [(game, pack, path, sid, rs) for (pack, path, sid), rs in groups.items()]
    with Pool(min(12, os.cpu_count() or 4)) as pool:
        for got in pool.imap_unordered(_resolve, jobs):
            codes.update(got)
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        f.write(header)
        for name, fmt, crc, size, stored in entries:
            if name in refs:
                f.write(foz.entry_bytes(name, foz.join_module(refs[name]["json"].encode(), codes[name])))
            else:
                f.write(name.encode() + struct.pack("<4I", len(stored), fmt, crc, size) + stored)
    os.replace(tmp, out)
    print(f"pipelines: {out} ({len(entries)} entries, {len(refs)} shader modules from {len(groups)} shader combos)")
    return 0


def merge(out, inputs):
    header, seen, n = None, set(), 0
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        for path in inputs:
            h, entries = foz.read(path)
            if header is None:
                header = h
                f.write(h)
            for name, fmt, crc, size, stored in entries:
                if name in seen:
                    continue
                seen.add(name)
                n += 1
                f.write(name.encode() + struct.pack("<4I", len(stored), fmt, crc, size) + stored)
    os.replace(tmp, out)
    print(f"merged {len(inputs)} recipes: {n} entries -> {out}")
    return check(out)


def check(recipe):
    _, entries = foz.read(recipe)
    bad = 0
    for name, fmt, _crc, _size, stored in entries:
        p = foz.payload(fmt, stored)
        if name[22:24] == foz.TAG_SHADER_MODULE and not p.startswith(REF_MAGIC):
            bad += 1
        if vcs.SPIRV_MAGIC in p:
            bad += 1
    print(f"{recipe}: {len(entries)} entries, {'no shader code' if not bad else f'{bad} entries carry shader code'}")
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 4 and a[0] == "make":
        allow = "--allow-missing" in a
        a = [x for x in a if x != "--allow-missing"]
        sys.exit(make(a[1], a[2], a[3:], allow))
    if len(a) == 4 and a[0] == "build":
        sys.exit(build(a[1], a[2], a[3]))
    if len(a) >= 3 and a[0] == "merge":
        sys.exit(merge(a[1], a[2:]))
    if len(a) == 2 and a[0] == "check":
        sys.exit(check(a[1]))
    sys.exit(__doc__)
