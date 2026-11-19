#!/usr/bin/env python3
"""Run only in an isolated test account/container; never against production."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request


def request(path, token=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18081" + path, headers=headers), timeout=5) as r:
        return r.status, json.load(r)


def console_request(boot):
    req = urllib.request.Request("http://127.0.0.1:18081/console?boot=" + boot)
    with urllib.request.urlopen(req, timeout=5) as response:
        assert response.status == 200
        assert "text/html" in response.headers["Content-Type"]
        assert "data-console-access" in response.read().decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--systemd", action="store_true")
    parser.add_argument("--already-installed", action="store_true")
    args = parser.parse_args()
    if os.geteuid() == 0 or not os.environ.get("POCKET_ISOLATED_TEST"):
        raise SystemExit("Requires explicit isolated normal-user test account")
    command = ["pocket-connect", "install", "--port", "18081"]
    if not args.systemd:
        command.append("--no-start")
    if not args.already_installed:
        subprocess.run(command, check=True)
    home = Path.home()
    token_file = home / ".config/pocket-connect/bridge-token"
    token = token_file.read_text().strip()
    assert token_file.stat().st_mode & 0o777 == 0o600
    process = None
    if not args.systemd:
        log = (home / "smoke.log").open("w")
        process = subprocess.Popen(["pocket-connect", "run"], stdout=log, stderr=log)
    passed = False
    try:
        for i in range(40):
            try:
                request("/health")
                break
            except (OSError, ValueError):
                if i == 39:
                    raise
                time.sleep(1)
        assert request("/capabilities", token)[0] == 200
        for invalid in [None, "invalid-token"]:
            try:
                request("/capabilities", invalid)
                raise AssertionError("Unauthorized access unexpectedly accepted")
            except urllib.error.HTTPError as error:
                assert error.code in [401, 403], error.code
        try:
            request("/pair/qr.json?boot=wrong-code")
            raise AssertionError("Pair gate accepted wrong code")
        except urllib.error.HTTPError as error:
            assert error.code in [401, 403]
        boot = (home / ".config/pocket-connect/pair-boot-code").read_text().strip()
        assert request("/pair/qr.json?boot=" + boot)[0] == 200
        console_request(boot)
        for endpoint in ["/console?boot=wrong-code", "/app/v1/agents/codex/login/status?login_id=missing"]:
            try:
                request(endpoint)
                raise AssertionError("Unauthorized entry unexpectedly accepted")
            except urllib.error.HTTPError as error:
                assert error.code in [401, 403], error.code
        # Only a local loopback test route; never advertise or contact a public host.
        route_file = home / ".config/pocket-connect/tunnel-url"
        assert not route_file.exists()
        try:
            route_file.write_text("http://127.0.0.1:18081")
            result = subprocess.run(["pocket-connect", "pair", "--link"], check=True, capture_output=True, text=True)
            assert result.stdout.startswith("pocket://pair?")
        finally:
            route_file.unlink(missing_ok=True)
        subprocess.run(["pocket-connect", "status"], check=True)
        subprocess.run(["pocket-connect", "doctor"], check=True)
        assert (home / ".local/share/pocket-connect/current/bridge/static/console/index.html").exists()
        print("PASS: runtime, authenticated capabilities, invalid-token rejection, QR gate, actual Console page, headless link (test route only)")
        passed = True
    finally:
        if not passed:
            if process:
                print((home / "smoke.log").read_text()[-12000:])
            else:
                subprocess.run(["pocket-connect", "logs"], check=False)
        if process:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()
        elif args.systemd:
            subprocess.run(["pocket-connect", "stop"], check=True)
    if not args.already_installed:
        subprocess.run(["pocket-connect", "install", "--no-start"], check=True)
        assert token_file.read_text().strip() == token
        print("PASS: reinstall preserves pairing identity")


if __name__ == "__main__":
    main()
