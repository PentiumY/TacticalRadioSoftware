using Microsoft.UI.Xaml;
using System;
using System.Threading.Tasks;

namespace TacticalRadio.Launcher;

public partial class App : Application
{
    private Window? window;

    public App()
    {
        try
        {
            Program.Log("App constructor entered.");

            InitializeComponent();

            Program.Log("App InitializeComponent completed.");

            UnhandledException += OnWinUiUnhandledException;
            AppDomain.CurrentDomain.UnhandledException += OnCurrentDomainUnhandledException;
            TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

            Program.Log("App exception handlers registered.");
        }
        catch (Exception ex)
        {
            Program.WriteCrashLog("App constructor failed.", ex);
            throw;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Program.Log("App.OnLaunched entered.");
            Program.Log("Creating MainWindow.");

            window = new MainWindow();

            Program.Log("MainWindow created.");
            Program.Log("Activating MainWindow.");

            window.Activate();

            Program.Log("MainWindow activated.");
        }
        catch (Exception ex)
        {
            Program.WriteCrashLog("App.OnLaunched failed.", ex);
            throw;
        }
    }

    private static void OnWinUiUnhandledException(
        object sender,
        Microsoft.UI.Xaml.UnhandledExceptionEventArgs e
    )
    {
        Program.WriteCrashLog("WinUI unhandled exception.", e.Exception);
    }

    private static void OnCurrentDomainUnhandledException(
        object sender,
        System.UnhandledExceptionEventArgs e
    )
    {
        if (e.ExceptionObject is Exception ex)
        {
            Program.WriteCrashLog("AppDomain unhandled exception.", ex);
        }
        else
        {
            Program.WriteCrashLog(
                "AppDomain unhandled non-Exception object.",
                new Exception(e.ExceptionObject?.ToString() ?? "Unknown exception object")
            );
        }
    }

    private static void OnUnobservedTaskException(
        object? sender,
        UnobservedTaskExceptionEventArgs e
    )
    {
        Program.WriteCrashLog("Unobserved task exception.", e.Exception);
    }
}