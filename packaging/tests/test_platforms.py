import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
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
