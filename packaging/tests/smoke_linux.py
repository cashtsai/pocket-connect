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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--systemd", action="store_true")
    args = parser.parse_args()
    if os.geteuid() == 0 or not os.environ.get("POCKET_ISOLATED_TEST"):
        raise SystemExit("Requires explicit isolated normal-user test account")
    command = ["pocket-connect", "install", "--port", "18081"]
    if not args.systemd:
        command.append("--no-start")
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
        subprocess.run(["pocket-connect", "status"], check=True)
        subprocess.run(["pocket-connect", "doctor"], check=True)
        assert (home / ".local/share/pocket-connect/current/bridge/static/console/index.html").exists()
        print("PASS: install, runtime, authenticated capabilities, invalid-token rejection, QR gate, bundled Console")
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
    subprocess.run(["pocket-connect", "install", "--no-start"], check=True)
    assert token_file.read_text().strip() == token
    print("PASS: reinstall preserves pairing identity")


if __name__ == "__main__":
    main()
