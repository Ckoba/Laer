using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Laer.Windows.Core;

namespace Laer.Windows;

public partial class MainWindow
{
    private bool prefersSidebar = true;
    private bool forceSidebar;
    private bool viewerFull;
    private double viewerWidth;
    private readonly HashSet<long> expandedCourses = [];
    private readonly Dictionary<long, string> selectedCourseTabs = [];
    private readonly List<ViewerEntry> viewerEntries = [];
    private ViewerEntry? activeViewer;
    private string searchScope = "Everywhere";
    private string searchKind = "Everything";
    private string searchType = "Any file type";
    private long selectedThreadId;
    private List<SearchResult> searchCandidates = [];
    private StackPanel Body => section == "messages" ? MessageThreads : PageBody;
    private StackPanel Detail => section == "messages" ? MessageBody : ViewerDetail;
    private sealed record ViewerEntry(string Key, string Title, FrameworkElement Content, SavedFile? File = null);
    private static readonly string[] CourseSections = ["Plans", "Updates", "Materials", "Calendar", "Participants", "Grades"];

    private void InitializeShell()
    {
        foreach (var (button, icon) in new (Button, string)[] { (SearchRail,"search"), (HomeRail,"home"), (UpcomingRail,"task"), (CalendarRail,"calendar"), (MessagesRail,"message"), (SavedRail,"saved"), (RefreshRail,"refresh"), (AccountButton,"person"), (SidebarToggle,"sidebar"), (NotificationButton,"bell"), (MinimizeButton,"minimize"), (MaximizeButton,"maximize"), (CloseWindowButton,"close"), (ViewerMenuButton,"more"), (ViewerCloseButton,"close") }) button.Content = Icons.Make(icon);
        PaletteSearchIcon.Content = Icons.Make("search");
        ContentPanel.SizeChanged += (_, _) => { PageBody.Width = Math.Max(0, Math.Min(720, ContentPanel.ActualWidth - 48)); ReaderBody.Width = PageBody.Width; };
        StateChanged += (_, _) => { MaximizeButton.Content = Icons.Make(WindowState == WindowState.Maximized ? "restore" : "maximize"); WindowRoot.Margin = WindowState == WindowState.Maximized ? new Thickness(6) : new Thickness(0); };
        ApplyLayout();
    }
    private void WindowSizeChanged(object sender, SizeChangedEventArgs e) { if (Shell != null) ApplyLayout(); }
    private void ShellSizeChanged(object sender, SizeChangedEventArgs e)
    {
        Shell.Clip = new RectangleGeometry(new Rect(0, 0, Math.Max(0, Shell.ActualWidth), Math.Max(0, Shell.ActualHeight)), 16, 16);
        ApplyLayout();
    }
    private void ApplyLayout()
    {
        var opened = activeViewer != null;
        var sidebar = prefersSidebar && (!opened || forceSidebar || ActualWidth >= 1180);
        SidebarColumn.Width = new GridLength(sidebar ? 248 : 0);
        var available = Math.Max(0, ActualWidth - 46 - (sidebar ? 248 : 0));
        ContentColumn.MinWidth = opened && viewerFull ? 0 : 260;
        ContentColumn.Width = opened && viewerFull ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        ContentPanel.Visibility = opened && viewerFull ? Visibility.Collapsed : Visibility.Visible;
        DetailColumn.MinWidth = opened ? Math.Min(320, available) : 0;
        DetailColumn.Width = opened ? new GridLength(viewerFull ? available : Math.Min(Math.Max(320, viewerWidth > 0 ? viewerWidth : available * .5), Math.Max(320, available - 260))) : new GridLength(0);
        SplitterColumn.Width = new GridLength(opened && !viewerFull ? 5 : 0);
        ViewerSplitter.Visibility = opened && !viewerFull ? Visibility.Visible : Visibility.Collapsed;
        PageBody.Width = Math.Max(0, Math.Min(720, ContentPanel.ActualWidth - 48));
        ReaderBody.Width = PageBody.Width;
        SidebarToggle.ToolTip = sidebar ? "Hide sidebar (Ctrl+Shift+S)" : "Show sidebar (Ctrl+Shift+S)";
        System.Windows.Automation.AutomationProperties.SetName(SidebarToggle, sidebar ? "Hide sidebar" : "Show sidebar");
    }
    private void ToggleSidebarClick(object sender, RoutedEventArgs e)
    {
        if (SidebarColumn.ActualWidth > 0) { prefersSidebar = false; forceSidebar = false; }
        else { prefersSidebar = true; forceSidebar = activeViewer != null; }
        ApplyLayout();
    }
    private void MinimizeClick(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(this);
    private void MaximizeClick(object sender, RoutedEventArgs e) { if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this); else SystemCommands.MaximizeWindow(this); }
    private void CloseWindowClick(object sender, RoutedEventArgs e) => SystemCommands.CloseWindow(this);
    private async void NotificationsClick(object sender, RoutedEventArgs e) => await Run(ShowNotifications);
    private async void ContinueSignInClick(object sender, RoutedEventArgs e) => await Run(SignIn);
    private async void DemoClick(object sender, RoutedEventArgs e) => await Run(StartDemo);
    private async void InstitutionKeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) { e.Handled = true; await Run(SignIn); } }
    private void ViewerResized(object sender, DragCompletedEventArgs e) { viewerWidth = DetailColumn.ActualWidth; }
    private void UpdateNavigation()
    {
        foreach (var (button, name) in new (Button,string)[] { (HomeRail,"home"), (UpcomingRail,"upcoming"), (CalendarRail,"calendar"), (MessagesRail,"messages"), (SavedRail,"saved"), (NotificationButton,"notifications") })
            button.SetResourceReference(BackgroundProperty, section == name ? "Selection" : "TransparentSurface");
        BuildSidebar();
    }
    private void BuildSidebar()
    {
        CourseList.Children.Clear();
        foreach (var item in courses.OrderBy(x => x.Text("FriendlyName", x.Text("Title"))))
        {
            var id = item.Id("CourseId"); var selected = section == "course" && course.Id("CourseId") == id;
            var group = new StackPanel { Margin = new Thickness(0, 0, 0, 2) };
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
            var name = new Button { Content = Icons.Label("course", item.Text("FriendlyName", item.Text("Title"))), HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(8), MinHeight = 32 };
            System.Windows.Automation.AutomationProperties.SetName(name, item.Text("Title"));
            if (selected && !expandedCourses.Contains(id)) name.SetResourceReference(BackgroundProperty, "Selection");
            name.Click += async (_, _) => await Run(() => OpenCourse(item)); row.Children.Add(name);
            var menu = new ContextMenu();
            var favorite = new MenuItem { Header = "Toggle active", IsEnabled = api?.CanWrite == true };
            favorite.Click += async (_, _) => await Run(async () => { await RequireApi().Write(HttpMethod.Put, $"/restapi/personal/courses/{id}/toggleFavorite/v1"); });
            menu.Items.Add(favorite);
            var website = new MenuItem { Header = "Open on the website" }; website.Click += async (_, _) => await Run(() => Website(item)); menu.Items.Add(website); name.ContextMenu = menu;
            var expand = IconButton("chevron", expandedCourses.Contains(id) ? "Hide sections of " + item.Text("Title") : "Show sections of " + item.Text("Title"), () =>
            { if (!expandedCourses.Remove(id)) expandedCourses.Add(id); BuildSidebar(); return Task.CompletedTask; });
            if (expandedCourses.Contains(id)) expand.Content = RotatedChevron();
            expand.Opacity = expandedCourses.Contains(id) ? 1 : 0;
            row.MouseEnter += (_, _) => expand.Opacity = 1;
            row.MouseLeave += (_, _) => expand.Opacity = expandedCourses.Contains(id) ? 1 : 0;
            expand.GotKeyboardFocus += (_, _) => expand.Opacity = 1;
            Grid.SetColumn(expand, 1); row.Children.Add(expand); group.Children.Add(row);
            if (expandedCourses.Contains(id)) foreach (var tab in CourseSections)
            {
                var child = new Button { Content = Icons.Label(Icons.Tab(tab), tab), HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(16,2,0,0), MinHeight = 28 };
                if (selected && courseTab == tab) child.SetResourceReference(BackgroundProperty, "Selection");
                child.Click += async (_, _) => await Run(async () => { selectedCourseTabs[id] = tab; await OpenCourse(item); });
                group.Children.Add(child);
            }
            CourseList.Children.Add(group);
        }
    }
    private FrameworkElement RotatedChevron()
    {
        var icon = Icons.Make("chevron", 12); icon.RenderTransformOrigin = new Point(.5,.5); icon.RenderTransform = new RotateTransform(90); return icon;
    }
    private Button IconButton(string icon, string label, Func<Task> action)
    {
        var button = new Button { Content = Icons.Make(icon), ToolTip = label, Style = (Style)FindResource("IconButton") };
        System.Windows.Automation.AutomationProperties.SetName(button, label);
        button.Click += async (_, _) => await Run(action); return button;
    }
    private void ShowAccountMenu()
    {
        var menu = new ContextMenu { PlacementTarget = AccountButton, Placement = PlacementMode.Right };
        menu.Items.Add(new MenuItem { Header = App.Demo ? "Demo · synthetic data" : account?.Site.Title ?? "Account", IsEnabled = false });
        var action = new MenuItem { Header = account == null ? "Sign in" : App.Demo ? "Leave demo" : "Sign out" };
        action.Click += async (_, _) => await Run(account == null ? SignIn : SignOut); menu.Items.Add(action); menu.IsOpen = true;
    }
    private void ShowViewer(ViewerEntry entry)
    {
        activeViewer = entry;
        foreach (var child in ViewerContents.Children.OfType<FrameworkElement>()) child.Visibility = child == entry.Content ? Visibility.Visible : Visibility.Collapsed;
        BuildViewerTabs(); ApplyLayout();
    }
    private void BuildViewerTabs()
    {
        ViewerTabs.Children.Clear();
        foreach (var entry in viewerEntries)
        {
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            var title = new Button { Content = Icons.Label("file", entry.Title, 12), Padding = new Thickness(8,4,4,4), MaxWidth = 180, ToolTip = entry.Title };
            title.Click += (_, _) => ShowViewer(entry); grid.Children.Add(title);
            var close = IconButton("close", "Close " + entry.Title, () => { CloseViewerTab(entry); return Task.CompletedTask; }); close.Width = 24; close.Height = 24; close.Padding = new Thickness(7);
            Grid.SetColumn(close, 1); grid.Children.Add(close);
            var border = new Border { CornerRadius = new CornerRadius(8), Margin = new Thickness(0,0,4,0), Child = grid };
            border.SetResourceReference(Border.BackgroundProperty, entry == activeViewer ? "Selection" : "TransparentSurface"); ViewerTabs.Children.Add(border);
        }
    }
    private void CloseViewerTab(ViewerEntry entry)
    {
        viewerEntries.Remove(entry);
        if (entry.Content != DetailScroll) { ViewerContents.Children.Remove(entry.Content); if (entry.Content is IDisposable disposable) disposable.Dispose(); }
        if (activeViewer == entry) activeViewer = viewerEntries.LastOrDefault();
        if (activeViewer != null) ShowViewer(activeViewer); else CloseViewer();
    }
    private void CloseViewer()
    {
        activeViewer = null; viewerFull = false; forceSidebar = false;
        foreach (var child in ViewerContents.Children.OfType<FrameworkElement>()) child.Visibility = Visibility.Collapsed;
        ApplyLayout();
    }
    private void ResetViewer()
    {
        CloseViewer();
        foreach (var entry in viewerEntries.ToArray())
        {
            if (entry.Content == DetailScroll) continue;
            ViewerContents.Children.Remove(entry.Content);
            if (entry.Content is IDisposable disposable) disposable.Dispose();
        }
        viewerEntries.Clear(); ViewerTabs.Children.Clear(); ViewerDetail.Children.Clear(); MessageBody.Children.Clear();
        notificationsPopup?.SetCurrentValue(Popup.IsOpenProperty,false);
    }
    private void ViewerMenuClick(object sender, RoutedEventArgs e)
    {
        if (activeViewer == null) return;
        var menu = new ContextMenu { PlacementTarget = ViewerMenuButton };
        var full = new MenuItem { Header = viewerFull ? "Exit full size" : "Full size" }; full.Click += (_, _) => { viewerFull = !viewerFull; ApplyLayout(); }; menu.Items.Add(full);
        if (activeViewer.File is { } file && store != null)
        {
            var copy = new MenuItem { Header = "Copy file" }; copy.Click += (_, _) => { var files = new System.Collections.Specialized.StringCollection { store.FilePath(file) }; Clipboard.SetFileDropList(files); }; menu.Items.Add(copy);
            var export = new MenuItem { Header = "Export…" }; export.Click += (_, _) => { var picker = new Microsoft.Win32.SaveFileDialog { FileName = file.Name }; if (picker.ShowDialog(this) == true) File.Copy(store.FilePath(file), picker.FileName, true); }; menu.Items.Add(export);
        }
        menu.IsOpen = true;
    }
    private void OpenPalette()
    {
        searchCandidates = courses.Select(x => new SearchResult(x.Text("FriendlyName", x.Text("Title")), "Course", x, x.Id("CourseId"))).Concat(tasks.Select(x => new SearchResult(x.Text("Title"), "Task", x, x.Id("LocationId")))).ToList();
        foreach (var (key, data) in cached)
        {
            if (data.ValueKind != JsonValueKind.Array || !(key.StartsWith("materials-") || key.StartsWith("plans-"))) continue;
            _ = long.TryParse(key.Split('-')[1], out var courseId);
            searchCandidates.AddRange(data.Array().Select(x => new SearchResult(x.Text("Title", x.Text("title", "Material")), key.StartsWith("plans-") ? "Plan" : "Material", x, courseId)));
        }
        PaletteOverlay.Visibility = Visibility.Visible; PaletteQuery.Clear(); BuildPaletteFilters(); FilterPalette();
        Dispatcher.InvokeAsync(() => PaletteQuery.Focus()); SearchRail.SetResourceReference(BackgroundProperty, "Selection");
    }
    private void ClosePalette() { PaletteOverlay.Visibility = Visibility.Collapsed; SearchRail.SetResourceReference(BackgroundProperty, "TransparentSurface"); SearchRail.Focus(); }
    private void BuildPaletteFilters()
    {
        PaletteFilters.Children.Clear();
        foreach (var scope in section == "course" ? new[] { "Everywhere", "Active courses", "This course" } : new[] { "Everywhere", "Active courses" })
        {
            var chip = new Button { Content = scope, FontSize = 11, MinHeight = 24, Padding = new Thickness(8,4,8,4), Margin = new Thickness(0,0,4,0) };
            if (searchScope == scope) chip.SetResourceReference(BackgroundProperty, "Selection");
            chip.Click += (_, _) => { searchScope = scope; BuildPaletteFilters(); FilterPalette(); }; PaletteFilters.Children.Add(chip);
        }
        foreach (var isType in new[] { false, true })
        {
            var button = new Button { Content = isType ? searchType : searchKind, FontSize = 11, MinHeight = 24, Padding = new Thickness(8,4,8,4) };
            button.Click += (_, _) =>
            {
                var menu = new ContextMenu { PlacementTarget = button };
                foreach (var label in isType ? new[] { "Any file type", "PDF", "PPTX", "DOCX", "XLSX" } : new[] { "Everything", "Course", "Plan", "Material", "Task" })
                { var pick = new MenuItem { Header = label }; pick.Click += (_, _) => { if (isType) searchType = label; else searchKind = label; BuildPaletteFilters(); FilterPalette(); }; menu.Items.Add(pick); }
                menu.IsOpen = true;
            }; PaletteFilters.Children.Add(button);
        }
    }
    private void FilterPalette()
    {
        if (PaletteResults == null) return;
        PaletteResults.Items.Clear();
        foreach (var result in searchCandidates.Where(x => x.Title.Contains(PaletteQuery.Text, StringComparison.CurrentCultureIgnoreCase) && (searchKind == "Everything" || x.Kind == searchKind) && (searchType == "Any file type" || x.Title.EndsWith("." + searchType, StringComparison.OrdinalIgnoreCase)) && (searchScope != "This course" || x.CourseId == course.Id("CourseId"))).Take(80))
        {
            var grid = new DockPanel(); var kind = new TextBlock { Text = result.Kind, FontSize = 11, Margin = new Thickness(12,0,0,0), VerticalAlignment = VerticalAlignment.Center }; kind.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); DockPanel.SetDock(kind,Dock.Right); grid.Children.Add(kind);
            grid.Children.Add(Icons.Label(result.Kind switch { "Course"=>"course", "Task"=>"task", "Plan"=>"calendar", _=>"file" }, result.Title));
            PaletteResults.Items.Add(new ListBoxItem { Content = grid, Tag = result });
        }
        PaletteResults.SelectedIndex = 0;
    }
    private void PaletteQueryChanged(object sender, TextChangedEventArgs e) => FilterPalette();
    private void PaletteBackdropClick(object sender, MouseButtonEventArgs e) => ClosePalette();
    private void PaletteSurfaceClick(object sender, MouseButtonEventArgs e) => e.Handled = true;
    private async void PalettePickClick(object sender, MouseButtonEventArgs e) => await PickPalette();
    private async void PaletteKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { ClosePalette(); e.Handled = true; }
        else if (e.Key is Key.Down or Key.Up)
        { PaletteResults.SelectedIndex = Math.Clamp(PaletteResults.SelectedIndex + (e.Key == Key.Down ? 1 : -1), 0, Math.Max(0, PaletteResults.Items.Count - 1)); PaletteResults.ScrollIntoView(PaletteResults.SelectedItem); e.Handled = true; }
        else if (e.Key == Key.Enter) { e.Handled = true; await PickPalette(); }
    }
    private async Task PickPalette()
    {
        if (PaletteResults.SelectedItem is not ListBoxItem { Tag: SearchResult result }) return;
        ClosePalette();
        await Run(async () => { switch (result.Kind) { case "Course": await OpenCourse(result.Item); break; case "Task": await OpenTask(result.Item); break; case "Plan": await Plan(result.Item); break; default: await SaveMaterial(result.Item); break; } });
    }
    private void ConversationRow(JsonElement item, string name)
    {
        var id = item.Id("InstantMessageThreadId");
        var content = new StackPanel(); var heading = new DockPanel();
        if (item.Field("LastMessage").Date("Created") is { } created) { var date = Label(ShortDate(created),11,true); DockPanel.SetDock(date,Dock.Right); heading.Children.Add(date); }
        var title = Label(name); if (item.Field("LastMessage").Id("MessageId") > item.Id("LastReadInstantMessageId")) title.FontWeight = FontWeights.SemiBold;
        heading.Children.Add(title); content.Children.Add(heading);
        var preview = Label(Truncate(Json.Plain(item.Field("LastMessage").Text("Text")),100),12,true); preview.Margin = new Thickness(0,2,0,0); content.Children.Add(preview);
        var button = new Button { Content = content, Tag = id, Style = (Style)FindResource("ContentRow") };
        if (selectedThreadId == id) button.SetResourceReference(BackgroundProperty,"Selection");
        System.Windows.Automation.AutomationProperties.SetName(button,name);
        button.Click += async (_, _) => await Run(async () =>
        {
            selectedThreadId = id;
            foreach (var row in MessageThreads.Children.OfType<Button>()) row.SetResourceReference(BackgroundProperty, row.Tag is long rowId && rowId == id ? "Selection" : "TransparentSurface");
            await Thread(item);
        }); MessageThreads.Children.Add(button);
    }
    private StackPanel OpenReader(string title)
    {
        ReaderBody.Children.Clear(); ReaderHost.Visibility = Visibility.Visible;
        PageScroll.Visibility = Visibility.Collapsed; CalendarHost.Visibility = Visibility.Collapsed; MessagesHost.Visibility = Visibility.Collapsed;
        ScreenHeader.Visibility = Visibility.Visible; PageTitle.Text = title; Tabs.Visibility = Visibility.Collapsed;
        HeaderActions.Children.Clear(); HeaderActions.Children.Add(IconButton("back","Back",()=>Navigate(section)));
        return ReaderBody;
    }
    private Popup? notificationsPopup;
    private async Task ShowNotifications()
    {
        if (notificationsPopup?.IsOpen == true) { notificationsPopup.IsOpen = false; return; }
        var body = new StackPanel { Margin = new Thickness(8) };
        var header = new DockPanel(); var heading = Label("Notifications",13); heading.FontWeight = FontWeights.SemiBold;
        var refresh = IconButton("refresh","Refresh notifications",async()=>{ if(notificationsPopup != null) notificationsPopup.IsOpen=false; await ShowNotifications(); }); DockPanel.SetDock(refresh,Dock.Right); header.Children.Add(refresh); header.Children.Add(heading); body.Children.Add(header);
        var border = new Border { Child = body, Width = 360, MaxHeight = 480, CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Padding = new Thickness(4) };
        border.SetResourceReference(Border.BackgroundProperty,"Raised"); border.SetResourceReference(Border.BorderBrushProperty,"StrongLine");
        notificationsPopup = new Popup { PlacementTarget = NotificationButton, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true, Child = border, IsOpen = true };
        try
        {
            var items = await Collection("notifications","/restapi/personal/notifications/v2");
            var unread = items.Where(x=>x.Flag("IsRead")==false).ToList();
            if (unread.Count>0) AddButton(body,"Mark all read",async()=>{await RequireApi().Write(HttpMethod.Put,"/restapi/personal/notifications/v2",unread.Select(x=>new{NotificationId=x.Id("NotificationId"),IsRead=true}).ToArray());notificationsPopup.IsOpen=false;},write:true);
            var list = new StackPanel(); body.Children.Add(new ScrollViewer { Content = list, MaxHeight = 360, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            foreach(var item in items) Row(list,Json.Plain(item.Text("Text")),item.Date("PublishedDate") is {} date ? ShortDate(date) : "",()=>{notificationsPopup.IsOpen=false;OpenDetail("Notification");Text(Detail,Json.Plain(item.Text("Text")));AddButton(Detail,"Mark read",async()=>{await RequireApi().Write(HttpMethod.Put,"/restapi/personal/notifications/v2",new[]{new{NotificationId=item.Id("NotificationId"),IsRead=true}});},write:true);AddButton(Detail,"Website",()=>Website(item));return Task.CompletedTask;});
            if(items.Count==0)Text(list,"No notifications",muted:true);
        }
        catch (Exception ex) when(ex is ApiException or HttpRequestException) { Text(body,Error(ex),muted:true); }
    }
}
