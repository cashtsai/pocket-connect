#!/usr/bin/env python3
"""Build Ubuntu .deb / portable Linux and Windows WSL preview packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
MAC_PACKAGING = REPO / "mac-app/packaging"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def runtime_file(name):
    p = Path(name)
    if any(part.startswith(".") for part in p.parts) or "__fixtures__" in p.parts:
        return False
    if len(p.parts) == 1:
        return (p.suffix == ".py" and not name.startswith("poc_")) or name in ["requirements.txt", "LICENSE"]
    return (p.parts[0] == "harness" and p.suffix == ".py") or (
        p.parts[:2] == ("static", "console") and p.suffix in [".js", ".html", ".css", ".json", ".png", ".woff2", ".txt"]
    ) or name == "deploy/bridge-supervisor.sh"


def prepare_bridge(source, destination):
    dirty = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True)
    if dirty:
        raise ValueError("Bridge checkout must have no tracked modifications")
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    names = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z"]).decode().split("\0")
    for name in filter(runtime_file, filter(None, names)):
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Non-regular runtime file: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    shutil.copy2(MAC_PACKAGING / "BRIDGE_README.md", destination / "README.md")
    run(["python3", MAC_PACKAGING / "sanitize_bridge_payload.py", destination])
    run(["python3", MAC_PACKAGING / "verify_payload_clean.py", destination])
    token = re.compile(rb'(BRIDGE_TOKEN|TELEGRAM_BOT_TOKEN|API_KEY)["\'>= ]+[A-Za-z0-9_:-]{20,}')
    for p in destination.rglob("*"):
        if not p.is_file():
            continue
        data = p.read_bytes()
        if re.search(rb"BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY", data) or token.search(data):
            raise ValueError(f"Credential shape found in {p.relative_to(destination)}; refusing to package")
        if p.suffix == ".py":
            compile(data, str(p), "exec")
    return revision


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    path.chmod(0o644)


def public_tar_metadata(info):
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mode = 0o755 if info.isdir() or info.name == "pocket-connect/pocket-connect" else 0o644
    info.pax_headers = {}
    return info


def build(source, output, version, no_deb=False):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z]+\.[0-9]+)?", version):
        raise ValueError("Version must be semver, optionally -preview.N")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pocket-packaging-") as temporary:
        temp = Path(temporary)
        root = temp / "pocket-connect"
        root.mkdir()
        revision = prepare_bridge(source, root / "bridge")
        shutil.copy2(REPO / "packaging/linux/pocket-connect", root / "pocket-connect")
        os.chmod(root / "pocket-connect", 0o755)
        shutil.copy2(REPO / "packaging/README.md", root / "README.md")
        write_json(root / "manifest.json", {"schema": 1, "version": version, "bridge_revision": revision,
                   "files": {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob("*")) if p.is_file()}})
        archive = output / f"Pocket-Connect-{version}-linux.tar.gz"
        with tarfile.open(archive, "w:gz") as tf:
            tf.add(root, arcname="pocket-connect", filter=public_tar_metadata)
        windows = temp / "windows"
        shutil.copytree(REPO / "packaging/windows", windows)
        shutil.copy2(archive, windows / "Pocket-Connect-linux.tar.gz")
        shutil.copy2(REPO / "packaging/README.md", windows / "README.md")
        write_json(windows / "windows-manifest.json", {"schema": 1, "version": version,
                   "files": {p.name: sha(p) for p in sorted(windows.iterdir()) if p.is_file()}})
        winzip = output / f"Pocket-Connect-{version}-windows-wsl2.zip"
        with zipfile.ZipFile(winzip, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(windows.iterdir()):
                z.write(p, arcname=f"Pocket-Connect/{p.name}")
        artifacts = [archive, winzip]
        if not no_deb:
            if not shutil.which("dpkg-deb"):
                raise ValueError("dpkg-deb required; build on Ubuntu or use --no-deb for archive-only builds")
            debversion = version.replace("-preview.", "~preview.")
            deb = output / f"pocket-connect_{debversion}_all.deb"
            run(["python3", REPO / "packaging/build_deb_from_archive.py", archive, "--output", output])
            artifacts.append(deb)
        checksums = output / f"Pocket-Connect-{version}-SHA256SUMS"
        checksums.write_text("".join(f"{sha(p)}  {p.name}\n" for p in artifacts))
        print("Built sanitized packages for bridge " + revision)
        for p in artifacts + [checksums]:
            print(p)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=REPO / "dist")
    parser.add_argument("--version", default="1.0.2-preview.2")
    parser.add_argument("--no-deb", action="store_true")
    args = parser.parse_args()
    build(args.bridge_source.resolve(), args.output.resolve(), args.version, args.no_deb)
