using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Laer.Windows;

public partial class App : Application
{
    internal static bool Demo { get; private set; }
    internal static string Root { get; private set; } = "";
    private static string? demoTheme;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Demo = e.Args.Contains("--demo");
        demoTheme = Demo ? e.Args.FirstOrDefault(x => x.StartsWith("--theme="))?.Split('=')[1] : null;
        Root = Demo ? Path.Combine(Path.GetTempPath(), "Laer-Demo") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Laer");
        Directory.CreateDirectory(Root);
        ApplyTheme();
        var window = new MainWindow(); MainWindow = window; window.Show();
    }
    internal static void SetDemo(bool value)
    {
        Demo = value;
        Root = value ? Path.Combine(Path.GetTempPath(), "Laer-Demo") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Laer");
        Directory.CreateDirectory(Root);
    }
    internal void ApplyTheme()
    {
        var dark = demoTheme is "dark" || demoTheme != "light" && (int?)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) == 0;
        if (SystemParameters.HighContrast) return;
        var colors = dark ? new Dictionary<string, string>
        {
            ["Stage"]="#191919", ["Chrome"]="#222222", ["Rail"]="#2C2C2C", ["Raised"]="#303030",
            ["Line"]="#2E2E2E", ["Ink"]="#EDEDED", ["Muted"]="#9E9E9E", ["Selection"]="#1AFFFFFF", ["Hover"]="#0FFFFFFF", ["Danger"]="#FF6B60", ["ViewerPanel"]="#1F1F1F", ["StrongLine"]="#404040", ["Pressed"]="#24FFFFFF", ["Scrim"]="#8C000000"
        } : new Dictionary<string, string>
        {
            ["Stage"]="#FFFFFF", ["Chrome"]="#F3F3F3", ["Rail"]="#E2E2E2", ["Raised"]="#F7F7F7",
            ["Line"]="#E3E3E3", ["Ink"]="#1F1F1F", ["Muted"]="#6B6B6B", ["Selection"]="#14000000", ["Hover"]="#0D000000", ["Danger"]="#C62828", ["ViewerPanel"]="#FAFAFA", ["StrongLine"]="#CCCCCC", ["Pressed"]="#1F000000", ["Scrim"]="#59000000"
        };
        foreach (var (key, color) in colors) Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    }
}
