using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ShapePath = System.Windows.Shapes.Path;

namespace Laer.Windows;

// One monochrome outline set: the same meaning and 16-point box as the Mac symbols.
internal static class Icons
{
    private static readonly Dictionary<string, string> Paths = new()
    {
        ["search"]="M10.5,3 A7.5,7.5 0 1 0 10.5,18 A7.5,7.5 0 1 0 10.5,3 M16,16 L22,22",
        ["home"]="M2,11 L12,3 22,11 M5,9 L5,21 10,21 10,15 14,15 14,21 19,21 19,9",
        ["task"]="M10,5 L22,5 M10,12 L22,12 M10,19 L22,19 M2,5 L4,7 7,3 M2,12 L4,14 7,10 M2,19 L4,21 7,17",
        ["calendar"]="M5,3 L5,7 M19,3 L19,7 M3,9 L21,9 M3,5 L21,5 21,22 3,22 Z M7,13 L10,13 M14,13 L17,13 M7,17 L10,17",
        ["message"]="M3,3 L17,3 17,14 9,14 4,18 4,14 3,14 Z M20,7 L22,7 22,20 18,20 18,23 14,20 10,20",
        ["course"]="M5,3 L20,3 20,21 5,21 C1,21 1,17 5,17 L20,17 M5,3 C1,3 2,7 2,8 L2,19 M7,7 L16,7",
        ["folder"]="M2,6 L9,6 11,8 22,8 22,21 2,21 Z M2,6 L2,3 9,3 11,6 20,6 20,8",
        ["file"]="M5,2 L14,2 20,8 20,22 5,22 Z M14,2 L14,8 20,8",
        ["clock"]="M12,2 A10,10 0 1 0 12,22 A10,10 0 1 0 12,2 M12,6 L12,12 16,14",
        ["person"]="M12,2 A10,10 0 1 0 12,22 A10,10 0 1 0 12,2 M12,6 A3,3 0 1 0 12,12 A3,3 0 1 0 12,6 M5,19 C5,12 19,12 19,19",
        ["bell"]="M4,17 L6,14 6,9 C6,1 18,1 18,9 L18,14 20,17 Z M10,20 C10,23 14,23 14,20",
        ["refresh"]="M21,9 C18,-1 3,1 3,12 C3,23 19,26 22,15 M21,3 L21,9 15,9",
        ["saved"]="M3,4 L21,4 21,9 3,9 Z M5,9 L5,22 19,22 19,9 M9,13 L15,13",
        ["sidebar"]="M2,3 L22,3 22,21 2,21 Z M9,3 L9,21",
        ["open"]="M14,3 L22,3 22,11 M22,3 L10,15 M10,3 L3,3 3,21 21,21 21,14",
        ["save"]="M12,2 A10,10 0 1 0 12,22 A10,10 0 1 0 12,2 M12,6 L12,17 M7,12 L12,17 17,12",
        ["check"]="M12,2 A10,10 0 1 0 12,22 A10,10 0 1 0 12,2 M6,12 L10,16 18,8",
        ["chevron"]="M8,4 L16,12 8,20", ["back"]="M16,4 L8,12 16,20",
        ["close"]="M5,5 L19,19 M19,5 L5,19", ["minimize"]="M4,12 L20,12",
        ["maximize"]="M4,4 L20,4 20,20 4,20 Z", ["restore"]="M8,4 L20,4 20,16 M4,8 L16,8 16,20 4,20 Z",
        ["more"]="M12,2 A10,10 0 1 0 12,22 A10,10 0 1 0 12,2 M7,12 L7.2,12 M12,12 L12.2,12 M17,12 L17.2,12",
        ["grades"]="M3,21 L3,13 7,13 7,21 Z M10,21 L10,7 14,7 14,21 Z M17,21 L17,2 21,2 21,21 Z",
        ["compose"]="M12,4 L3,4 3,22 21,22 21,13 M9,16 L10,11 19,2 23,6 14,15 Z",
        ["star"]="M12,2 L15,8 22,9 17,14 18,21 12,18 6,21 7,14 2,9 9,8 Z"
    };
    internal static FrameworkElement Make(string name, double size = 16)
    {
        var path = new ShapePath { Data = Geometry.Parse(Paths.GetValueOrDefault(name, Paths["file"])), StrokeThickness = 1.45, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, Stretch = Stretch.Uniform, Width = 22, Height = 22 };
        path.SetResourceReference(ShapePath.StrokeProperty, "Muted");
        return new Viewbox { Width = size, Height = size, Child = path, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center };
    }
    internal static string Tab(string name) => name switch { "Plans" or "Calendar" => "calendar", "Updates" => "bell", "Materials" => "folder", "Participants" => "person", "Grades" => "grades", "Tasks" => "task", _ => "file" };
    internal static StackPanel Label(string icon, string title, double fontSize = 13)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        var symbol = Make(icon, fontSize == 11 ? 12 : 16); symbol.Margin = new Thickness(0, 0, 6, 0); panel.Children.Add(symbol);
        panel.Children.Add(new TextBlock { Text = title, FontSize = fontSize, VerticalAlignment = VerticalAlignment.Center }); return panel;
    }
}
