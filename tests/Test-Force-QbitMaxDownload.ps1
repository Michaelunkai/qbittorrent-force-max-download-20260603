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
$required = @('app/setPreferences','app/preferences','app/version','app/webapiVersion','transfer/setDownloadLimit','transfer/setUploadLimit','torrents/setForceStart','torrents/reannounce','torrents/addTrackers','torrents/setDownloadLimit','torrents/setUploadLimit','torrents/topPrio','torrents/setAutoManagement','torrents/filePrio','torrents/stop','Stop-CompletedSeeders','queueing_enabled','dl_limit','dht','pex','lsd','dht_bootstrap_nodes','enable_multi_connections_from_same_ip','limit_lan_peers','limit_utp_rate','web_ui_username','web_ui_password','Try-NewQbitSession','adminadmin','Ensure-QbitForceWatchdog','QbitForceMaxDownloadPermanentWatchdog','schtasks.exe','AuditOnly','Rollback','LocalOnly','FullAdmin','Category','Tag','NoUploadCap','UploadCapKBps','BenchmarkSeconds','Invoke-SpeedSurge','Set-TargetFilePriorityMax','Measure-TargetSpeed','Set-MultiplierProof','Ensure-QbitRunning','Ensure-FirewallRule','Set-QbitProcessPriority','Test-ListenPort','QbitFitGirlSafeHook','Proof JSON','QbitMaxDownload-')
foreach ($needle in $required) {
    if (-not $content.Contains($needle)) { throw "Missing required token: $needle" }
}
if ($content -like '*Read-Host*') { throw 'Script must not prompt interactively with Read-Host' }
$dangerous = @('Remove-Item','Format-Volume','Clear-Disk','Reset-NetAdapter','Restart-Computer')
foreach ($needle in $dangerous) {
    if ($content.Contains($needle)) { throw "Forbidden destructive token present: $needle" }
}
$root = Split-Path -Parent (Split-Path -Parent $ScriptPath)
$launcher = Join-Path $root 'src\QbitMaxDownloadLauncher.cs'
if (-not (Test-Path -LiteralPath $launcher)) { throw "Missing launcher source: $launcher" }
$launcherContent = Get-Content -LiteralPath $launcher -Raw
foreach ($needle in @('--audit-only','--rollback','--local-only','--full-admin','--no-trackers','--minutes','--poll-seconds','--upload-cap-kbps','--benchmark-seconds','--no-upload-cap','Force-QbitMaxDownload.ps1')) {
    if (-not $launcherContent.Contains($needle)) { throw "Launcher missing required token: $needle" }
}
$tray = Join-Path $root 'src\QbitMaxDownloadTray.cs'
if (-not (Test-Path -LiteralPath $tray)) { throw "Missing tray source: $tray" }
$trayContent = Get-Content -LiteralPath $tray -Raw
foreach ($needle in @('NotifyIcon','ContextMenuStrip','Application.Run','CreateNoWindow = true','ProcessWindowStyle.Hidden','RedirectStandardOutput = true','RedirectStandardError = true','Force-QbitMaxDownload.ps1','-Watch','-SkipWatchdogInstall','QbitForceMaxDownloadPermanentWatchdog','schtasks.exe','/Delete /F','--stop-running','--upload-cap-kbps','--benchmark-seconds','--no-upload-cap','KillPowerShellWorkers','StopAllOptimizerActivity')) {
    if (-not $trayContent.Contains($needle)) { throw "Tray source missing required token: $needle" }
}
if ($trayContent -match 'C:\\Users\\micha|Documents\\Codex|micha\\bin') {
    throw 'Tray source must not depend on the Codex workspace or user bin path'
}
Write-Host "PASS parser/token/no-prompt/no-danger/tray-lifecycle checks for $ScriptPath"
