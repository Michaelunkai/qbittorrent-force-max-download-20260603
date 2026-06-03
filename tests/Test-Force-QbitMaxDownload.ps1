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
$required = @('app/setPreferences','torrents/setForceStart','torrents/reannounce','torrents/addTrackers','torrents/setDownloadLimit','torrents/setUploadLimit','torrents/topPrio','torrents/setAutoManagement','queueing_enabled','dl_limit','dht','pex','lsd','web_ui_username','web_ui_password','Try-NewQbitSession','adminadmin','Ensure-QbitForceWatchdog','QbitForceMaxDownloadPermanentWatchdog','schtasks.exe')
foreach ($needle in $required) {
    if (-not $content.Contains($needle)) { throw "Missing required token: $needle" }
}
if ($content -like '*Read-Host*') { throw 'Script must not prompt interactively with Read-Host' }
Write-Host "PASS parser/token/no-prompt checks for $ScriptPath"
