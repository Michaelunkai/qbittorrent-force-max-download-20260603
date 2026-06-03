[CmdletBinding()]
param(
    [string]$ScriptPath
)
$ErrorActionPreference = 'Stop'
if (-not $ScriptPath) {
    $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    $ScriptPath = Join-Path $root 'scripts\Force-QbitMaxDownload.ps1'
}
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Missing script: $ScriptPath" }
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) { $errors | Format-List | Out-String | Write-Host; throw "PowerShell parser errors found" }
$content = Get-Content -LiteralPath $ScriptPath -Raw
$required = @('app/setPreferences','torrents/setForceStart','torrents/reannounce','torrents/addTrackers','queueing_enabled','dl_limit','dht','pex','lsd','Read-Host')
foreach ($needle in $required) {
    if ($content -notlike "*$needle*") { throw "Missing required token: $needle" }
}
Write-Host "PASS parser/token checks for $ScriptPath"
