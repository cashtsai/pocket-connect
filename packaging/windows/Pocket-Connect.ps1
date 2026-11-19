# Windows entry point. Bridge and provider sessions run inside the chosen WSL2 distro.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Start', 'Status', 'Pair', 'Uninstall')]
    [string]$Action = 'Install',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$NoAutostart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$InstallRoot = Join-Path $env:LOCALAPPDATA 'PocketConnect'
$StateFile = Join-Path $InstallRoot 'windows.json'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Pocket Connect.lnk'

function Invoke-Wsl {
    param([string[]]$Command)
    & wsl.exe --distribution $script:Distro --exec @Command
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed (exit $LASTEXITCODE). No distro or Windows network settings were changed." }
}

function Assert-Distro {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL2 is required. In Administrator PowerShell: wsl --install -d Ubuntu-24.04 . Restart if requested, create a normal Linux user, then rerun Install.cmd.'
    }
    $names = @(& wsl.exe --list --quiet) -replace "`0", ''
    if ($LASTEXITCODE -ne 0 -or -not ($names.Trim() -contains $Distro)) {
        throw "Install and initialize $Distro first: wsl --install -d $Distro . Create a normal Linux user, then rerun. Existing distros are never replaced."
    }
    $kernel = (Invoke-Wsl -Command @('uname', '-r')) -join ''
    if ($kernel -notmatch '(?i)wsl2') { throw "This distro must use WSL2. Review: wsl --set-version $Distro 2" }
    $uid = ((Invoke-Wsl -Command @('id', '-u')) -join '').Trim()
    if ($uid -eq '0') { throw 'Choose a normal default Linux user before installing; do not run Pocket as root.' }
    Invoke-Wsl -Command @('systemctl', '--user', 'show-environment') | Out-Null
}

function Invoke-PocketMain {
    if ($Action -ne 'Install') {
        if (-not (Test-Path $StateFile)) { throw 'Pocket Connect is not installed for this Windows user.' }
        $state = Get-Content -Raw $StateFile | ConvertFrom-Json
        if ($state.distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Invalid saved distro' }
        $script:Distro = $state.distro
    }
    Assert-Distro
    $linuxHome = ((Invoke-Wsl -Command @('printenv', 'HOME')) -join '').Trim()
    if (-not $linuxHome.StartsWith('/') -or $linuxHome.Contains("`n")) { throw 'Invalid Linux home directory' }
    $linuxLauncher = "$linuxHome/.local/share/pocket-connect/pocket-connect"
    switch ($Action) {
        'Install' {
            $package = Join-Path $PSScriptRoot 'Pocket-Connect-linux.tar.gz'
            $manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'windows-manifest.json') | ConvertFrom-Json
            foreach ($entry in $manifest.files.PSObject.Properties) {
                if ($entry.Name -notmatch '^[A-Za-z0-9._-]+$') { throw 'Unsafe manifest path' }
                $hash = (Get-FileHash -Algorithm SHA256 (Join-Path $PSScriptRoot $entry.Name)).Hash.ToLowerInvariant()
                if ($hash -ne $entry.Value) { throw "Package checksum mismatch: $($entry.Name)" }
            }
            if (-not ($manifest.files.PSObject.Properties.Name -contains 'Pocket-Connect-linux.tar.gz')) {
                throw 'Manifest does not cover the Linux payload'
            }
            Write-Host 'Pocket will install dependencies inside your selected Ubuntu distro, then a per-user bridge.'
            Write-Host 'Provider accounts must be installed and signed in INSIDE this WSL distro; Windows app sessions are not automatically shared.'
            Write-Host 'No firewall, port forwarding, WSL settings, or provider credentials will be changed.'
            if ((Read-Host 'Continue? [y/N]') -notmatch '^(?i)y(es)?$') { throw 'Cancelled before installation' }
            $linuxPackage = ((Invoke-Wsl -Command @('wslpath', '-a', '-u', $package)) -join '').Trim()
            $temporary = ((Invoke-Wsl -Command @('mktemp', '-d', '/tmp/pocket-connect.XXXXXXXX')) -join '').Trim()
            if ($temporary -notmatch '^/tmp/pocket-connect\.[A-Za-z0-9]+$') { throw 'Unexpected WSL staging path' }
            try {
                Invoke-Wsl -Command @('tar', '-xzf', $linuxPackage, '-C', $temporary)
                Invoke-Wsl -Command @('sudo', 'apt-get', 'update')
                Invoke-Wsl -Command @('sudo', 'apt-get', 'install', '-y', 'python3', 'python3-venv', 'ca-certificates', 'tmux', 'curl')
                Invoke-Wsl -Command @('python3', "$temporary/pocket-connect/pocket-connect", 'install', '--package-dir', "$temporary/pocket-connect")
            } finally {
                Invoke-Wsl -Command @('rm', '-rf', '--', $temporary)
            }
            New-Item -ItemType Directory -Force $InstallRoot | Out-Null
            Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $InstallRoot 'Pocket-Connect.ps1') -Force
            @{ distro = $Distro; version = $manifest.version } | ConvertTo-Json | Set-Content -Encoding UTF8 $StateFile
            if (-not $NoAutostart) {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($ShortcutPath)
                $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + (Join-Path $InstallRoot 'Pocket-Connect.ps1') + '" -Action Start'
                $shortcut.WorkingDirectory = $InstallRoot
                $shortcut.Description = 'Pocket Connect WSL keepalive (current user)'
                $shortcut.Save()
            }
            Write-Host 'Installed. Login autostart is enabled unless -NoAutostart was selected. Not a pre-login Windows service.'
            Write-Host 'Phone access still requires a route into WSL (recommended: Tailscale inside WSL + Serve). See README. Do not scan an unreachable NAT address.'
            Write-Host "Run: powershell -File `"$InstallRoot\Pocket-Connect.ps1`" -Action Pair"
            Write-Host "Run: powershell -File `"$InstallRoot\Pocket-Connect.ps1`" -Action Start (keeps WSL alive)"
        }
        'Start' { Invoke-Wsl -Command @('python3', $linuxLauncher, 'keepalive') }
        'Status' { Invoke-Wsl -Command @('python3', $linuxLauncher, 'status') }
        'Pair' {
            $url = ((Invoke-Wsl -Command @('python3', $linuxLauncher, 'pair', '--url')) -join '').Trim()
            if ($url -notmatch '^http://127\.0\.0\.1:[0-9]+/pair/qr\?boot=[A-Za-z0-9_%~-]+$') { throw 'Unexpected pairing URL; not opening it' }
            Start-Process $url
        }
        'Uninstall' {
            if ((Read-Host 'Remove Pocket service and Windows autostart? Data and WSL distro stay. [y/N]') -notmatch '^(?i)y(es)?$') { throw 'Cancelled' }
            Invoke-Wsl -Command @('python3', $linuxLauncher, 'uninstall', '--yes')
            if (Test-Path $ShortcutPath) { Remove-Item -LiteralPath $ShortcutPath }
            Write-Host 'Service/autostart removed. Linux data, provider logins, and distro retained.'
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-PocketMain } catch {
        Write-Error $_
        exit 1
    }
}
