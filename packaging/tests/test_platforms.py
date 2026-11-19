import hashlib
import argparse
from contextlib import ExitStack
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    result = importlib.util.module_from_spec(spec)
    loader.exec_module(result)
    return result


controller = module("controller", ROOT / "packaging/linux/pocket-connect")
builder = module("builder", ROOT / "packaging/build_platforms.py")
sanitizer = module("sanitizer", ROOT / "mac-app/packaging/sanitize_bridge_payload.py")
verifier = module("verifier", ROOT / "mac-app/packaging/verify_payload_clean.py")


class PackageTests(unittest.TestCase):
    def test_public_network_constant_is_preserved_but_host_addresses_are_not(self):
        import ipaddress
        text = 'ipaddress.ip_network("100.64.0.0/10")'
        for pattern, replacement in sanitizer.SHAPE_RULES:
            text = pattern.sub(replacement, text)
        self.assertIn('100.64.0.0/10', text)
        self.assertEqual(ipaddress.ip_network('100.64.0.0/10').prefixlen, 10)
        self.assertIsNone(verifier.SHAPES['tailnet IP'].search(text))
        self.assertIsNotNone(verifier.SHAPES['tailnet IP'].search('100.64.0.0'))
        self.assertIsNotNone(verifier.SHAPES['tailnet IP'].search('100.71.2.3'))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = ["bridge/bridge.py", "bridge/requirements.txt", "bridge/deploy/bridge-supervisor.sh", "pocket-connect"]
        digests = {}
        for name in files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("sample\n")
            digests[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        (self.root / "manifest.json").write_text(json.dumps({"schema": 1, "version": "1.0.2-preview.1", "files": digests}))

    def test_complete_manifest(self):
        self.assertEqual(controller.verify_package(self.root)["version"], "1.0.2-preview.1")

    def test_tampered_runtime_rejected(self):
        (self.root / "bridge/bridge.py").write_text("changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            controller.verify_package(self.root)

    def test_unlisted_secret_rejected(self):
        (self.root / ".env").write_text("not a real secret")
        with self.assertRaisesRegex(ValueError, "contents"):
            controller.verify_package(self.root)

    def test_symlink_rejected(self):
        path = self.root / "bridge/bridge.py"
        path.unlink()
        path.symlink_to("/etc/passwd")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            controller.verify_package(self.root)

    def test_payload_allowlist(self):
        for name in ["secrets/token", ".env", "docs/notes.md", "deploy/live.plist", "tests/check.py", "poc_experiment.py", "static/console/__fixtures__/approval-preview.html"]:
            self.assertFalse(builder.runtime_file(name), name)
        for name in ["bridge.py", "harness/store.py", "static/console/app.js", "deploy/bridge-supervisor.sh", "LICENSE"]:
            self.assertTrue(builder.runtime_file(name), name)

    def test_private_atomic_write(self):
        path = self.root / "config/token"
        controller.private_write(path, "first")
        controller.private_write(path, "second")
        self.assertEqual(path.read_text(), "second")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_systemd_escaping(self):
        self.assertEqual(controller.unit_quote('/home/A B%/"test'), '"/home/A B%%/\\"test"')
        with self.assertRaises(ValueError):
            controller.unit_quote("bad\npath")
        self.assertIn("WorkingDirectory=%h/.local/share/pocket-connect/current/bridge\n", controller.unit_text())

    def test_failed_first_install_can_be_retried(self):
        self.check_failed_install(previous=False)

    def test_failed_upgrade_restores_runtime_and_settings(self):
        self.check_failed_install(previous=True)

    def check_failed_install(self, previous):
        home = self.root / "home"
        base = home / ".local/share/pocket-connect"
        config = home / ".config/pocket-connect"
        unit = home / ".config/systemd/user/pocket-connect.service"
        current = base / "current"
        old = base / "releases/old"
        args = argparse.Namespace(package_dir=str(self.root), no_start=False, port=0, lan=False)
        # The package fixture must not include mutable installation state.
        package = tempfile.TemporaryDirectory()
        self.addCleanup(package.cleanup)
        import shutil
        shutil.copytree(self.root, Path(package.name) / "payload")
        args.package_dir = str(Path(package.name) / "payload")
        if previous:
            old.mkdir(parents=True)
            current.symlink_to(old)
            unit.parent.mkdir(parents=True)
            unit.write_text("old unit")
            config.mkdir(parents=True)
            (config / "settings.json").write_text('{"port": 18081, "bind": "127.0.0.1"}')
            (base / "pocket-connect").write_bytes(b"old launcher")
        def fail_restart(command, **kwargs):
            if command[:3] == ["systemctl", "--user", "restart"]:
                raise subprocess.CalledProcessError(1, command)
        with ExitStack() as stack:
            for key, value in {"HOME": home, "BASE": base, "CONFIG": config, "STATE": home / "state", "UNIT_FILE": unit, "CURRENT": current}.items():
                stack.enter_context(patch.object(controller, key, value))
            stack.enter_context(patch.object(controller, "check_platform"))
            stack.enter_context(patch.object(controller, "systemd_ready", return_value=True))
            stack.enter_context(patch.object(controller.subprocess, "run"))
            stack.enter_context(patch.object(controller.socket, "socket"))
            stack.enter_context(patch.object(controller, "run", side_effect=fail_restart))
            with self.assertRaises(subprocess.CalledProcessError):
                controller.install(args)
            if previous:
                self.assertEqual(current.resolve(), old.resolve())
                self.assertEqual(unit.read_text(), "old unit")
                self.assertEqual((base / "pocket-connect").read_bytes(), b"old launcher")
                self.assertNotIn("version", json.loads((config / "settings.json").read_text()))
            else:
                self.assertFalse(unit.exists())
                self.assertFalse(current.is_symlink())
                args.no_start = True
                controller.install(args)
                self.assertTrue(current.is_symlink())

    def test_switch_preserves_previous(self):
        previous = self.root / "releases/old"
        next_release = self.root / "releases/new"
        previous.mkdir(parents=True)
        next_release.mkdir()
        current = self.root / "current"
        current.symlink_to(previous)
        with patch.object(controller, "BASE", self.root), patch.object(controller, "CURRENT", current):
            controller.switch(next_release)
        self.assertEqual(current.resolve(), next_release.resolve())
        self.assertTrue(previous.exists())

    def test_runtime_port_and_secret_source(self):
        (self.root / "bridge-token").write_text("test-token")
        with patch.object(controller, "CONFIG", self.root):
            env = controller.runtime_env({"port": 18081, "path": "/sample/bin"})
        self.assertEqual(env["BRIDGE_TOKEN"], "test-token")
        self.assertIn(":18081/", env["CCSESS_HOOK_URL"])
        self.assertIn("/sample/bin", env["PATH"])


if __name__ == "__main__":
    unittest.main()
