using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;

namespace QbitMaxDownloadLauncher
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string root = exeDir;
            if (String.Equals(Path.GetFileName(exeDir), "dist", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(Path.GetFileName(exeDir), "bin", StringComparison.OrdinalIgnoreCase))
            {
                root = Directory.GetParent(exeDir).FullName;
            }

            string script = Path.Combine(root, "scripts", "Force-QbitMaxDownload.ps1");
            if (!File.Exists(script))
            {
                string fallback = @"F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1";
                if (File.Exists(fallback))
                {
                    script = fallback;
                }
            }

            if (!File.Exists(script))
            {
                Console.Error.WriteLine("Missing engine script: " + script);
                return 2;
            }

            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
            {
                powershell = "powershell.exe";
            }

            var psArgs = new List<string>();
            psArgs.Add("-NoProfile");
            psArgs.Add("-ExecutionPolicy");
            psArgs.Add("Bypass");
            psArgs.Add("-File");
            psArgs.Add(Quote(script));
            psArgs.AddRange(MapArguments(args));

            var psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = String.Join(" ", psArgs.ToArray());
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = false;
            psi.RedirectStandardError = false;
            psi.CreateNoWindow = false;

            using (Process process = Process.Start(psi))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }

        private static IEnumerable<string> MapArguments(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                string lower = arg.ToLowerInvariant();
                switch (lower)
                {
                    case "--watch":
                        yield return "-Watch";
                        break;
                    case "--audit-only":
                        yield return "-AuditOnly";
                        break;
                    case "--rollback":
                        yield return "-Rollback";
                        break;
                    case "--local-only":
                        yield return "-LocalOnly";
                        break;
                    case "--full-admin":
                        yield return "-FullAdmin";
                        break;
                    case "--no-trackers":
                        yield return "-NoTrackerInjection";
                        break;
                    case "--verbose-torrent-list":
                        yield return "-VerboseTorrentList";
                        break;
                    case "--skip-watchdog-install":
                        yield return "-SkipWatchdogInstall";
                        break;
                    case "--no-upload-cap":
                        yield return "-NoUploadCap";
                        break;
                    case "--upload-cap-kbps":
                        yield return "-UploadCapKBps";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--benchmark-seconds":
                        yield return "-BenchmarkSeconds";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--minutes":
                        yield return "-Minutes";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--poll-seconds":
                        yield return "-PollSeconds";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--category":
                        yield return "-Category";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--tag":
                        yield return "-Tag";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--base-url":
                        yield return "-BaseUrl";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--username":
                        yield return "-Username";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    case "--password":
                        yield return "-Password";
                        if (i + 1 < args.Length) { yield return Quote(args[++i]); }
                        break;
                    default:
                        yield return Quote(arg);
                        break;
                }
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
