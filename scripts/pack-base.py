#!/usr/bin/env python3
"""Pack a prepared device (firmwarekit create output) into one blob for the app bundle, and back.

    pack-base.py pack   BASE-DIR OUT.itbase     every regular file under BASE-DIR (.DS_Store skipped)
    pack-base.py unpack IN.itbase DIR           what the app's BundledBase.unpack does

The format is the guest package's (.itpack, qemu-ios contrib/guest-package/mkpkg.py): "ITPACK01", a
little-endian u32 index length, {"entries": [{"name", "size", "mode"}]} in stream order, then one zlib
stream of the files' bytes. Not an archive: the notary opens anything it recognises as one and rejects
the armv6 Mach-Os an iOS filesystem's pages contain (see nandpack.py). pack ends by reading its own
output back and checking every file's hash; the app reads it as a stream, so a base never sits in
memory at once.
"""
import hashlib
import json
import os
import struct
import sys
import zlib

MAGIC = b"ITPACK01"
CHUNK = 1 << 20


def files(base):
    out = []
    for dirpath, dirs, names in os.walk(base):
        dirs.sort()
        for name in sorted(names):
            if name == ".DS_Store":
                continue
            path = os.path.join(dirpath, name)
            if os.path.isfile(path) and not os.path.islink(path):
                out.append((os.path.relpath(path, base), os.path.getsize(path), os.stat(path).st_mode & 0o777))
    return out


def pack(base, out_path):
    entries = files(base)
    if not entries:
        sys.exit(f"pack-base: nothing under {base}")
    index = json.dumps({"entries": [{"name": n, "size": s, "mode": m} for n, s, m in entries]}).encode()
    hashes = {}
    comp = zlib.compressobj(6)
    with open(out_path, "wb") as f:
        f.write(MAGIC + struct.pack("<I", len(index)) + index)
        for name, size, _ in entries:
            digest = hashlib.sha256()
            with open(os.path.join(base, name), "rb") as source:
                while chunk := source.read(CHUNK):
                    digest.update(chunk)
                    f.write(comp.compress(chunk))
            hashes[name] = digest.hexdigest()
        f.write(comp.flush())
    checked = 0
    for name, _, digest in read(out_path):
        if hashes[name] != digest:
            sys.exit(f"pack-base: {name} did not round-trip")
        checked += 1
    if checked != len(entries):
        sys.exit("pack-base: the index did not round-trip")
    print(f"packed {len(entries)} files ({sum(s for _, s, _ in entries) / 1e6:.1f} MB) -> {out_path} ({os.path.getsize(out_path) / 1e6:.1f} MB)")


def read(path, sink=None):
    """Yields (name, mode, sha256) per file, streaming; `sink(name, mode, chunk)` receives the bytes."""
    with open(path, "rb") as f:
        head = f.read(12)
        if head[:8] != MAGIC:
            sys.exit(f"pack-base: {path} is not a packed device")
        entries = json.loads(f.read(struct.unpack("<I", head[8:])[0]))["entries"]
        dec = zlib.decompressobj()
        pending = b""

        def take(n):
            nonlocal pending
            while len(pending) < n:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                pending += dec.decompress(chunk)
            if len(pending) < n:
                sys.exit("pack-base: truncated stream")
            out, pending = pending[:n], pending[n:]
            return out

        for e in entries:
            digest, left = hashlib.sha256(), e["size"]
            if sink:
                sink(e["name"], e.get("mode", 0o644), b"")
            while left:
                chunk = take(min(left, CHUNK))
                digest.update(chunk)
                if sink:
                    sink(e["name"], e.get("mode", 0o644), chunk)
                left -= len(chunk)
            yield e["name"], e.get("mode", 0o644), digest.hexdigest()


def unpack(path, directory):
    handles = {}

    def sink(name, mode, chunk):
        target = os.path.join(directory, name)
        if name not in handles:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            handles[name] = open(target, "wb")
        handles[name].write(chunk)

    count = 0
    for name, mode, _ in read(path, sink):
        handles.pop(name).close()
        os.chmod(os.path.join(directory, name), mode)
        count += 1
    print(f"unpacked {count} files -> {directory}")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "pack":
        pack(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "unpack":
        unpack(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
