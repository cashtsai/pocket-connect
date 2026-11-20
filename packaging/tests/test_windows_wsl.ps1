param([Parameter(Mandatory=$true)][string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:RUNNER_TEMP) {
    throw 'This test requires a disposable GitHub-hosted CI runner. Never use a personal Windows host.'
}
$testDistro = 'PocketConnectCI'
function Invoke-TestWsl {
    param([string[]]$Command)
    & wsl.exe @Command
    if ($LASTEXITCODE -ne 0) { throw "WSL integration test command failed (exit $LASTEXITCODE)" }
}
$existing = @(& wsl.exe --list --quiet) -replace "`0", ''
if (($existing | ForEach-Object { $_.Trim() }) -contains $testDistro) { throw 'Refusing to replace an existing Ubuntu distro' }
$created = $false
try {
    Invoke-TestWsl -Command @('--version')
    # Import avoids Store Ubuntu's interactive first-run account wizard in CI.
    # Official Canonical SHA256SUMS: ubuntu-base/releases/24.04/release/.
    $rootfs = Join-Path $env:RUNNER_TEMP 'ubuntu-base-24.04.5-base-amd64.tar.gz'
    Invoke-WebRequest -Uri 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz' -OutFile $rootfs
    if ((Get-FileHash -Algorithm SHA256 $rootfs).Hash.ToLowerInvariant() -ne 'e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86') {
        throw 'Official Ubuntu Base test fixture checksum mismatch'
    }
    $distroPath = Join-Path $env:RUNNER_TEMP 'pocket-ci-distro'
    Write-Host 'Importing verified Ubuntu Base 24.04.5 into an isolated WSL2 test distro.'
    Invoke-TestWsl -Command @('--import', $testDistro, $distroPath, $rootfs, '--version', '2')
    $created = $true
    Write-Host 'Booting test distro and provisioning its disposable CI user.'
    $bootstrap = (Resolve-Path (Join-Path $PSScriptRoot 'wsl_bootstrap.sh')).Path
    $linuxBootstrap = ((Invoke-TestWsl -Command @('-d', $testDistro, '-u', 'root', '--exec', 'wslpath', '-u', $bootstrap)) -join '').Trim()
    Invoke-TestWsl -Command @('-d', $testDistro, '-u', 'root', '--exec', 'env', 'POCKET_ISOLATED_TEST=1', 'bash', $linuxBootstrap)
    Invoke-TestWsl -Command @('--terminate', $testDistro)
    Invoke-TestWsl -Command @('-d', $testDistro, '-u', 'root', '--exec', 'loginctl', 'enable-linger', 'pockettest')
    $uid = ((Invoke-TestWsl -Command @('-d', $testDistro, '-u', 'root', '--exec', 'id', '-u', 'pockettest')) -join '').Trim()
    Invoke-TestWsl -Command @('-d', $testDistro, '-u', 'root', '--exec', 'systemctl', 'start', "user@$uid.service")
    $zip = @(Get-ChildItem -LiteralPath $ArtifactDirectory -Filter '*-windows-wsl2.zip')
    if ($zip.Count -ne 1) { throw 'Expected exactly one Windows installer ZIP' }
    $stage = Join-Path $env:RUNNER_TEMP 'pocket-wsl-setup'
    Expand-Archive -LiteralPath $zip[0].FullName -DestinationPath $stage
    $setup = Join-Path $stage 'Pocket-Connect/Pocket-Connect.ps1'
    # Only human confirmation is automated. Every WSL/install/service call is real.
    function global:Read-Host { return 'y' }
    . $setup -Action Install -Distro $testDistro -Port 18081
    Invoke-PocketMain
    if (-not (Test-Path $ShortcutPath)) { throw 'Login startup shortcut was not created' }
    $linuxHome = ((Invoke-Wsl -Command @('printenv', 'HOME')) -join '').Trim()
    $tokenPath = "$linuxHome/.config/pocket-connect/bridge-token"
    $before = ((Invoke-Wsl -Command @('sha256sum', $tokenPath)) -join '')
    & $setup -Action Install -Distro $testDistro -Port 18081 -NoAutostart
    if ($LASTEXITCODE -ne 0) { throw 'Windows reinstall failed' }
    $after = ((Invoke-Wsl -Command @('sha256sum', $tokenPath)) -join '')
    if ($before -ne $after) { throw 'Reinstall changed pairing identity' }
    if (Test-Path $ShortcutPath) { throw '-NoAutostart did not remove its shortcut' }
    $smoke = (Resolve-Path (Join-Path $PSScriptRoot 'smoke_linux.py')).Path
    $linuxSmoke = ((Invoke-Wsl -Command @('wslpath', '-u', $smoke)) -join '').Trim()
    Invoke-Wsl -Command @('env', 'POCKET_ISOLATED_TEST=1', "PATH=$linuxHome/.local/share/pocket-connect:/usr/local/bin:/usr/bin:/bin", 'python3', $linuxSmoke, '--systemd', '--already-installed')
    & $setup -Action Uninstall
    if ($LASTEXITCODE -ne 0) { throw 'Windows uninstall failed' }
    Invoke-Wsl -Command @('test', '-f', $tokenPath)
    Write-Host 'PASS: REAL WSL2 install, user systemd, auth, Console, headless pairing gate, login shortcut, reinstall identity, uninstall keeps data.'
    Write-Host 'NOT TESTED: interactive Windows login/reboot, SmartScreen, physical phone or provider sign-in/reply.'
} finally {
    if ($created) {
        & wsl.exe --unregister $testDistro
    }
}
