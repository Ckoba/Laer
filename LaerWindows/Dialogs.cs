using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Laer.Windows.Core;
using Microsoft.Win32;

namespace Laer.Windows;

internal sealed class TextDialog : Window
{
    private readonly TextBox text;
    internal string Value => text.Text.Trim();
    internal List<string> Files { get; } = [];
    internal TextDialog(string title, string label, string action, bool multiline, bool files = false, string initial = "")
    {
        Title = title; Width = 520; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 16) });
        panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap });
        text = new TextBox { Text = initial, AcceptsReturn = multiline, TextWrapping = TextWrapping.Wrap, Height = multiline ? 160 : 36, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        System.Windows.Automation.AutomationProperties.SetName(text, label); panel.Children.Add(text);
        var fileLabel = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) };
        if (files)
        {
            var attach = new Button { Content = "Attach files", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            attach.Click += (_, _) =>
            {
                var picker = new OpenFileDialog { Multiselect = true };
                if (picker.ShowDialog(this) == true) { Files.Clear(); Files.AddRange(picker.FileNames); fileLabel.Text = string.Join("\n", Files.Select(Path.GetFileName)); }
            };
            panel.Children.Add(attach); panel.Children.Add(fileLabel);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        var ok = new Button { Content = action, IsDefault = !multiline, Style = (Style)Application.Current.FindResource("Primary") };
        ok.Click += (_, _) => { if (Value.Length > 0 || Files.Count > 0) DialogResult = true; };
        buttons.Children.Add(cancel); buttons.Children.Add(ok); panel.Children.Add(buttons);
        var surface = new Border { Child = panel, CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1) }; surface.SetResourceReference(Border.BackgroundProperty,"Raised"); surface.SetResourceReference(Border.BorderBrushProperty,"StrongLine"); Content = surface;
        Loaded += (_, _) => { text.Focus(); text.CaretIndex = text.Text.Length; };
    }
}

internal sealed record SearchResult(string Title, string Kind, JsonElement Item, long CourseId = 0)
{
    public override string ToString() => $"{Title} · {Kind}";
}
