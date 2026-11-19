#!/usr/bin/env python3
"""Build a .deb from an already sanitized portable package, using dpkg-deb."""
import argparse
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import shutil
import importlib.machinery
import importlib.util


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        with tarfile.open(args.archive) as tf:
            tf.extractall(root, filter="data")
        payload = root / "pocket-connect"
        loader = importlib.machinery.SourceFileLoader("controller", str(payload / "pocket-connect"))
        spec = importlib.util.spec_from_loader("controller", loader)
        controller = importlib.util.module_from_spec(spec)
        loader.exec_module(controller)
        manifest = controller.verify_package(payload)
        version = manifest["version"].replace("-preview.", "~preview.")
        package = root / "deb"
        shutil.copytree(payload, package / "usr/lib/pocket-connect")
        (package / "usr/bin").mkdir(parents=True)
        (package / "usr/bin/pocket-connect").symlink_to("../lib/pocket-connect/pocket-connect")
        desktop = package / "usr/share/applications"
        desktop.mkdir(parents=True)
        shutil.copy2(Path(__file__).parent / "linux/pocket-connect.desktop", desktop)
        control = package / "DEBIAN"
        control.mkdir()
        (control / "control").write_text(
            f"Package: pocket-connect\nVersion: {version}\nArchitecture: all\n"
            "Maintainer: Pocket <developer@shan.house>\nSection: net\nPriority: optional\n"
            "Depends: python3 (>= 3.10), python3-venv, ca-certificates, tmux, systemd, curl\n"
            "Homepage: https://pocketone.app\nDescription: Pocket Connect per-user bridge (preview)\n"
            " Run pocket-connect install as your normal user after installing this package.\n")
        for p in [package, *[p for p in package.rglob("*") if p.is_dir()]]:
            p.chmod(0o755)
        for p in package.rglob("*"):
            if p.is_file() and not p.is_symlink():
                p.chmod(0o755 if p == package / "usr/lib/pocket-connect/pocket-connect" else 0o644)
        args.output.mkdir(parents=True, exist_ok=True)
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(package), str(args.output / f"pocket-connect_{version}_all.deb")], check=True)


if __name__ == "__main__":
    main()
