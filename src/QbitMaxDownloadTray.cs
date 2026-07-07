using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Management;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace QbitMaxDownloadTray
{
    internal static class Program
    {
        private const string TaskName = "QbitForceMaxDownloadPermanentWatchdog";
        private static readonly object Sync = new object();
        private static Process worker;
        private static NotifyIcon tray;
        private static string scriptPath;
        private static string logPath;
        private static bool exiting;

        [STAThread]
        private static int Main(string[] args)
        {
            scriptPath = FindScriptPath();
            logPath = Path.Combine(ProjectRootFromExecutable(), "logs", "QbitMaxDownloadTray.log");

            if (args.Any(a => String.Equals(a, "--stop-running", StringComparison.OrdinalIgnoreCase)))
            {
                StopAllOptimizerActivity(true);
                return 0;
            }

            if (!File.Exists(scriptPath))
            {
                MessageBox.Show("Missing engine script: " + scriptPath, "Qbit Max Download", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Directory.CreateDirectory(Path.GetDirectoryName(logPath));

            StopOtherTrayProcesses();
            StopAllOptimizerActivity(false);
            StartWorker(args);

            var menu = new ContextMenuStrip();
            menu.Items.Add("Status", null, delegate { ShowStatus(); });
            menu.Items.Add("Restart optimizer", null, delegate { RestartWorker(args); });
            menu.Items.Add("Open logs", null, delegate { OpenLogsFolder(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, delegate { ExitTray(); });

            tray = new NotifyIcon();
            tray.Icon = SystemIcons.Application;
            tray.Text = "Qbit Max Download active";
            tray.Visible = true;
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { ShowStatus(); };

            Application.ApplicationExit += delegate { CleanupOnExit(); };
            Application.Run();
            return 0;
        }

        private static void StartWorker(string[] args)
        {
            lock (Sync)
            {
                var ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(ps))
                {
                    ps = "powershell.exe";
                }

                var mapped = MapArguments(args).ToList();
                if (!mapped.Any(a => String.Equals(a, "-Watch", StringComparison.OrdinalIgnoreCase) ||
                                     String.Equals(a, "-WatchMinutes", StringComparison.OrdinalIgnoreCase) ||
                                     String.Equals(a, "-Minutes", StringComparison.OrdinalIgnoreCase) ||
                                     String.Equals(a, "-AuditOnly", StringComparison.OrdinalIgnoreCase) ||
                                     String.Equals(a, "-Rollback", StringComparison.OrdinalIgnoreCase)))
                {
                    mapped.Add("-Watch");
                    mapped.Add("-PollSeconds");
                    mapped.Add("15");
                    mapped.Add("-BenchmarkSeconds");
                    mapped.Add("0");
                }
                if (!mapped.Any(a => String.Equals(a, "-SkipWatchdogInstall", StringComparison.OrdinalIgnoreCase)))
                {
                    mapped.Add("-SkipWatchdogInstall");
                }

                var allArgs = new List<string>
                {
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-WindowStyle",
                    "Hidden",
                    "-File",
                    Quote(scriptPath)
                };
                allArgs.AddRange(mapped.Select(QuoteIfNeeded));

                var psi = new ProcessStartInfo();
                psi.FileName = ps;
                psi.Arguments = String.Join(" ", allArgs.ToArray());
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;

                worker = new Process();
                worker.StartInfo = psi;
                worker.EnableRaisingEvents = true;
                worker.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { AppendLog(e.Data); };
                worker.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { AppendLog(e.Data); };
                worker.Exited += delegate
                {
                    if (!exiting && tray != null)
                    {
                        tray.Text = "Qbit Max Download stopped";
                        tray.ShowBalloonTip(3000, "Qbit Max Download", "Optimizer worker stopped. Use Restart optimizer from the tray menu.", ToolTipIcon.Warning);
                    }
                };
                worker.Start();
                worker.BeginOutputReadLine();
                worker.BeginErrorReadLine();
                AppendLog("Started worker PID " + worker.Id + " with " + psi.Arguments);
            }
        }

        private static void RestartWorker(string[] args)
        {
            StopAllOptimizerActivity(false);
            StartWorker(args);
            if (tray != null)
            {
                tray.Text = "Qbit Max Download active";
                tray.ShowBalloonTip(1500, "Qbit Max Download", "Optimizer restarted.", ToolTipIcon.Info);
            }
        }

        private static void ExitTray()
        {
            exiting = true;
            CleanupOnExit();
            Application.Exit();
        }

        private static void CleanupOnExit()
        {
            StopAllOptimizerActivity(false);
            if (tray != null)
            {
                tray.Visible = false;
                tray.Dispose();
                tray = null;
            }
        }

        private static void StopAllOptimizerActivity(bool includeTrayProcesses)
        {
            lock (Sync)
            {
                KillProcessTree(worker);
                worker = null;
                KillPowerShellWorkers();
                EndAndDeleteWatchdogTask();
                if (includeTrayProcesses)
                {
                    StopOtherTrayProcesses();
                }
            }
        }

        private static void EndAndDeleteWatchdogTask()
        {
            RunHidden("schtasks.exe", "/End /TN " + Quote(TaskName));
            RunHidden("schtasks.exe", "/Delete /F /TN " + Quote(TaskName));
        }

        private static void KillPowerShellWorkers()
        {
            foreach (var processId in FindProcessesByCommandLine("powershell.exe", "Force-QbitMaxDownload.ps1"))
            {
                TryKillProcessTree(processId);
            }
        }

        private static void StopOtherTrayProcesses()
        {
            int current = Process.GetCurrentProcess().Id;
            foreach (var proc in Process.GetProcessesByName("QbitMaxDownloadTray"))
            {
                if (proc.Id == current) { continue; }
                TryKillProcessTree(proc.Id);
            }
        }

        private static IEnumerable<int> FindProcessesByCommandLine(string name, string commandNeedle)
        {
            var results = new List<int>();
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT ProcessId,CommandLine FROM Win32_Process WHERE Name='" + name.Replace("'", "''") + "'"))
                {
                    foreach (ManagementObject item in searcher.Get())
                    {
                        string commandLine = Convert.ToString(item["CommandLine"]);
                        if (commandLine != null && commandLine.IndexOf(commandNeedle, StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            results.Add(Convert.ToInt32(item["ProcessId"]));
                        }
                    }
                }
            }
            catch
            {
            }
            return results;
        }

        private static void KillProcessTree(Process proc)
        {
            if (proc == null) { return; }
            try
            {
                if (!proc.HasExited)
                {
                    TryKillProcessTree(proc.Id);
                }
            }
            catch
            {
            }
        }

        private static void TryKillProcessTree(int processId)
        {
            try
            {
                foreach (var childId in GetChildProcessIds(processId))
                {
                    TryKillProcessTree(childId);
                }
                using (var proc = Process.GetProcessById(processId))
                {
                    proc.Kill();
                    proc.WaitForExit(3000);
                }
            }
            catch
            {
            }
        }

        private static IEnumerable<int> GetChildProcessIds(int parentProcessId)
        {
            var ids = new List<int>();
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT ProcessId FROM Win32_Process WHERE ParentProcessId=" + parentProcessId))
                {
                    foreach (ManagementObject item in searcher.Get())
                    {
                        ids.Add(Convert.ToInt32(item["ProcessId"]));
                    }
                }
            }
            catch
            {
            }
            return ids;
        }

        private static int RunHidden(string fileName, string arguments)
        {
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = fileName;
                psi.Arguments = arguments;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                using (var proc = Process.Start(psi))
                {
                    proc.WaitForExit(5000);
                    return proc.ExitCode;
                }
            }
            catch
            {
                return -1;
            }
        }

        private static void ShowStatus()
        {
            string status = "Optimizer worker: ";
            try
            {
                status += (worker != null && !worker.HasExited) ? ("running, PID " + worker.Id) : "stopped";
            }
            catch
            {
                status += "unknown";
            }
            status += Environment.NewLine + "Engine: " + scriptPath + Environment.NewLine + "Log: " + logPath;
            MessageBox.Show(status, "Qbit Max Download", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static void OpenLogsFolder()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = Path.GetDirectoryName(logPath),
                    UseShellExecute = true
                });
            }
            catch
            {
            }
        }

        private static void AppendLog(string line)
        {
            if (String.IsNullOrEmpty(line)) { return; }
            try
            {
                File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }

        private static string FindScriptPath()
        {
            string root = ProjectRootFromExecutable();
            string local = Path.Combine(root, "scripts", "Force-QbitMaxDownload.ps1");
            if (File.Exists(local)) { return local; }
            return @"F:\study\Windows\Applications\Gaming\DownloadManagers\qBittorrent\Automation\SpeedOptimization\qbittorrent-force-max-download-20260603\scripts\Force-QbitMaxDownload.ps1";
        }

        private static string ProjectRootFromExecutable()
        {
            string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string name = Path.GetFileName(exeDir);
            if (String.Equals(name, "runtime", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, "dist", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, "bin", StringComparison.OrdinalIgnoreCase))
            {
                return Directory.GetParent(exeDir).FullName;
            }
            return exeDir;
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
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--benchmark-seconds":
                        yield return "-BenchmarkSeconds";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--minutes":
                        yield return "-Minutes";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--watch-minutes":
                        yield return "-WatchMinutes";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--poll-seconds":
                        yield return "-PollSeconds";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--category":
                        yield return "-Category";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--tag":
                        yield return "-Tag";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--base-url":
                        yield return "-BaseUrl";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--username":
                        yield return "-Username";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    case "--password":
                        yield return "-Password";
                        if (i + 1 < args.Length) { yield return args[++i]; }
                        break;
                    default:
                        yield return arg;
                        break;
                }
            }
        }

        private static string QuoteIfNeeded(string value)
        {
            if (value.StartsWith("-", StringComparison.Ordinal)) { return value; }
            return Quote(value);
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
