using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using System;
using System.IO;
using System.Threading;

namespace TacticalRadio.Launcher;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        try
        {
            Log("Tactical Radio launcher starting.");
            Log($"Base directory: {AppContext.BaseDirectory}");
            Log($"Current directory: {Environment.CurrentDirectory}");
            Log($"OS: {Environment.OSVersion}");
            Log($".NET: {Environment.Version}");
            Log("Initializing WinRT COM wrappers.");

            WinRT.ComWrappersSupport.InitializeComWrappers();

            Log("Calling Application.Start.");

            Application.Start((p) =>
            {
                Log("Application.Start callback entered.");

                try
                {
                    var dispatcherQueue = DispatcherQueue.GetForCurrentThread();

                    if (dispatcherQueue is null)
                    {
                        Log("DispatcherQueue.GetForCurrentThread returned null.");
                    }
                    else
                    {
                        Log("DispatcherQueue acquired.");
                    }

                    var context = new DispatcherQueueSynchronizationContext(dispatcherQueue);
                    SynchronizationContext.SetSynchronizationContext(context);

                    Log("SynchronizationContext set.");
                    Log("Creating App instance.");

                    new App();

                    Log("App instance created.");
                }
                catch (Exception ex)
                {
                    WriteCrashLog("Application.Start callback failed.", ex);
                    ShowNativeErrorBox("Application.Start callback failed.", ex);
                    throw;
                }
            });

            Log("Application.Start returned. The app exited.");
        }
        catch (Exception ex)
        {
            WriteCrashLog("Fatal launcher startup failure.", ex);
            ShowNativeErrorBox("Fatal launcher startup failure.", ex);
        }
    }

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(LauncherLogDirectory);

            File.AppendAllText(
                LauncherLogPath,
                $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}] {message}{Environment.NewLine}"
            );
        }
        catch
        {
            // Do not crash while trying to log.
        }
    }

    public static void WriteCrashLog(string message, Exception exception)
    {
        try
        {
            Directory.CreateDirectory(LauncherLogDirectory);

            File.AppendAllText(
                LauncherLogPath,
                $"""
                [{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}] {message}
                {exception}

                """
            );
        }
        catch
        {
            // Do not crash while trying to log a crash.
        }
    }

    private static string LauncherLogDirectory
    {
        get
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(localAppData, "TacticalRadio", "logs");
        }
    }

    private static string LauncherLogPath => Path.Combine(LauncherLogDirectory, "launcher-crash.log");

    private static void ShowNativeErrorBox(string title, Exception exception)
    {
        try
        {
            NativeMethods.MessageBoxW(
                IntPtr.Zero,
                $"Tactical Radio Launcher failed to start.\n\n{title}\n\n{exception}\n\nCrash log:\n{LauncherLogPath}",
                "Tactical Radio Launcher",
                0x00000010
            );
        }
        catch
        {
            // Ignore.
        }
    }

    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int MessageBoxW(
            IntPtr hWnd,
            string text,
            string caption,
            uint type
        );
    }
}