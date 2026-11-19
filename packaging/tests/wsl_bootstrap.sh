#!/usr/bin/env bash
set -euo pipefail
# Disposable CI distro only. Never run on a user's existing host.
[ "${POCKET_ISOLATED_TEST:-}" = 1 ] && [ "$(id -u)" = 0 ]
if id pockettest >/dev/null 2>&1; then
  echo 'Refusing to overwrite an existing test user' >&2
  exit 1
fi
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y sudo dbus-user-session python3
useradd --create-home --shell /bin/bash pockettest
python3 - <<'PY'
import configparser
from pathlib import Path
config = configparser.ConfigParser()
path = Path('/etc/wsl.conf')
config.read(path)
for section, key, value in [('boot', 'systemd', 'true'), ('user', 'default', 'pockettest')]:
    if not config.has_section(section):
        config.add_section(section)
    config.set(section, key, value)
with path.open('w') as f:
    config.write(f)
sudoers = Path('/etc/sudoers.d/pocket-ci-test')
sudoers.write_text('pockettest ALL=(ALL) NOPASSWD:ALL\n')
sudoers.chmod(0o440)
PY
