#!/usr/bin/env python3
"""The identity scan of a release: does anything in this zip name who or what built it?

    scan-release-zip.py APP.zip [--also WORD]...

Reads every file in the zip, and inside the guest archive (.aar, through `aa`), nested zips and the built-in device's
compressed NAND chunks (.z): the builder's home folder, user, host, email, serial and hardware UUID, read from this Mac
when it runs so that none is written down here; private keys and App Store Connect key names; and files that have no
place in a release. Prints one line per finding and exits 1 on any; exits 2 if it can't do the scan. The public name
of the project and its signing identity aren't findings: the bundle IDs and license texts carry the first, and a code
signature must carry the second.
"""
import io
import os
import pwd
import re
import subprocess
import sys
import tempfile
import zipfile
import zlib

# What a signature or a credit may say of the builder: taken out before a file is searched.
PUBLIC = [rb"Developer ID Application: [^\0\n]{1,80}", rb"Developer ID Certification Authority"]
SECRET = [
    # A key has its body after the header; OpenSSH's sshd carries the header alone, as the format it parses.
    (rb"-----BEGIN [A-Z ]*PRIVATE KEY-----\r?\n[A-Za-z0-9+/=]{40}", "a private key"),
    (rb"AuthKey_[A-Z0-9]{10}\.p8", "an App Store Connect key name"),
    (rb"LTM_NOTARY_(?:KEY|ISSUER)=", "notarization settings"),
]
BAD_NAME = re.compile(r"(^|/)(\.DS_Store|\.git|__MACOSX|notary\.env)(/|$)|\.(p8|p12|mobileprovision|xcarchive|dSYM)(/|$)")


def run(*argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def builder():
    """The strings that identify this Mac and its user, as (bytes, what); only ones long enough to mean something."""
    entry = pwd.getpwuid(os.getuid())
    found = [(entry.pw_dir, "the home folder")]
    found += [("/Users/" + entry.pw_name + "/", "the user's home path")]
    for host in {run("hostname"), run("scutil", "--get", "LocalHostName"), run("scutil", "--get", "ComputerName")}:
        found.append((host, "the host name"))
    full = entry.pw_gecos.split(",")[0]
    found.append((full, "the user's full name"))
    for key in ["user.email"]:
        found.append((run("git", "config", "--global", key), "the git email"))
    hardware = run("ioreg", "-rd1", "-c", "IOPlatformExpertDevice")
    for key, what in [("IOPlatformSerialNumber", "the Mac's serial"), ("IOPlatformUUID", "the Mac's hardware UUID")]:
        match = re.search(key + r'" = "([^"]+)"', hardware)
        if match:
            found.append((match.group(1), what))
    return [(text.encode(), what) for text, what in found if len(text) >= 6]


def search(name, data, words, findings):
    for pattern in PUBLIC:
        data = re.sub(pattern, b"", data)
    lowered = data.lower()
    for word, what in words:
        if word.lower() in lowered:
            findings.append(f"{name}: {what}")
    for pattern, what in SECRET:
        if re.search(pattern, data):
            findings.append(f"{name}: {what}")


def scan_aar(name, data, words, findings):
    with tempfile.TemporaryDirectory() as root:
        archive = os.path.join(root, "a.aar")
        with open(archive, "wb") as file:
            file.write(data)
        out = os.path.join(root, "out")
        os.mkdir(out)
        done = subprocess.run(["aa", "extract", "-i", archive, "-d", out], capture_output=True)
        if done.returncode != 0:
            findings.append(f"{name}: can't be read, so it wasn't scanned")
            return
        for folder, _, files in os.walk(out):
            for leaf in files:
                path = os.path.join(folder, leaf)
                if not os.path.islink(path):
                    with open(path, "rb") as file:
                        scan(f"{name}!{os.path.relpath(path, out)}", file.read(), words, findings)


def scan(name, data, words, findings):
    if os.path.basename(name).startswith("._"):  # ditto's AppleDouble of a file's attributes, not the file's format
        search(name, data, words, findings)
        return
    if BAD_NAME.search(name):
        findings.append(f"{name}: has no place in a release")
    if name.endswith(".aar"):
        scan_aar(name, data, words, findings)
    elif data[:4] == b"PK\x03\x04":
        with zipfile.ZipFile(io.BytesIO(data)) as nested:
            scan_zip(nested, name + "!", words, findings)
    elif name.endswith(".z"):
        try:
            search(name, zlib.decompress(data), words, findings)
        except zlib.error:
            findings.append(f"{name}: can't be read, so it wasn't scanned")
    else:
        search(name, data, words, findings)


def scan_zip(archive, prefix, words, findings):
    for info in archive.infolist():
        if not info.is_dir():
            scan(prefix + info.filename, archive.read(info), words, findings)
        elif BAD_NAME.search(prefix + info.filename):
            findings.append(f"{prefix}{info.filename}: has no place in a release")


def main(argv):
    if len(argv) < 2 or not os.path.isfile(argv[1]):
        print(__doc__, file=sys.stderr)
        return 2
    words = builder()
    for index, arg in enumerate(argv):
        if arg == "--also":
            words.append((argv[index + 1].encode(), f'"{argv[index + 1]}"'))
    findings = []
    try:
        with zipfile.ZipFile(argv[1]) as archive:
            scan_zip(archive, "", words, findings)
    except (OSError, zipfile.BadZipFile) as error:
        print(f"can't scan {argv[1]}: {error}", file=sys.stderr)
        return 2
    for finding in sorted(set(findings)):
        print(finding)
    print(f"{len(set(findings))} finding(s), {len(words)} identifiers searched")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
