using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class JianNoteLauncher
{
    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();

        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(baseDirectory, "JianNote.ps1");
        bool selfTest = args.Length > 0 && String.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase);
        string dataDirectory = selfTest
            ? Path.Combine(baseDirectory, ".launcher-test", "JianNote")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JianNote");
        string logPath = Path.Combine(dataDirectory, "startup.log");

        try
        {
            Directory.CreateDirectory(dataDirectory);
            File.AppendAllText(
                logPath,
                Environment.NewLine + "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] Starting JianNote" + Environment.NewLine,
                Encoding.UTF8
            );

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

                File.AppendAllText(
                    logPath,
                    "Exited with code " + process.ExitCode + Environment.NewLine + errorOutput + Environment.NewLine,
                    Encoding.UTF8
                );

                if (process.ExitCode != 0 || !String.IsNullOrWhiteSpace(errorOutput))
                {
                    ShowStartupError(errorOutput, logPath);
                }
            }
        }
        catch (Exception exception)
        {
            try
            {
                Directory.CreateDirectory(dataDirectory);
                File.AppendAllText(logPath, exception.ToString() + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
                // The message box below still reports the original startup error.
            }

            ShowStartupError(exception.Message, logPath);
        }
    }

    private static void ShowStartupError(string details, string logPath)
    {
        string readableDetails = String.IsNullOrWhiteSpace(details) ? "应用程序意外退出。" : details.Trim();
        if (readableDetails.Length > 1200)
        {
            readableDetails = readableDetails.Substring(0, 1200) + "…";
        }

        MessageBox.Show(
            "简笺未能启动。\r\n\r\n" + readableDetails + "\r\n\r\n错误日志：\r\n" + logPath,
            "简笺启动失败",
            MessageBoxButtons.OK,
            MessageBoxIcon.Error
        );
    }
}

