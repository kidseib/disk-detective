using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace DiskDetective
{
    internal static class Launcher
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_OK = 0x00000000;
        private const uint MB_ICONERROR = 0x00000010;

        [STAThread]
        private static int Main(string[] args)
        {
            string folder = AppDomain.CurrentDomain.BaseDirectory;
            string[] requiredFiles =
            {
                "DiskDetective.ps1",
                "DiskDetective.Core.ps1",
                "DiskDetective.Tools.ps1",
                "DiskDetective.Data.ps1"
            };

            foreach (string name in requiredFiles)
            {
                string path = Path.Combine(folder, name);
                if (!File.Exists(path))
                {
                    ShowError("Disk Detective could not start because a required file is missing:\r\n\r\n" + path +
                        "\r\n\r\nKeep all the downloaded files together in one folder, then try again.");
                    return 2;
                }
            }

            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");

            if (!File.Exists(powerShell))
            {
                ShowError("Disk Detective could not find Windows PowerShell 5.1.\r\n\r\n" +
                    "Install the Windows PowerShell update, then try again.");
                return 3;
            }

            string script = Path.Combine(folder, "DiskDetective.ps1");
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            startInfo.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File \"" + script + "\"";
            if (args != null && args.Length > 0)
            {
                startInfo.Arguments += " " + string.Join(" ", Array.ConvertAll(args, QuoteArgument));
            }
            startInfo.WorkingDirectory = folder;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;

            try
            {
                using (Process process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        ShowError("Disk Detective could not start Windows PowerShell.");
                        return 4;
                    }

                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                ShowError("Disk Detective could not start.\r\n\r\n" + ex.Message);
                return 1;
            }
        }

        // Encode arguments using the Windows CommandLineToArgvW quoting rules.
        private static string QuoteArgument(string value)
        {
            if (value == null) { return "\"\""; }
            if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return value;
            }

            StringBuilder quoted = new StringBuilder();
            quoted.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    quoted.Append('\\', backslashes * 2 + 1);
                    quoted.Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes > 0)
                {
                    quoted.Append('\\', backslashes);
                    backslashes = 0;
                }
                quoted.Append(character);
            }
            if (backslashes > 0)
            {
                quoted.Append('\\', backslashes * 2);
            }
            quoted.Append('"');
            return quoted.ToString();
        }

        private static void ShowError(string message)
        {
            if (Environment.GetEnvironmentVariable("DISKDETECTIVE_LAUNCHER_NO_DIALOG") == "1")
            {
                try { Console.Error.WriteLine(message); } catch { }
                return;
            }
            MessageBoxW(IntPtr.Zero, message, "Disk Detective", MB_OK | MB_ICONERROR);
        }
    }
}
