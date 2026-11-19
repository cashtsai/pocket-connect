$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../windows/Pocket-Connect.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw ($errors | Out-String) }
. $path -Action Install

# Execute the actual Windows preflight against controlled native-command results.
$script:Mode = 'valid'
function wsl.exe {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq '--list') { return 'Ubuntu-24.04' }
    $command = $args[3]
    if ($command -eq 'uname') {
        if ($script:Mode -eq 'wsl1') { return '4.4.0-microsoft' }
        return '6.6.87.2-microsoft-standard-WSL2'
    }
    if ($command -eq 'id') {
        if ($script:Mode -eq 'root') { return '0' }
        return '1000'
    }
    if ($command -eq 'systemctl') {
        if ($script:Mode -eq 'no-systemd') { $global:LASTEXITCODE = 1 }
        return
    }
    throw "Unexpected command in test: $args"
}
Assert-Distro
foreach ($mode in @('wsl1', 'root', 'no-systemd')) {
    $script:Mode = $mode
    $failed = $false
    try { Assert-Distro } catch { $failed = $true }
    if (-not $failed) { throw "Preflight accepted invalid state: $mode" }
}
Write-Host 'PASS: PowerShell parse, WSL2 preflight, WSL1/root/no-systemd rejection. No actual WSL installation performed.'
