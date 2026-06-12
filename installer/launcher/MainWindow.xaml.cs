using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Windows.Graphics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace TacticalRadio.Launcher;

public sealed partial class MainWindow : Window
{
    private const double LargeWindowWidthDip = 1080;
    private const double LargeWindowHeightDip = 820;
    private const double NormalWindowWidthDip = 980;
    private const double NormalWindowHeightDip = 760;
    private const double CompactWindowWidthDip = 900;
    private const double CompactWindowHeightDip = 700;
    private const double MinimumWindowWidthDip = 760;
    private const double MinimumWindowHeightDip = 560;

    private const string GitHubOwner = "PentiumY";
    private const string GitHubRepository = "TacticalRadioSoftware";
    private const string GitHubInstallerAssetPattern = @"^TacticalRadioSetup-.*\.exe$";

    private readonly string appDir;
    private readonly LauncherService launcherService;
    private readonly GitHubUpdateService updateService;
    private readonly IntPtr windowHandle;
    private readonly AppWindow? appWindow;

    private UpdateCheckResult? latestUpdateCheck;

    public MainWindow()
    {
        InitializeComponent();

        appDir = LauncherPaths.ResolveAppDir(Environment.GetCommandLineArgs());
        launcherService = new LauncherService(appDir);

        updateService = new GitHubUpdateService(
            GitHubOwner,
            GitHubRepository,
            GitHubInstallerAssetPattern
        );

        windowHandle = WindowNative.GetWindowHandle(this);

        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        appWindow = AppWindow.GetFromWindowId(windowId);

        ConfigureWindow();
        LoadLogo();
        LoadConfigIntoUi();

        _ = CheckForUpdatesAsync(showSuccessWhenCurrent: false);
    }

    private void ConfigureWindow()
    {
        Title = "Tactical Radio";
        ConfigureStartupWindowSize();

        var iconPath = Path.Combine(appDir, "TacticalRadio.ico");
        if (File.Exists(iconPath))
        {
            try
            {
                appWindow?.SetIcon(iconPath);
            }
            catch
            {
                // Icon loading is cosmetic. Ignore failures so the launcher still starts.
            }
        }
    }

    private void ConfigureStartupWindowSize()
    {
        if (appWindow is null)
        {
            return;
        }

        var dpiScale = GetDpiScaleForWindow(windowHandle);
        var displayArea = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary);
        var workArea = displayArea.WorkArea;
        var outerBounds = displayArea.OuterBounds;

        var workAreaLeft = outerBounds.X + workArea.X;
        var workAreaTop = outerBounds.Y + workArea.Y;

        var availableWidthDip = workArea.Width / dpiScale;
        var availableHeightDip = workArea.Height / dpiScale;

        var preferredSizeDip = GetPreferredWindowSizeDip(availableWidthDip, availableHeightDip);
        var maxWidthDip = Math.Max(480, availableWidthDip * 0.92);
        var maxHeightDip = Math.Max(420, availableHeightDip * 0.88);

        var startupWidthDip = Clamp(preferredSizeDip.Width, 480, maxWidthDip);
        var startupHeightDip = Clamp(preferredSizeDip.Height, 420, maxHeightDip);

        var minWidthDip = Math.Min(MinimumWindowWidthDip, Math.Max(480, availableWidthDip * 0.82));
        var minHeightDip = Math.Min(MinimumWindowHeightDip, Math.Max(420, availableHeightDip * 0.72));

        var startupWidthPx = ToPixels(startupWidthDip, dpiScale);
        var startupHeightPx = ToPixels(startupHeightDip, dpiScale);
        var minWidthPx = ToPixels(minWidthDip, dpiScale);
        var minHeightPx = ToPixels(minHeightDip, dpiScale);

        if (appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = minWidthPx;
            presenter.PreferredMinimumHeight = minHeightPx;
        }

        var x = workAreaLeft + Math.Max(0, (workArea.Width - startupWidthPx) / 2);
        var y = workAreaTop + Math.Max(0, (workArea.Height - startupHeightPx) / 2);

        appWindow.MoveAndResize(new RectInt32(x, y, startupWidthPx, startupHeightPx));
    }

    private static SizeDip GetPreferredWindowSizeDip(double availableWidthDip, double availableHeightDip)
    {
        if (availableWidthDip >= 1700 && availableHeightDip >= 1000)
        {
            return new SizeDip(LargeWindowWidthDip, LargeWindowHeightDip);
        }

        if (availableWidthDip >= 1200 && availableHeightDip >= 780)
        {
            return new SizeDip(NormalWindowWidthDip, NormalWindowHeightDip);
        }

        return new SizeDip(CompactWindowWidthDip, CompactWindowHeightDip);
    }

    private static double Clamp(double value, double min, double max)
    {
        if (max < min)
        {
            return max;
        }

        return Math.Min(Math.Max(value, min), max);
    }

    private static int ToPixels(double dips, double dpiScale)
    {
        return Math.Max(1, (int)Math.Round(dips * dpiScale));
    }

    private static double GetDpiScaleForWindow(IntPtr hwnd)
    {
        try
        {
            var dpi = GetDpiForWindow(hwnd);
            if (dpi > 0)
            {
                return dpi / 96.0;
            }
        }
        catch
        {
            // Fall back to 100% scale if Windows refuses the DPI query for any reason.
        }

        return 1.0;
    }

    private void LoadLogo()
    {
        var logoPath = Path.Combine(appDir, "TacticalRadioLogo.png");
        if (!File.Exists(logoPath))
        {
            LogoImage.Visibility = Visibility.Collapsed;
            LogoFallbackText.Visibility = Visibility.Visible;
            return;
        }

        try
        {
            LogoImage.Source = new BitmapImage(new Uri(logoPath));
            LogoImage.Visibility = Visibility.Visible;
            LogoFallbackText.Visibility = Visibility.Collapsed;
        }
        catch
        {
            LogoImage.Visibility = Visibility.Collapsed;
            LogoFallbackText.Visibility = Visibility.Visible;
        }
    }

    private void LoadConfigIntoUi()
    {
        var config = launcherService.LoadConfig();
        BaseUrlTextBox.Text = config.BaseUrl;
        PlaceIdTextBox.Text = config.PlaceId;
        JobIdTextBox.Text = config.JobId;
        MumblePathTextBox.Text = config.MumblePath;
    }

    private LauncherConfig ReadConfigFromUi()
    {
        return new LauncherConfig
        {
            BaseUrl = BaseUrlTextBox.Text.Trim(),
            PlaceId = PlaceIdTextBox.Text.Trim(),
            JobId = JobIdTextBox.Text.Trim(),
            MumblePath = MumblePathTextBox.Text.Trim()
        };
    }

    private async void BrowseButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FileOpenPicker
            {
                SuggestedStartLocation = PickerLocationId.ComputerFolder
            };

            picker.FileTypeFilter.Add(".exe");
            InitializeWithWindow.Initialize(picker, windowHandle);

            var file = await picker.PickSingleFileAsync();
            if (file is not null)
            {
                MumblePathTextBox.Text = file.Path;
            }
        }
        catch (Exception exception)
        {
            await ShowErrorAsync(exception.Message);
        }
    }

    private async void SaveSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var config = ReadConfigFromUi();

        await RunLauncherActionAsync(
            () => launcherService.SaveConfig(config),
            "Settings saved.",
            "Saved"
        );
    }

    private async void RepairPluginButton_Click(object sender, RoutedEventArgs e)
    {
        var config = ReadConfigFromUi();

        await RunLauncherActionAsync(
            () =>
            {
                launcherService.SaveConfig(config);
                launcherService.InstallPlugin();
            },
            "Plugin installed/repaired in Mumble plugin folder.",
            "Plugin ready"
        );
    }

    private async void LaunchMumbleButton_Click(object sender, RoutedEventArgs e)
    {
        var config = ReadConfigFromUi();

        await RunLauncherActionAsync(
            () => launcherService.LaunchMumble(config),
            "Mumble launched with Tactical Radio environment.",
            "Launched"
        );
    }

    private async void CheckForUpdatesButton_Click(object sender, RoutedEventArgs e)
    {
        await CheckForUpdatesAsync(showSuccessWhenCurrent: true);
    }

    private void UpdateButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (latestUpdateCheck is null ||
                string.IsNullOrWhiteSpace(latestUpdateCheck.BestUpdateUrl))
            {
                SetUpdateStatus(
                    "No update link available",
                    "The latest GitHub release did not include a usable installer asset.",
                    false,
                    "No update link"
                );

                SetStatus(
                    "The latest GitHub release did not include a usable installer asset.",
                    InfoBarSeverity.Warning,
                    "No update link"
                );

                return;
            }

            Process.Start(new ProcessStartInfo
            {
                FileName = latestUpdateCheck.BestUpdateUrl,
                UseShellExecute = true
            });
        }
        catch (Exception exception)
        {
            SetUpdateStatus(
                "Could not open update",
                exception.Message,
                false,
                "Update failed"
            );

            SetStatus(exception.Message, InfoBarSeverity.Error, "Update failed");
        }
    }

    private async Task CheckForUpdatesAsync(bool showSuccessWhenCurrent)
    {
        try
        {
            SetUpdateStatus(
                "Checking for updates...",
                "Contacting GitHub Releases.",
                false,
                "Checking..."
            );

            CheckForUpdatesButton.IsEnabled = false;
            UpdateButton.IsEnabled = false;

            latestUpdateCheck = await updateService.CheckForUpdatesAsync();

            if (latestUpdateCheck.IsUpdateAvailable)
            {
                var assetText = string.IsNullOrWhiteSpace(latestUpdateCheck.InstallerAssetName)
                    ? "Open the GitHub release page to download the installer."
                    : $"Installer asset: {latestUpdateCheck.InstallerAssetName}";

                SetUpdateStatus(
                    $"Update available: v{latestUpdateCheck.LatestVersion}",
                    $"Installed: v{latestUpdateCheck.CurrentVersion}. {assetText}",
                    true,
                    $"Update to v{latestUpdateCheck.LatestVersion}"
                );

                SetStatus(
                    $"A newer version is available: v{latestUpdateCheck.LatestVersion}.",
                    InfoBarSeverity.Warning,
                    "Update available"
                );
            }
            else
            {
                SetUpdateStatus(
                    "Up to date",
                    $"Installed version v{latestUpdateCheck.CurrentVersion} matches the latest GitHub release.",
                    false,
                    "Up to date"
                );

                if (showSuccessWhenCurrent)
                {
                    SetStatus(
                        "You are already running the latest version.",
                        InfoBarSeverity.Success,
                        "Up to date"
                    );
                }
            }
        }
        catch (Exception exception)
        {
            SetUpdateStatus(
                "Could not check for updates",
                "GitHub could not be reached or the latest release could not be read.",
                false,
                "Check failed"
            );

            if (showSuccessWhenCurrent)
            {
                SetStatus(exception.Message, InfoBarSeverity.Warning, "Update check failed");
            }
        }
        finally
        {
            CheckForUpdatesButton.IsEnabled = true;
        }
    }

    private void SetUpdateStatus(
        string title,
        string message,
        bool updateAvailable,
        string buttonText
    )
    {
        DispatcherQueue.TryEnqueue(
            () =>
            {
                UpdateStatusTitleText.Text = title;
                UpdateStatusMessageText.Text = message;

                UpdateButton.Content = buttonText;
                UpdateButton.IsEnabled = updateAvailable;
            }
        );
    }

    private async Task RunLauncherActionAsync(Action action, string successMessage, string successTitle)
    {
        SetBusy(true);

        try
        {
            await Task.Run(action);
            SetStatus(successMessage, InfoBarSeverity.Success, successTitle);
        }
        catch (Exception exception)
        {
            SetStatus(exception.Message, InfoBarSeverity.Error, "Error");
            await ShowErrorAsync(exception.Message);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void SetBusy(bool isBusy)
    {
        SaveSettingsButton.IsEnabled = !isBusy;
        RepairPluginButton.IsEnabled = !isBusy;
        LaunchMumbleButton.IsEnabled = !isBusy;
        BrowseButton.IsEnabled = !isBusy;
        CheckForUpdatesButton.IsEnabled = !isBusy;

        if (isBusy)
        {
            UpdateButton.IsEnabled = false;
        }
        else
        {
            UpdateButton.IsEnabled = latestUpdateCheck?.IsUpdateAvailable == true;
        }
    }

    private void SetStatus(string message, InfoBarSeverity severity, string title)
    {
        DispatcherQueue.TryEnqueue(
            () =>
            {
                StatusInfoBar.Title = title;
                StatusInfoBar.Message = message;
                StatusInfoBar.Severity = severity;
                StatusInfoBar.IsOpen = true;
            }
        );
    }

    private async Task ShowErrorAsync(string message)
    {
        var dialog = new ContentDialog
        {
            Title = "Tactical Radio Launcher",
            Content = message,
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = RootGrid.XamlRoot
        };

        await dialog.ShowAsync();
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private readonly record struct SizeDip(double Width, double Height);
}