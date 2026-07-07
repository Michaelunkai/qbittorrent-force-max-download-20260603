# qBittorrent Force Max Download

GitHub repository: https://github.com/Michaelunkai/qbittorrent-force-max-download-20260603

This project contains a tray executable plus a Windows PowerShell engine that pushes qBittorrent downloads toward the fastest speed the local machine, network, disk, and torrent swarm can actually provide.

Primary executable:

```text
F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\runtime\QbitMaxDownloadTray.exe
```

## What it does

`Force-QbitMaxDownload.ps1` connects to the local qBittorrent Web API and then:

- Removes qBittorrent-side global download and upload speed limits.
- Disables queue bottlenecks so all incomplete downloads can run.
- Enables DHT, PeX, LSD, all-tier announces, and all-tracker announces.
- Raises connection, request queue, announce, disk cache, and I/O thread settings to high-throughput values.
- Starts/resumes all incomplete torrents.
- Removes per-torrent download/upload limits for every targeted torrent.
- Moves targeted torrents to top priority and disables automatic management for them.
- Force-starts stalled, queued, stopped, metadata, and downloading torrents.
- Adds a small list of public rescue trackers to incomplete torrents unless `-NoTrackerInjection` is used.
- Reannounces torrents immediately.
- Re-applies the max-speed global preferences on every watch cycle.
- The tray executable runs hidden with no terminal, starts the engine in watch mode, writes logs under this F-drive project, and owns the worker lifecycle.
- Exiting the tray icon stops the optimizer worker immediately and deletes the legacy scheduled watchdog named `QbitForceMaxDownloadPermanentWatchdog`.
- On direct script no-argument runs, installs and starts a permanent Windows Scheduled Task watchdog named `QbitForceMaxDownloadPermanentWatchdog` so the force/max-speed behavior keeps running at logon and every 5 minutes.
- Optionally keeps watching and retrying forever in the current console with `-Watch`.

Important limitation: no script can create seeders, peers, tracker responses, internet bandwidth, or disk throughput that does not exist. If a torrent has zero available seeders or a dead magnet/tracker swarm, the script can keep retrying and remove local limits, but the external swarm still controls whether metadata or pieces can arrive.

## Prerequisites

- Windows with qBittorrent running.
- qBittorrent Web UI enabled.
- PowerShell 5 or newer.
- qBittorrent Web UI enabled. The script is now no-prompt by default and auto-uses/manages the local Web UI credential `admin` / `adminadmin` when no password is supplied.

The script auto-detects the Web UI port and username from:

`%APPDATA%\qBittorrent\qBittorrent.ini`

It does **not** store your password in this repository.

## Setup

No installation is required. Keep the folder anywhere under `F:\study` and run the PowerShell script.

If PowerShell blocks local scripts, run PowerShell with execution policy bypass for this invocation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1"
```

## Usage

Run from the tray with no console:

```powershell
F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\runtime\QbitMaxDownloadTray.exe
```

The tray app defaults to:

```powershell
-Watch -PollSeconds 15 -BenchmarkSeconds 0 -SkipWatchdogInstall
```

Supported tray executable switches include `--watch`, `--audit-only`, `--rollback`, `--local-only`, `--full-admin`, `--no-trackers`, `--verbose-torrent-list`, `--no-upload-cap`, `--upload-cap-kbps`, `--benchmark-seconds`, `--minutes`, `--watch-minutes`, `--poll-seconds`, `--category`, `--tag`, `--base-url`, `--username`, and `--password`.

For automated verification or emergency cleanup:

```powershell
F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\runtime\QbitMaxDownloadTray.exe --stop-running
```

That command stops the tray process, the hidden PowerShell engine, and the legacy watchdog task. It does not close qBittorrent.

Run once with no prompt, apply the speed settings, auto-login to the local qBittorrent Web UI, force-start incomplete downloads, reannounce, and keep retrying for 5 minutes by default:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1"
```

Run and keep retrying forever until you close the PowerShell window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1" -Watch
```

Run with a timed watch window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1" -WatchMinutes 10 -PollSeconds 20
```

Pass credentials without being prompted:

```powershell
$env:QBT_PASSWORD = "your-webui-password"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1" -Username admin -Watch
```

Or pass the password for a one-time run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1" -Username admin -Password "your-webui-password" -WatchMinutes 5
```

## Inputs

- `-BaseUrl`: qBittorrent Web UI base URL. Default: auto-detected `http://localhost:<port>`.
- `-Username`: qBittorrent Web UI username. Default: auto-detected from qBittorrent config or `admin`.
- `-Password`: Optional qBittorrent Web UI password. Default: `$env:QBT_PASSWORD`, then managed local default `adminadmin`. The script does not prompt.
- `-Watch`: keep retrying until all targeted torrents are no longer stalled/metadata/zero-speed.
- `-WatchMinutes`: retry for a fixed number of minutes. Default: `5`, so the exact script path by itself already retries instead of doing only one poke.
- `-PollSeconds`: delay between watch cycles. Default: `15`.
- `-NoTrackerInjection`: do not add public rescue trackers.
- `-VerboseTorrentList`: print every targeted torrent, not only active/problem states.

## Outputs

The script prints:

- qBittorrent version and API endpoint.
- Before/after/final target count.
- Total download speed in bytes per second.
- Count of torrents still blocked or zero-speed.
- Per-torrent state, speed, seeds, peers, progress, hash, and name for active/problem torrents.

## Important files

- `scripts/Force-QbitMaxDownload.ps1`: main script to run.
- `src/QbitMaxDownloadTray.cs`: no-console tray executable source.
- `runtime/QbitMaxDownloadTray.exe`: compiled tray executable.
- `tests/Test-Force-QbitMaxDownload.ps1`: parser and token verification test.
- `.gitignore`: excludes logs, caches, temp files, local secrets, and downloaded torrent data.

## Troubleshooting

### Login failed

Verify qBittorrent Web UI is enabled and that the username/password are correct. You can pass `-BaseUrl`, `-Username`, and `-Password` explicitly.

### 403 Forbidden

qBittorrent may reject the host header or require a Web UI login. Use `http://localhost:<port>` rather than an external host, and pass valid credentials.

### Torrents still show `metaDL`, `stalledDL`, or zero speed

The script has removed local qBittorrent caps and reannounced. Remaining causes are usually outside the local machine:

- No seeders or peers are reachable.
- Magnet metadata is unavailable from the DHT/swarm.
- Tracker is dead or temporarily unreachable.
- ISP/router/firewall/NAT blocks incoming connections.
- Disk or antivirus is bottlenecking writes.

Leave the script running with `-Watch` so it keeps reannouncing and force-starting as peers appear.

### Want to avoid adding trackers

Use `-NoTrackerInjection`.

## Verification

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\tests\Test-Force-QbitMaxDownload.ps1"
```

Expected output:

`PASS parser/token checks ...`
