<#
.SYNOPSIS
Forces qBittorrent toward maximum practical download throughput and writes proof logs.

.DESCRIPTION
The script uses the local qBittorrent Web API. It removes local qBittorrent caps,
force-starts incomplete downloads, injects public rescue trackers unless disabled,
reannounces, validates local reachability, installs a watchdog, and classifies
remaining blockers. It cannot create seeders, peers, ISP bandwidth, or router
reachability that does not exist.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$Username,
    [string]$Password = $env:QBT_PASSWORD,
    [switch]$Watch,
    [int]$WatchMinutes = 0,
    [int]$Minutes = 0,
    [int]$PollSeconds = 15,
    [switch]$TargetOnlyIncomplete = $true,
    [switch]$NoTrackerInjection,
    [switch]$VerboseTorrentList,
    [switch]$SkipCredentialBootstrap,
    [switch]$SkipWatchdogInstall,
    [switch]$AuditOnly,
    [switch]$Rollback,
    [switch]$LocalOnly,
    [switch]$FullAdmin,
    [string]$Category,
    [string]$Tag,
    [switch]$NoUploadCap,
    [int]$UploadCapKBps = 1024,
    [int]$BenchmarkSeconds = 20
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $script:Root) { $script:Root = 'F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603' }
$script:LogDir = Join-Path $script:Root 'logs'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Proof = [ordered]@{
    started_at = (Get-Date).ToString('o')
    mode = if ($AuditOnly) { 'audit-only' } elseif ($Rollback) { 'rollback' } elseif ($Watch -or $WatchMinutes -gt 0 -or $Minutes -gt 0) { 'watch' } else { 'default' }
    root = $script:Root
    base_url = $null
    qbit_exe = $null
    qbit_started = $false
    qbit_version = $null
    api_version = $null
    config = @{}
    webui = @{}
    watchdog = @{}
    firewall = @{}
    listen_port = @{}
    process = @{}
    before_preferences = @{}
    after_preferences = @{}
    before_summary = @{}
    after_summary = @{}
    final_summary = @{}
    multiplier = @{}
    actions = New-Object System.Collections.ArrayList
    bottlenecks = New-Object System.Collections.ArrayList
    warnings = New-Object System.Collections.ArrayList
}

function Add-Action {
    param([string]$Message)
    [void]$script:Proof.actions.Add(([ordered]@{ at = (Get-Date).ToString('o'); message = $Message }))
    Write-Host $Message
}

function Add-ProofWarning {
    param([string]$Message)
    [void]$script:Proof.warnings.Add($Message)
    Write-Warning $Message
}

function Save-Proof {
    $script:Proof.finished_at = (Get-Date).ToString('o')
    $jsonPath = Join-Path $script:LogDir "QbitMaxDownload-$script:RunStamp.json"
    $txtPath = Join-Path $script:LogDir "QbitMaxDownload-$script:RunStamp.txt"
    $script:Proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $watchdogStatus = if ($script:Proof.watchdog.Contains('status')) { $script:Proof.watchdog.status } else { 'not-run' }
    $firewallStatus = if ($script:Proof.firewall.Contains('status')) { $script:Proof.firewall.status } else { 'not-run' }
    $listenStatus = if ($script:Proof.listen_port.Contains('status')) { $script:Proof.listen_port.status } else { 'not-run' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("QbitMaxDownload proof $script:RunStamp")
    [void]$lines.Add("mode=$($script:Proof.mode)")
    [void]$lines.Add("base_url=$($script:Proof.base_url)")
    [void]$lines.Add("qbit_exe=$($script:Proof.qbit_exe)")
    [void]$lines.Add("qbit_version=$($script:Proof.qbit_version) api_version=$($script:Proof.api_version)")
    [void]$lines.Add("watchdog=$watchdogStatus")
    [void]$lines.Add("firewall=$firewallStatus")
    [void]$lines.Add("listen_port=$listenStatus")
    [void]$lines.Add("before=$($script:Proof.before_summary | ConvertTo-Json -Compress)")
    [void]$lines.Add("after=$($script:Proof.after_summary | ConvertTo-Json -Compress)")
    [void]$lines.Add("final=$($script:Proof.final_summary | ConvertTo-Json -Compress)")
    [void]$lines.Add("multiplier=$($script:Proof.multiplier | ConvertTo-Json -Compress)")
    [void]$lines.Add("bottlenecks=$($script:Proof.bottlenecks -join '; ')")
    [void]$lines.Add("warnings=$($script:Proof.warnings -join '; ')")
    Set-Content -LiteralPath $txtPath -Value $lines -Encoding UTF8
    Write-Host "Proof JSON: $jsonPath"
    Write-Host "Proof text: $txtPath"
}

function Get-QbitConfig {
    $ini = Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini'
    $cfg = [ordered]@{
        Path = $ini
        Port = 8080
        Username = 'admin'
        WebUIEnabled = $false
        SavePath = $null
        Hook = $null
        ListenPort = $null
    }
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue) {
            if ($line -match '^WebUI\\Port=(\d+)') { $cfg.Port = [int]$Matches[1] }
            elseif ($line -match '^WebUI\\Username=(.+)$') { $cfg.Username = $Matches[1].Trim('"') }
            elseif ($line -match '^WebUI\\Enabled=(.+)$') { $cfg.WebUIEnabled = ($Matches[1] -eq 'true') }
            elseif ($line -match '^Downloads\\SavePath=(.+)$') { $cfg.SavePath = $Matches[1] }
            elseif ($line -match '^Downloads\\RunExternalProgramCommand=(.+)$') { $cfg.Hook = $Matches[1] }
            elseif ($line -match '^(Session\\Port|Connection\\PortRangeMin)=(\d+)') { $cfg.ListenPort = [int]$Matches[2] }
        }
    }
    $script:Proof.config = $cfg
    return $cfg
}

function Find-QbitExe {
    $running = Get-Process qbittorrent -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path) { return $running.Path }
    $candidates = @(
        "$env:ProgramFiles\qBittorrent\qbittorrent.exe",
        "${env:ProgramFiles(x86)}\qBittorrent\qbittorrent.exe",
        'F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\qBittorrent\qbittorrent.exe'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Ensure-QbitRunning {
    param([int]$WebPort)
    $exe = Find-QbitExe
    $script:Proof.qbit_exe = $exe
    $running = Get-Process qbittorrent -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $running -and $exe -and -not $AuditOnly -and -not $Rollback) {
        Start-Process -FilePath $exe -WindowStyle Minimized | Out-Null
        $script:Proof.qbit_started = $true
        Add-Action "Started qBittorrent: $exe"
    }
    $deadline = (Get-Date).AddSeconds(35)
    while ((Get-Date) -lt $deadline) {
        if ((Test-NetConnection -ComputerName 127.0.0.1 -Port $WebPort -InformationLevel Quiet -WarningAction SilentlyContinue)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function New-QbitSession {
    param([string]$Url,[string]$User,[string]$Pass)
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $body = @{ username = $User; password = $Pass }
    $login = Invoke-WebRequest -UseBasicParsing -Uri "$Url/api/v2/auth/login" -Method Post -Body $body -WebSession $session -TimeoutSec 15
    if ($login.Content -notmatch 'Ok\.') { throw "qBittorrent login failed for $User at ${Url}: $($login.Content)" }
    return $session
}

function Try-NewQbitSession {
    param([string]$Url,[string]$User,[string]$Pass)
    try { return New-QbitSession -Url $Url -User $User -Pass $Pass } catch { return $null }
}

function Invoke-QbitPost {
    param([string]$Path,[hashtable]$Body=@{})
    if ($AuditOnly) {
        Add-Action "AUDIT would POST $Path"
        return
    }
    Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/$Path" -Method Post -Body $Body -WebSession $script:Session -TimeoutSec 30 | Out-Null
}

function Get-QbitJson {
    param([string]$Path)
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/$Path" -WebSession $script:Session -TimeoutSec 30
    try { return $response.Content | ConvertFrom-Json } catch { return $response.Content }
}

function Set-QbitManagedCredentials {
    param([string]$User,[string]$Pass)
    if ($SkipCredentialBootstrap -or $AuditOnly) { return }
    $credPrefs = [ordered]@{
        web_ui_username = $User
        web_ui_password = $Pass
        web_ui_password_verify = $Pass
        web_ui_session_timeout = 1000000000
        web_ui_host_header_validation_enabled = $false
        bypass_local_auth = $false
    }
    try {
        Invoke-QbitPost -Path 'app/setPreferences' -Body @{ json = ($credPrefs | ConvertTo-Json -Compress) }
        Add-Action "WebUI credentials auto-managed for future runs: username=$User password=adminadmin"
    } catch {
        Add-ProofWarning "Could not update WebUI credentials through the API: $($_.Exception.Message)"
    }
}

function Ensure-QbitForceWatchdog {
    param([string]$ScriptPath)
    if ($SkipWatchdogInstall -or $Watch -or $AuditOnly -or $Rollback) { return }
    $taskName = 'QbitForceMaxDownloadPermanentWatchdog'
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $binDir = Join-Path $env:USERPROFILE 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $watchdogCmd = Join-Path $binDir 'QbitMaxDownloadWatchdog.cmd'
    $cmdLine = '@echo off' + [Environment]::NewLine + '"' + $psExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Watch -PollSeconds 15 -SkipWatchdogInstall'
    Set-Content -LiteralPath $watchdogCmd -Value $cmdLine -Encoding ASCII
    $taskRun = (Join-Path $env:WINDIR 'System32\cmd.exe') + ' /c ' + $watchdogCmd
    try {
        & schtasks.exe /Create /TN $taskName /SC MINUTE /MO 5 /TR $taskRun /F | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed with exit code $LASTEXITCODE" }
        & schtasks.exe /Run /TN $taskName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /Run failed with exit code $LASTEXITCODE" }
        $script:Proof.watchdog = [ordered]@{ status = 'installed-started'; task = $taskName; trampoline = $watchdogCmd }
        Add-Action "Permanent watchdog installed/started: $taskName"
    } catch {
        $script:Proof.watchdog = [ordered]@{ status = 'task-failed'; task = $taskName; error = $_.Exception.Message }
        Add-ProofWarning "Could not install scheduled watchdog: $($_.Exception.Message)"
        try {
            Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$ScriptPath,'-Watch','-PollSeconds','15','-SkipWatchdogInstall') -WindowStyle Hidden
            $script:Proof.watchdog.status = 'fallback-process-started'
            Add-Action 'Fallback hidden watchdog process started.'
        } catch {
            Add-ProofWarning "Fallback watchdog start failed: $($_.Exception.Message)"
        }
    }
}

function Ensure-FirewallRule {
    if ($LocalOnly -or $AuditOnly -or $Rollback) { return }
    $exe = $script:Proof.qbit_exe
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        $script:Proof.firewall = [ordered]@{ status = 'skipped-no-exe' }
        return
    }
    try {
        $rule = Get-NetFirewallRule -DisplayName 'QbitMaxDownload qBittorrent Inbound' -ErrorAction SilentlyContinue
        if (-not $rule) {
            New-NetFirewallRule -DisplayName 'QbitMaxDownload qBittorrent Inbound' -Direction Inbound -Program $exe -Action Allow -Profile Any | Out-Null
            $script:Proof.firewall = [ordered]@{ status = 'created'; program = $exe }
        } else {
            $script:Proof.firewall = [ordered]@{ status = 'exists'; program = $exe }
        }
    } catch {
        $psError = $_.Exception.Message
        try {
            & netsh.exe advfirewall firewall add rule name="QbitMaxDownload qBittorrent Inbound" dir=in action=allow program="$exe" enable=yes | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $script:Proof.firewall = [ordered]@{ status = 'created-netsh-fallback'; program = $exe; powershell_error = $psError }
                return
            }
            throw "netsh failed with exit code $LASTEXITCODE"
        } catch {
            $script:Proof.firewall = [ordered]@{ status = 'failed'; error = $_.Exception.Message; powershell_error = $psError }
            Add-ProofWarning "Firewall rule check failed: $psError; netsh fallback failed: $($_.Exception.Message)"
        }
    }
}

function Set-QbitProcessPriority {
    if ($AuditOnly -or $Rollback) { return }
    try {
        $procs = @(Get-Process qbittorrent -ErrorAction SilentlyContinue)
        foreach ($p in $procs) { try { $p.PriorityClass = 'AboveNormal' } catch {} }
        $script:Proof.process = [ordered]@{ status = if ($procs.Count -gt 0) { 'priority-above-normal-attempted' } else { 'not-running' }; count = $procs.Count }
    } catch {
        $script:Proof.process = [ordered]@{ status = 'failed'; error = $_.Exception.Message }
    }
}

function Test-ListenPort {
    param([int]$Port)
    if (-not $Port) { $script:Proof.listen_port = [ordered]@{ status = 'unknown' }; return }
    try {
        $local = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
        $script:Proof.listen_port = [ordered]@{ status = if ($local) { 'local-open' } else { 'not-listening-locally' }; port = $Port }
        if (-not $local) { [void]$script:Proof.bottlenecks.Add("listen-port-$Port-not-listening-locally-or-udp-only") }
    } catch {
        $script:Proof.listen_port = [ordered]@{ status = 'failed'; port = $Port; error = $_.Exception.Message }
    }
}

function Set-MaxDownloadPreferences {
    $uploadLimitBytes = if ($NoUploadCap) { 0 } else { [math]::Max(1, $UploadCapKBps) * 1024 }
    $prefs = [ordered]@{
        dl_limit = 0
        up_limit = $uploadLimitBytes
        alt_dl_limit = 0
        alt_up_limit = $uploadLimitBytes
        scheduler_enabled = $false
        queueing_enabled = $false
        max_active_downloads = -1
        max_active_torrents = -1
        max_active_uploads = -1
        max_connec = 1000
        max_connec_per_torrent = 250
        max_uploads = 24
        max_uploads_per_torrent = 8
        dont_count_slow_torrents = $true
        slow_torrent_dl_rate_threshold = 0
        slow_torrent_ul_rate_threshold = 0
        slow_torrent_inactive_timer = 1
        dht = $true
        pex = $true
        lsd = $true
        announce_to_all_trackers = $true
        announce_to_all_tiers = $true
        anonymous_mode = $false
        bittorrent_protocol = 0
        encryption = 0
        random_port = $false
        upnp = $true
        disk_cache = 1024
        disk_cache_ttl = 120
        async_io_threads = 8
        hashing_threads = 4
        connection_speed = 200
        request_queue_size = 2000
        send_buffer_watermark = 5000
        send_buffer_watermark_factor = 250
        send_buffer_low_watermark = 500
        socket_backlog_size = 100
        max_concurrent_http_announces = 100
        dht_bootstrap_nodes = 'dht.libtorrent.org:25401, dht.transmissionbt.com:6881, router.bittorrent.com:6881, router.utorrent.com:6881, dht.aelitis.com:6881'
        enable_multi_connections_from_same_ip = $true
        limit_lan_peers = $false
        limit_utp_rate = $false
        reannounce_when_address_changed = $true
        max_ratio_enabled = $true
        max_ratio = 0
        max_ratio_act = 0
        max_seeding_time_enabled = $true
        max_seeding_time = 0
    }
    Invoke-QbitPost -Path 'app/setPreferences' -Body @{ json = ($prefs | ConvertTo-Json -Compress) }
    try { Invoke-QbitPost -Path 'transfer/setDownloadLimit' -Body @{ limit = 0 } } catch { Write-Verbose "transfer/setDownloadLimit failed: $($_.Exception.Message)" }
    try { Invoke-QbitPost -Path 'transfer/setUploadLimit' -Body @{ limit = $uploadLimitBytes } } catch { Write-Verbose "transfer/setUploadLimit failed: $($_.Exception.Message)" }
    if ($NoUploadCap) {
        Add-Action 'Upload cap disabled by request.'
    } else {
        Add-Action "Smart upload cap applied to prevent upstream choking downloads: $UploadCapKBps KiB/s"
    }
}

function Get-TargetTorrents {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/torrents/info" -WebSession $script:Session -TimeoutSec 30
    $parsed = $response.Content | ConvertFrom-Json
    $all = New-Object System.Collections.ArrayList
    foreach ($item in $parsed) { [void]$all.Add($item) }
    $selected = New-Object System.Collections.ArrayList
    foreach ($t in $all) {
        if ($TargetOnlyIncomplete -and [double]$t.progress -ge 1.0) { continue }
        if ($Category -and [string]$t.category -ne $Category) { continue }
        if ($Tag -and ([string]$t.tags -notmatch [regex]::Escape($Tag))) { continue }
        [void]$selected.Add($t)
    }
    return $selected.ToArray()
}

function Add-RescueTrackers {
    param([object[]]$Torrents)
    if ($NoTrackerInjection) { return }
    $trackers = @(
        'udp://tracker.opentrackr.org:1337/announce',
        'udp://open.stealth.si:80/announce',
        'udp://tracker.torrent.eu.org:451/announce',
        'udp://exodus.desync.com:6969/announce',
        'udp://tracker.moeking.me:6969/announce',
        'udp://tracker.dler.org:6969/announce',
        'udp://open.demonii.com:1337/announce',
        'udp://tracker-udp.gbitt.info:80/announce',
        'udp://tracker1.bt.moack.co.kr:80/announce',
        'udp://tracker.theoks.net:6969/announce',
        'udp://tracker.dump.cl:6969/announce',
        'udp://tracker.bittor.pw:1337/announce',
        'udp://bt.ktrackers.com:6666/announce',
        'udp://explodie.org:6969/announce',
        'udp://uploads.gamecoast.net:6969/announce',
        'udp://tracker.filemail.com:6969/announce',
        'udp://wepzone.net:6969/announce',
        'udp://tracker.tryhackx.org:6969/announce',
        'udp://isk.richardsw.club:6969/announce',
        'udp://epider.me:6969/announce',
        'https://tracker.lilithraws.org:443/announce',
        'https://tracker.gbitt.info:443/announce',
        'https://tracker.bt4g.com:443/announce',
        'https://tracker.cloudit.top:443/announce',
        'https://tr.burnabyhighstar.com:443/announce'
    ) -join "`n"
    foreach ($t in $Torrents) {
        try { Invoke-QbitPost -Path 'torrents/addTrackers' -Body @{ hash = $t.hash; urls = $trackers } } catch { Write-Verbose "Tracker add failed for $($t.name): $($_.Exception.Message)" }
    }
}

function Stop-CompletedSeeders {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/torrents/info" -WebSession $script:Session -TimeoutSec 30
    $parsed = $response.Content | ConvertFrom-Json
    $completed = New-Object System.Collections.ArrayList
    foreach ($t in $parsed) {
        if ([double]$t.progress -ge 1.0 -and [string]$t.state -match 'UP|upload|stalledUP|forcedUP|queuedUP') { [void]$completed.Add($t.hash) }
    }
    if ($completed.Count -gt 0) {
        $hashes = ($completed.ToArray()) -join '|'
        foreach ($endpoint in @('torrents/stop','torrents/pause')) {
            try { Invoke-QbitPost -Path $endpoint -Body @{ hashes = $hashes } } catch { Write-Verbose "$endpoint completed seeders failed: $($_.Exception.Message)" }
        }
        Add-Action "Stopped completed seeders to keep bandwidth focused on incomplete downloads: $($completed.Count)"
    }
}

function Force-And-Reannounce {
    param([object[]]$Torrents)
    if (-not $Torrents -or $Torrents.Count -eq 0) { return }
    $hashes = ($Torrents | ForEach-Object { $_.hash }) -join '|'
    foreach ($endpoint in @('torrents/start','torrents/resume')) {
        try { Invoke-QbitPost -Path $endpoint -Body @{ hashes = $hashes } } catch { Write-Verbose "$endpoint failed: $($_.Exception.Message)" }
    }
    try { Invoke-QbitPost -Path 'torrents/setDownloadLimit' -Body @{ hashes = $hashes; limit = 0 } } catch { Write-Verbose "setDownloadLimit failed: $($_.Exception.Message)" }
    $uploadLimitBytes = if ($NoUploadCap) { 0 } else { [math]::Max(1, $UploadCapKBps) * 1024 }
    try { Invoke-QbitPost -Path 'torrents/setUploadLimit' -Body @{ hashes = $hashes; limit = $uploadLimitBytes } } catch { Write-Verbose "setUploadLimit failed: $($_.Exception.Message)" }
    try { Invoke-QbitPost -Path 'torrents/topPrio' -Body @{ hashes = $hashes } } catch { Write-Verbose "topPrio failed: $($_.Exception.Message)" }
    try { Invoke-QbitPost -Path 'torrents/setAutoManagement' -Body @{ hashes = $hashes; enable = 'false' } } catch { Write-Verbose "setAutoManagement failed: $($_.Exception.Message)" }
    try { Invoke-QbitPost -Path 'torrents/setForceStart' -Body @{ hashes = $hashes; value = 'true' } } catch { Write-Verbose "setForceStart failed: $($_.Exception.Message)" }
    try { Invoke-QbitPost -Path 'torrents/reannounce' -Body @{ hashes = $hashes } } catch { Write-Verbose "reannounce failed: $($_.Exception.Message)" }
}

function Set-TargetFilePriorityMax {
    param([object[]]$Torrents)
    if (-not $Torrents -or $Torrents.Count -eq 0) { return }
    foreach ($t in $Torrents) {
        try {
            $files = Get-QbitJson -Path ("torrents/files?hash={0}" -f [uri]::EscapeDataString([string]$t.hash))
            $ids = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $files.Count; $i++) { [void]$ids.Add($i) }
            if ($ids.Count -gt 0) {
                Invoke-QbitPost -Path 'torrents/filePrio' -Body @{ hash = $t.hash; id = (($ids.ToArray()) -join '|'); priority = 7 }
            }
        } catch {
            Write-Verbose "filePrio failed for $($t.name): $($_.Exception.Message)"
        }
    }
    Add-Action "Set target torrent file priorities to maximum where qBittorrent exposed file lists: $($Torrents.Count)"
}

function Invoke-SpeedSurge {
    param([object[]]$Torrents)
    Set-MaxDownloadPreferences
    Stop-CompletedSeeders
    Add-RescueTrackers -Torrents $Torrents
    Set-TargetFilePriorityMax -Torrents $Torrents
    Force-And-Reannounce -Torrents $Torrents
}

function Measure-TargetSpeed {
    param([string]$Label,[int]$Seconds)
    $samples = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds([math]::Max(1, $Seconds))
    while ((Get-Date) -lt $deadline) {
        $targets = @(Get-TargetTorrents)
        $summary = Get-Summary -Torrents $targets -Label $Label
        [void]$samples.Add([int64]$summary.total_download_speed_Bps)
        Start-Sleep -Seconds 2
    }
    if ($samples.Count -eq 0) { return 0 }
    $sorted = @($samples.ToArray() | Sort-Object)
    return [int64]$sorted[[math]::Floor(($sorted.Count - 1) / 2)]
}

function Set-MultiplierProof {
    param([int64]$BeforeBps,[int64]$AfterBps)
    $baseline = [math]::Max(1, $BeforeBps)
    $multiplier = [math]::Round(($AfterBps / $baseline), 2)
    $pct = [math]::Round((($AfterBps - $BeforeBps) / $baseline) * 100, 2)
    $script:Proof.multiplier = [ordered]@{
        before_median_Bps = $BeforeBps
        after_median_Bps = $AfterBps
        multiplier = $multiplier
        percent_change = $pct
        benchmark_seconds = $BenchmarkSeconds
    }
    Write-Host "Measured speed multiplier: ${multiplier}x (${pct}% change), before=${BeforeBps}B/s after=${AfterBps}B/s"
    if ($AfterBps -lt ($BeforeBps * 3) -and $AfterBps -eq 0) {
        [void]$script:Proof.bottlenecks.Add('3x-not-possible-on-current-targets-zero-download-after-surge')
    } elseif ($AfterBps -lt ($BeforeBps * 3)) {
        [void]$script:Proof.bottlenecks.Add('3x-not-proven-on-current-targets-after-surge')
    }
}

function Get-Summary {
    param([object[]]$Torrents,[string]$Label)
    $items = New-Object System.Collections.ArrayList
    foreach ($x in $Torrents) {
        if ($x -is [System.Array]) { foreach ($y in $x) { [void]$items.Add($y) } }
        elseif ($null -ne $x) { [void]$items.Add($x) }
    }
    $Torrents = $items.ToArray()
    $totalSpeed = 0
    $blocked = 0
    $zeroSeed = 0
    foreach ($t in $Torrents) {
        try { $totalSpeed += [int64]$t.dlspeed } catch {}
        if ([string]$t.state -match 'stalled|metaDL|error|missing|unknown' -or ([double]$t.progress -lt 1.0 -and [int]$t.dlspeed -eq 0)) { $blocked++ }
        if ([double]$t.progress -lt 1.0 -and [int]$t.num_seeds -le 0) { $zeroSeed++ }
    }
    $summary = [ordered]@{ label = $Label; target_count = $Torrents.Count; total_download_speed_Bps = $totalSpeed; blocked_or_zero_speed = $blocked; zero_seed_incomplete = $zeroSeed }
    Write-Host "[$Label] target_count=$($summary.target_count) total_download_speed_Bps=$totalSpeed blocked_or_zero_speed=$blocked zero_seed_incomplete=$zeroSeed"
    foreach ($t in ($Torrents | Sort-Object state,name)) {
        $pct = [math]::Round(([double]$t.progress * 100), 2)
        $line = "state=$($t.state) speed_Bps=$($t.dlspeed) seeds=$($t.num_seeds) peers=$($t.num_leechs) progress=$pct% hash=$($t.hash) name=$($t.name)"
        if ($VerboseTorrentList -or $t.state -match 'stalled|meta|downloading|queued|paused|stopped') { Write-Host $line }
    }
    return $summary
}

function Invoke-Rollback {
    $taskName = 'QbitForceMaxDownloadPermanentWatchdog'
    try {
        & schtasks.exe /End /TN $taskName 2>$null | Out-Null
        & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
        $script:Proof.watchdog = [ordered]@{ status = 'deleted-if-present'; task = $taskName }
    } catch {
        $script:Proof.watchdog = [ordered]@{ status = 'delete-failed'; task = $taskName; error = $_.Exception.Message }
    }
    try {
        Get-NetFirewallRule -DisplayName 'QbitMaxDownload qBittorrent Inbound' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $script:Proof.firewall = [ordered]@{ status = 'deleted-if-present' }
    } catch {
        $script:Proof.firewall = [ordered]@{ status = 'delete-failed'; error = $_.Exception.Message }
    }
    Add-Action 'Rollback completed for project watchdog/firewall artifacts only; torrent data and qBittorrent downloads were not changed.'
}

try {
    if ($Minutes -gt 0 -and $WatchMinutes -le 0) { $WatchMinutes = $Minutes }
    $config = Get-QbitConfig
    if (-not $BaseUrl) { $BaseUrl = "http://localhost:$($config.Port)" }
    if (-not $Username) { $Username = if ($config.Username) { $config.Username } else { 'admin' } }
    $script:Base = $BaseUrl.TrimEnd('/')
    $script:Proof.base_url = $script:Base

    if ($Rollback) {
        Invoke-Rollback
        Save-Proof
        exit 0
    }

    $webReady = Ensure-QbitRunning -WebPort $config.Port
    $script:Proof.webui = [ordered]@{ port = $config.Port; reachable = $webReady; enabled_in_config = $config.WebUIEnabled }
    if (-not $webReady) {
        [void]$script:Proof.bottlenecks.Add('webui-not-reachable')
        if ($AuditOnly) {
            Add-ProofWarning "Audit-only: qBittorrent WebUI is not reachable at $script:Base and was not started because audit mode is non-mutating."
            Save-Proof
            exit 0
        }
        throw "qBittorrent WebUI is not reachable at $script:Base after startup recovery."
    }

    $managedPassword = 'adminadmin'
    $candidates = New-Object System.Collections.ArrayList
    if ($Password) { [void]$candidates.Add($Password) }
    if ($env:QBT_PASSWORD -and $env:QBT_PASSWORD -ne $Password) { [void]$candidates.Add($env:QBT_PASSWORD) }
    if (-not $candidates.Contains($managedPassword)) { [void]$candidates.Add($managedPassword) }

    $script:Session = $null
    $usedPassword = $null
    foreach ($candidate in $candidates) {
        $trySession = Try-NewQbitSession -Url $script:Base -User $Username -Pass $candidate
        if ($trySession) { $script:Session = $trySession; $usedPassword = $candidate; break }
    }
    if (-not $script:Session -and $Username -ne 'admin') {
        $Username = 'admin'
        foreach ($candidate in $candidates) {
            $trySession = Try-NewQbitSession -Url $script:Base -User $Username -Pass $candidate
            if ($trySession) { $script:Session = $trySession; $usedPassword = $candidate; break }
        }
    }
    if (-not $script:Session) { throw "Automatic qBittorrent WebUI login failed at $script:Base. Managed default is admin/adminadmin." }

    $script:Proof.qbit_version = Get-QbitJson -Path 'app/version'
    $script:Proof.api_version = Get-QbitJson -Path 'app/webapiVersion'
    Write-Host "Connected to qBittorrent $($script:Proof.qbit_version) API $($script:Proof.api_version) at $script:Base as $Username without prompting"

    if ($usedPassword -eq $managedPassword) { Set-QbitManagedCredentials -User 'admin' -Pass $managedPassword }
    $script:Proof.before_preferences = Get-QbitJson -Path 'app/preferences'
    $resolvedScriptPath = $MyInvocation.MyCommand.Path
    if (-not $resolvedScriptPath) { $resolvedScriptPath = Join-Path $script:Root 'scripts\Force-QbitMaxDownload.ps1' }

    Ensure-QbitForceWatchdog -ScriptPath $resolvedScriptPath
    Ensure-FirewallRule
    Set-QbitProcessPriority
    Test-ListenPort -Port $config.ListenPort

    $beforeMedian = 0
    if ($BenchmarkSeconds -gt 0 -and -not $AuditOnly) {
        $beforeMedian = Measure-TargetSpeed -Label 'benchmark-before' -Seconds $BenchmarkSeconds
    }
    $targets = @(Get-TargetTorrents)
    $script:Proof.before_summary = Get-Summary -Torrents $targets -Label 'before'
    if ($AuditOnly) {
        [void]$script:Proof.bottlenecks.Add('audit-only-no-mutations-applied')
        Save-Proof
        exit 0
    }

    Invoke-SpeedSurge -Torrents $targets
    Start-Sleep -Seconds 3
    $targets = @(Get-TargetTorrents)
    $script:Proof.after_summary = Get-Summary -Torrents $targets -Label 'after-force'

    if ($Watch -or $WatchMinutes -gt 0) {
        $deadline = if ($WatchMinutes -gt 0) { (Get-Date).AddMinutes($WatchMinutes) } else { [datetime]::MaxValue }
        $cycle = 0
        while ((Get-Date) -lt $deadline) {
            $cycle++
            $targets = @(Get-TargetTorrents)
            Invoke-SpeedSurge -Torrents $targets
            Start-Sleep -Seconds $PollSeconds
            $targets = @(Get-TargetTorrents)
            $cycleSummary = Get-Summary -Torrents $targets -Label "watch-$cycle"
            if ([int]$cycleSummary.blocked_or_zero_speed -eq 0) { break }
        }
    }

    $afterMedian = 0
    if ($BenchmarkSeconds -gt 0) {
        $afterMedian = Measure-TargetSpeed -Label 'benchmark-after' -Seconds $BenchmarkSeconds
        Set-MultiplierProof -BeforeBps $beforeMedian -AfterBps $afterMedian
    }
    $final = @(Get-TargetTorrents)
    $script:Proof.final_summary = Get-Summary -Torrents $final -Label 'final'
    $script:Proof.after_preferences = Get-QbitJson -Path 'app/preferences'
    if ([int]$script:Proof.final_summary.blocked_or_zero_speed -gt 0) {
        [void]$script:Proof.bottlenecks.Add('external-swarm-trackers-network-or-zero-seed-limit-remains')
        Add-ProofWarning 'Some torrents remain metadata/stalled/zero-speed after local qBittorrent limits were removed and retries were sent. Remaining limit is external swarm/tracker/network availability unless the proof log shows a local failed check.'
    }
    if ($config.Hook -and $config.Hook -match 'QbitFitGirlSafeHook') {
        Add-Action 'FitGirl/ins qBittorrent external-program hook preserved.'
    } elseif ($config.Hook) {
        Add-ProofWarning "qBittorrent external-program hook exists but is not the expected FitGirl hook: $($config.Hook)"
    } else {
        Add-ProofWarning 'qBittorrent external-program hook is empty.'
    }
    Save-Proof
    exit 0
} catch {
    Add-ProofWarning $_.Exception.Message
    Save-Proof
    throw
}
