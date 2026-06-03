<#
.SYNOPSIS
Forces active qBittorrent downloads toward maximum speed by removing qBittorrent-side limits, force-starting stalled/metadata/downloading torrents, adding public trackers, reannouncing, and optionally watching/retrying until they are no longer stalled.

.DESCRIPTION
This script uses qBittorrent Web API. It cannot create seeders or bandwidth that does not exist on the swarm/network, but it removes local qBittorrent throttles/queue bottlenecks and keeps poking stalled or metadata torrents so the client can use the maximum available hardware/network capacity.

Do not hard-code your qBittorrent password in this file. Pass -Password, set QBT_PASSWORD, or let the script prompt.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$Username,
    [string]$Password = $env:QBT_PASSWORD,
    [switch]$Watch,
    [int]$WatchMinutes = 0,
    [int]$PollSeconds = 20,
    [switch]$TargetOnlyIncomplete = $true,
    [switch]$NoTrackerInjection,
    [switch]$VerboseTorrentList
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-QbitConfig {
    $ini = Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini'
    $cfg = [ordered]@{ Path = $ini; Port = 8080; Username = 'admin' }
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue) {
            if ($line -match '^WebUI\\Port=(\d+)') { $cfg.Port = [int]$Matches[1] }
            elseif ($line -match '^WebUI\\Username=(.+)$') { $cfg.Username = $Matches[1].Trim('"') }
            elseif ($line -match '^WebUI\\Enabled=(.+)$' -and $Matches[1] -ne 'true') { Write-Warning "qBittorrent WebUI appears disabled in $ini" }
        }
    }
    return $cfg
}

function New-QbitSession {
    param([string]$Url,[string]$User,[string]$Pass)
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $body = @{ username = $User; password = $Pass }
    $login = Invoke-WebRequest -UseBasicParsing -Uri "$Url/api/v2/auth/login" -Method Post -Body $body -WebSession $session -TimeoutSec 15
    if ($login.Content -notmatch 'Ok\.') { throw "qBittorrent login failed for $User at ${Url}: $($login.Content)" }
    return $session
}

function Invoke-QbitPost {
    param([string]$Path,[hashtable]$Body=@{})
    Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/$Path" -Method Post -Body $Body -WebSession $script:Session -TimeoutSec 30 | Out-Null
}

function Get-QbitJson {
    param([string]$Path)
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/$Path" -WebSession $script:Session -TimeoutSec 30
    try { return $response.Content | ConvertFrom-Json } catch { return $response.Content }
}

function Set-MaxDownloadPreferences {
    $prefs = [ordered]@{
        dl_limit = 0
        up_limit = 0
        alt_dl_limit = 0
        alt_up_limit = 0
        scheduler_enabled = $false
        queueing_enabled = $false
        max_active_downloads = -1
        max_active_torrents = -1
        max_active_uploads = -1
        max_connec = 1000
        max_connec_per_torrent = 250
        max_uploads = -1
        max_uploads_per_torrent = -1
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
    }
    $json = $prefs | ConvertTo-Json -Compress
    Invoke-QbitPost -Path 'app/setPreferences' -Body @{ json = $json }
}

function Get-TargetTorrents {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$script:Base/api/v2/torrents/info" -WebSession $script:Session -TimeoutSec 30
    $parsed = $response.Content | ConvertFrom-Json
    $all = New-Object System.Collections.ArrayList
    foreach ($item in $parsed) { [void]$all.Add($item) }
    if ($TargetOnlyIncomplete) {
        $selected = New-Object System.Collections.ArrayList
        foreach ($t in $all) {
            if ([double]$t.progress -lt 1.0 -or [string]$t.state -match 'DL|meta|stalled|downloading|queued|paused|stopped') { [void]$selected.Add($t) }
        }
        return $selected.ToArray()
    }
    return $all.ToArray()
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
        'https://tracker.lilithraws.org:443/announce',
        'https://tracker.gbitt.info:443/announce'
    ) -join "`n"
    foreach ($t in $Torrents) {
        try { Invoke-QbitPost -Path 'torrents/addTrackers' -Body @{ hash = $t.hash; urls = $trackers } } catch { Write-Verbose "Tracker add failed for $($t.name): $($_.Exception.Message)" }
    }
}

function Force-And-Reannounce {
    param([object[]]$Torrents)
    if (-not $Torrents -or $Torrents.Count -eq 0) { return }
    $hashes = ($Torrents | ForEach-Object { $_.hash }) -join '|'
    foreach ($endpoint in @('torrents/start','torrents/resume')) {
        try { Invoke-QbitPost -Path $endpoint -Body @{ hashes = $hashes } } catch { Write-Verbose "$endpoint failed: $($_.Exception.Message)" }
    }
    try { Invoke-QbitPost -Path 'torrents/setForceStart' -Body @{ hashes = $hashes; value = 'true' } } catch { Write-Verbose "setForceStart failed: $($_.Exception.Message)" }
    try { Invoke-QbitPost -Path 'torrents/reannounce' -Body @{ hashes = $hashes } } catch { Write-Verbose "reannounce failed: $($_.Exception.Message)" }
}

function Show-Summary {
    param([object[]]$Torrents,[string]$Label)
    $items = New-Object System.Collections.ArrayList
    foreach ($x in $Torrents) {
        if ($x -is [System.Array]) { foreach ($y in $x) { [void]$items.Add($y) } }
        elseif ($null -ne $x) { [void]$items.Add($x) }
    }
    $Torrents = $items.ToArray()
    $totalSpeed = 0
    foreach ($t in $Torrents) { try { $totalSpeed += [int64]$t.dlspeed } catch {} }
    $blocked = @($Torrents | Where-Object { $_.state -match 'stalled|metaDL|error|missing|unknown' -or ([double]$_.progress -lt 1.0 -and [int]$_.dlspeed -eq 0) })
    Write-Host "[$Label] target_count=$($Torrents.Count) total_download_speed_Bps=$totalSpeed blocked_or_zero_speed=$($blocked.Count)"
    foreach ($t in ($Torrents | Sort-Object state,name)) {
        $pct = [math]::Round(([double]$t.progress * 100), 2)
        $line = "state=$($t.state) speed_Bps=$($t.dlspeed) seeds=$($t.num_seeds) peers=$($t.num_leechs) progress=$pct% hash=$($t.hash) name=$($t.name)"
        if ($VerboseTorrentList -or $t.state -match 'stalled|meta|downloading|queued|paused|stopped') { Write-Host $line }
    }
    return $blocked.Count
}

$config = Get-QbitConfig
if (-not $BaseUrl) { $BaseUrl = "http://localhost:$($config.Port)" }
if (-not $Username) { $Username = $config.Username }
if (-not $Password) {
    $secure = Read-Host -Prompt "qBittorrent WebUI password for $Username at $BaseUrl" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$script:Base = $BaseUrl.TrimEnd('/')
$script:Session = New-QbitSession -Url $script:Base -User $Username -Pass $Password
Write-Host "Connected to qBittorrent $((Get-QbitJson -Path 'app/version')) at $script:Base as $Username"

Set-MaxDownloadPreferences
$targets = @(Get-TargetTorrents)
Show-Summary -Torrents $targets -Label 'before' | Out-Null
Add-RescueTrackers -Torrents $targets
Force-And-Reannounce -Torrents $targets
Start-Sleep -Seconds 3
$targets = @(Get-TargetTorrents)
$blocked = Show-Summary -Torrents $targets -Label 'after-force'

if ($Watch -or $WatchMinutes -gt 0) {
    $deadline = if ($WatchMinutes -gt 0) { (Get-Date).AddMinutes($WatchMinutes) } else { [datetime]::MaxValue }
    $cycle = 0
    while ((Get-Date) -lt $deadline) {
        $cycle++
        $targets = @(Get-TargetTorrents)
        Add-RescueTrackers -Torrents $targets
        Force-And-Reannounce -Torrents $targets
        Start-Sleep -Seconds $PollSeconds
        $targets = @(Get-TargetTorrents)
        $blocked = Show-Summary -Torrents $targets -Label "watch-$cycle"
        if ($blocked -eq 0) { break }
    }
}

$final = @(Get-TargetTorrents)
$finalBlocked = Show-Summary -Torrents $final -Label 'final'
if ($finalBlocked -gt 0) {
    Write-Warning "Some torrents remain metadata/stalled/zero-speed after all qBittorrent-side limits were removed and retries were sent. That means the remaining bottleneck is external swarm/trackers/network reachability, not a local qBittorrent speed cap. Leave this script running with -Watch to keep retrying."
}
