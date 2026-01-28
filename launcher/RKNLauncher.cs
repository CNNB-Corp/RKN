using System;
using System.Diagnostics;
using System.IO;

namespace RknLauncher
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(exeDir, "RKN.ps1");
                if (!File.Exists(scriptPath))
                {
                    Console.Error.WriteLine("Не найден RKN.ps1 рядом с exe: {0}", scriptPath);
                    return 1;
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = string.Format("-NoProfile -ExecutionPolicy Bypass -File \"{0}\"", scriptPath),
                    UseShellExecute = false,
                    RedirectStandardOutput = false,
                    RedirectStandardError = false,
                    RedirectStandardInput = false
                };

                using (var process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        Console.Error.WriteLine("Не удалось запустить powershell.exe.");
                        return 1;
                    }

                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Ошибка запуска: {0}", ex.Message);
                return 1;
            }
        }
    }
}
