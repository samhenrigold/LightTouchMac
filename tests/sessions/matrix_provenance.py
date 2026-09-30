"""Content identity and append-only evidence for matrix acceptance runs."""
import fcntl
import hashlib
import json
import os
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

FORMAT = 1

def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def artifact(path, exclude=()):
    """Hash bytes, not mtimes or installation paths; include tree-relative names."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"matrix provenance input is missing: {path}")
    files = sorted(p for p in path.rglob("*") if p.is_file() and "__pycache__" not in p.parts and p.name != ".DS_Store" and p.name not in exclude) if path.is_dir() else [path]
    rows = []
    for file in files:
        h = hashlib.sha256()
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(chunk)
        rows.append({"name": str(file.relative_to(path)) if path.is_dir() else "file", "sha256": h.hexdigest(), "bytes": file.stat().st_size})
    return {"sha256": digest_json(rows), "files": rows}

def source_state(root):
    """Context, alongside artifact hashes; never claim an untracked build is pinned."""
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True, stderr=subprocess.DEVNULL).strip()
    try:
        return {"commit": git("rev-parse", "HEAD"), "status": git("status", "--porcelain")}
    except (OSError, subprocess.CalledProcessError):
        return {"commit": None, "status": "unavailable"}

def identity(entry, inputs, options):
    value = {"format": FORMAT, "entry": entry, "inputs": inputs, "options": options}
    return {"sha256": digest_json(value), "contract": value}

def reusable(record, expected):
    # Failed, interrupted, or prerequisite-skipped attempts are useful history,
    # but must not suppress a new acceptance attempt.
    if not (record.get("provenance", {}).get("sha256") == expected["sha256"]
            and record.get("complete") is True and not record.get("first_failure")
            and not record.get("runner_error") and not record.get("skipped")):
        return False
    try:
        root = Path(record["artifacts"])
        stored = json.loads((root / "record.json").read_text())
        return stored == record and artifact(root, exclude=("record.json",)) == record["evidence"]
    except (OSError, KeyError, ValueError):
        return False

def run_directory(root, entry_id, identity_sha):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    path = Path(root) / entry_id / (stamp + "-" + identity_sha[:12] + "-" + uuid.uuid4().hex[:8])
    path.mkdir(parents=True, exist_ok=False)
    return path

def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    staged = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with staged.open("x") as stream:
            json.dump(value, stream, indent=1)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        staged.replace(path)
    finally:
        staged.unlink(missing_ok=True)

def preserve_previous(root, entry_id, record):
    """Retain legacy index records before replacing them, without moving artifacts."""
    if not record:
        return
    path = Path(root) / entry_id / "history" / (digest_json(record) + ".json")
    if not path.exists():
        atomic_json(path, record)

def update_index(path, mutate, after=None):
    """Serialize read/merge/publication across runners with different scratch dirs.

    Lock a stable sibling, not the atomically replaced index inode. Derived
    summaries are written while held too, so they cannot lag a newer index.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_name(path.name + ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = json.loads(path.read_text()) if path.exists() else {}
        updated = mutate(current)
        atomic_json(path, updated)
        if after is not None:
            after(updated)
        return updated

def publish_result(path, root, entry_id, record, after=None):
    def merge(current):
        preserve_previous(root, entry_id, current.get(entry_id))
        current[entry_id] = record
        return current
    return update_index(path, merge, after)
