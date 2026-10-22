using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class JianNoteLauncher
{
    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();

        bool selfTest = args.Length > 0 && String.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase);
        bool ownsMutex = false;

        // 同一时间只允许一个实例：两个实例同时写 notes.json 会互相抢占导致启动失败
        using (Mutex instanceMutex = new Mutex(false, @"Local\JianNote.SingleInstance"))
        {
            if (!selfTest)
            {
                try
                {
                    ownsMutex = instanceMutex.WaitOne(0);
                }
                catch (AbandonedMutexException)
                {
                    // 上一个实例异常退出，这里接管即可
                    ownsMutex = true;
                }

                if (!ownsMutex)
                {
                    MessageBox.Show(
                        "简笺已经在运行了，请在任务栏里切换到它的窗口。",
                        "简笺",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information
                    );
                    return;
                }
            }

            try
            {
                RunApplication(selfTest);
            }
            finally
            {
                if (ownsMutex)
                {
                    instanceMutex.ReleaseMutex();
                }
            }
        }
    }

    private static void RunApplication(bool selfTest)
    {
        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(baseDirectory, "JianNote.ps1");
        string dataDirectory = selfTest
            ? Path.Combine(baseDirectory, ".launcher-test", "JianNote")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JianNote");
        string logPath = ResolveLogPath(dataDirectory);

        try
        {
            WriteLog(logPath, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] Starting JianNote");

            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("找不到应用程序文件 JianNote.ps1。请不要将简笺.exe 单独移出当前文件夹。", scriptPath);
            }

            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powershellPath = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershellPath))
            {
                powershellPath = "powershell.exe";
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powershellPath;
            startInfo.WorkingDirectory = baseDirectory;
            startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File \"" + scriptPath.Replace("\"", "\\\"") + "\"" + (selfTest ? " -SelfTest" : "");
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardError = true;

            using (Process process = new Process())
            {
                process.StartInfo = startInfo;
                process.Start();
                string errorOutput = process.StandardError.ReadToEnd();
                process.WaitForExit();

                WriteLog(logPath, "Exited with code " + process.ExitCode + Environment.NewLine + errorOutput);

                if (process.ExitCode != 0 || !String.IsNullOrWhiteSpace(errorOutput))
                {
                    ShowStartupError(errorOutput, logPath);
                }
            }
        }
        catch (Exception exception)
        {
            WriteLog(logPath, exception.ToString());
            ShowStartupError(exception.Message, logPath);
        }
    }

    /// <summary>
    /// 找出可写的日志位置：优先应用数据目录，写不进去就退到临时目录，
    /// 都失败则返回 null —— 日志永远不应该阻止应用启动。
    /// </summary>
    private static string ResolveLogPath(string preferredDirectory)
    {
        string primary = Path.Combine(preferredDirectory, "startup.log");
        if (CanAppendTo(primary))
        {
            return primary;
        }

        string fallback = Path.Combine(Path.GetTempPath(), "JianNote", "startup.log");
        if (CanAppendTo(fallback))
        {
            return fallback;
        }

        return null;
    }

    private static bool CanAppendTo(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (FileStream stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            {
                stream.Write(new byte[0], 0, 0);
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void WriteLog(string logPath, string message)
    {
        if (String.IsNullOrEmpty(logPath))
        {
            return;
        }

        try
        {
            File.AppendAllText(logPath, Environment.NewLine + message.TrimEnd() + Environment.NewLine, Encoding.UTF8);
        }
        catch
        {
            // 日志写失败不影响使用
        }
    }

    private static void ShowStartupError(string details, string logPath)
    {
        string readableDetails = String.IsNullOrWhiteSpace(details) ? "应用程序意外退出。" : details.Trim();
        if (readableDetails.Length > 1200)
        {
            readableDetails = readableDetails.Substring(0, 1200) + "…";
        }

        string logHint = String.IsNullOrEmpty(logPath) ? "未能写入日志文件。" : logPath;
        MessageBox.Show(
            "简笺未能启动。\r\n\r\n" + readableDetails + "\r\n\r\n错误日志：\r\n" + logHint,
            "简笺启动失败",
            MessageBoxButtons.OK,
            MessageBoxIcon.Error
        );
    }
}
