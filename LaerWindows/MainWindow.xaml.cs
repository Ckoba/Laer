using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Laer.Windows.Core;
using Microsoft.Win32;

namespace Laer.Windows;

public partial class MainWindow : Window
{
    private ApiClient? api;
    private Account? account;
    private LocalStore? store;
    private BrowserWindow? session;
    private readonly List<BrowserWindow> browsers = [];
    private TokenVault vault => new(App.Root);
    private readonly Dictionary<string, JsonElement> cached = [];
    private List<JsonElement> courses = [];
    private List<JsonElement> tasks = [];
    private string section = "home";
    private string courseTab = "Plans";
    private JsonElement course;
    private long? folder;
    private readonly Stack<long?> folders = [];
    private long threadCursor;
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMinutes(5) };
    private int generation;
    private bool working;
    private string AccountPath => Path.Combine(App.Root, "account.json");

    public MainWindow()
    {
        InitializeComponent();
        InitializeShell();
        poll.Tick += async (_, _) => { if (IsVisible && !working) await Run(Refresh); };
        Activated += async (_, _) =>
        {
            ((App)Application.Current).ApplyTheme();
            if (account != null && !working && DateTimeOffset.UtcNow - lastRefresh > TimeSpan.FromMinutes(5)) await Run(Refresh);
        };
        Closed += (_, _) => { poll.Stop(); ResetViewer(); foreach (var browser in browsers.ToArray()) browser.Shutdown(); api?.Dispose(); };
    }
    private DateTimeOffset lastRefresh = DateTimeOffset.MinValue;
    private async void OnLoaded(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        if (App.Demo) { await StartDemo(); return; }
        if (File.Exists(AccountPath))
        {
            try
            {
                account = JsonSerializer.Deserialize<Account>(await File.ReadAllTextAsync(AccountPath));
                if (account == null || !Site.IsInstitution(account.Site.BaseUrl) || account.PersonId <= 0) { ShowWelcome(); return; }
                store = new(App.Root, account.Site.AccountKey(account.PersonId));
                var tokens = await vault.Load(account.Site);
                if (tokens != null) api = new(account.Site, tokens, renewed => vault.Save(account.Site, renewed));
                await LoadAccount();
                if (api == null) SetNotice("Sign in again. Saved content is still available.");
                return;
            }
            catch (Exception ex) when (ex is IOException or JsonException or ArgumentException) { account = null; }
        }
        ShowWelcome();
    });
    private void ShowWelcome()
    {
        PageTitle.Text = "Choose your institution"; Tabs.Children.Clear(); Body.Children.Clear();
        WelcomeOverlay.Visibility = Visibility.Visible; WelcomeError.Text = "";
    }
    private async Task SignIn()
    {
        if (account != null) { await SignOut(); }
        var institution = InstitutionField.Text.Trim();
        if (institution.Length == 0) { ShowWelcome(); InstitutionField.Focus(); return; }
        Site site;
        try { site = await ApiClient.Lookup(institution); }
        catch (HttpRequestException) { throw new ApiException(Failure.Offline); }
        var browser = NewBrowser(site, Path.Combine(App.Root, "web", site.Key));
        session = browser; browser.Show(); await browser.Initialize();
        Tokens? tokens;
        try { tokens = await browser.SignIn(); }
        catch (OperationCanceledException) { browser.Shutdown(); ShowWelcome(); return; }
        if (tokens == null)
        {
            api = new(site, browser.Read);
            // Website sessions cannot identify an account. Never mix their data with another session.
            account = new(site, 0, null); store = new(App.Root, Guid.NewGuid().ToString("N"));
            SetNotice("Website session: some features are unavailable. This session is not restored after restart.");
        }
        else
        {
            api = new(site, tokens, renewed => vault.Save(site, renewed));
            var person = await api.Get("/restapi/personal/person/v1");
            var id = checked((int)person.Id("PersonId")); if (id <= 0) throw new ApiException(Failure.Schema);
            account = new(site, id, person.Text("FullName"));
            store = new(App.Root, site.AccountKey(id));
            await vault.Save(site, tokens);
            await LocalStore.Atomic(AccountPath, JsonSerializer.SerializeToUtf8Bytes(account));
        }
        await LoadAccount(); poll.Start();
    }
    private async Task LoadAccount()
    {
        WelcomeOverlay.Visibility = Visibility.Collapsed;
        AccountLabel.Text = App.Demo ? "Demo · synthetic data" : account!.Site.Title;
        AccountButton.ToolTip = App.Demo ? "Demo account" : "Account";
        courses = (await Collection("courses", "/restapi/personal/courses/v4")).ToList();
        tasks = (await Collection("tasks", "/restapi/personal/tasks/v1")).ToList();
        PopulateCourses(); await Navigate("home"); poll.Start();
    }
    private void PopulateCourses()
    {
        BuildSidebar();
    }
    private async Task SignOut()
    {
        generation++; poll.Stop(); api?.Dispose(); api = null;
        if (!App.Demo && account != null) vault.Remove(account.Site);
        if (File.Exists(AccountPath)) File.Delete(AccountPath);
        foreach (var browser in browsers.ToArray()) { await browser.Clear(); browser.Shutdown(); }
        if (!App.Demo && account != null)
        {
            // Clear the persistent profile even when all website windows were already closed.
            var cleanup = NewBrowser(account.Site, Path.Combine(App.Root, "web", account.Site.Key));
            cleanup.Opacity = 0; cleanup.ShowActivated = false; cleanup.ShowInTaskbar = false;
            cleanup.Show();
            try { await cleanup.Initialize(); await cleanup.Clear(); }
            finally { cleanup.Shutdown(); }
        }
        browsers.Clear(); session = null; account = null; store = null; cached.Clear(); courses.Clear(); tasks.Clear();
        if (App.Demo) App.SetDemo(false);
        CourseList.Children.Clear(); AccountLabel.Text = ""; AccountButton.ToolTip = "Sign in";
        ResetViewer(); SetNotice(null); ShowWelcome();
    }
    private async Task Refresh()
    {
        if (account == null) return;
        courses = (await Collection("courses", "/restapi/personal/courses/v4")).ToList();
        tasks = (await Collection("tasks", "/restapi/personal/tasks/v1")).ToList();
        PopulateCourses(); await Navigate(section); lastRefresh = DateTimeOffset.UtcNow;
    }
    private async Task<IReadOnlyList<JsonElement>> Collection(string key, string path, string? envelope = null, bool nested = false)
    {
        if (App.Demo && cached.TryGetValue(key, out var fixture)) return fixture.Array();
        var old = store == null ? null : await store.Load(key);
        if (old != null) cached[key] = old.Data;
        if (api != null)
        {
            try
            {
                var result = await api.All(path, envelope, nested);
                if (!result.IsComplete) throw new ApiException(Failure.Incomplete);
                Contracts.ValidateCollection(key, result.Items);
                var data = JsonSerializer.SerializeToElement(result.Items);
                cached[key] = data;
                if (store != null) await store.Save(key, data);
                return result.Items;
            }
            catch (Exception ex) when (ex is ApiException or HttpRequestException or TaskCanceledException)
            { SetNotice(Error(ex)); if (old == null) throw; }
        }
        if (cached.TryGetValue(key, out var existing)) return existing.Array();
        throw new ApiException(Failure.Offline);
    }
    private async Task<JsonElement> Document(string key, string path)
    {
        if (App.Demo && cached.TryGetValue(key, out var fixture)) return fixture;
        var old = store == null ? null : await store.Load(key);
        if (old != null) cached[key] = old.Data;
        if (api != null)
        {
            try
            {
                var value = await api.Get(path);
                if (value.ValueKind != JsonValueKind.Object) throw new ApiException(Failure.Schema);
                Contracts.ValidateDocument(key, value);
                cached[key] = value; if (store != null) await store.Save(key, value); return value;
            }
            catch (Exception ex) when (ex is ApiException or HttpRequestException or TaskCanceledException)
            { SetNotice(Error(ex)); if (old == null) throw; }
        }
        if (cached.TryGetValue(key, out var existing)) return existing;
        throw new ApiException(Failure.Offline);
    }
    private async Task Navigate(string target)
    {
        if (account == null) { ShowWelcome(); return; }
        section = target; var version = ++generation;
        Body.Children.Clear(); Tabs.Children.Clear(); HeaderActions.Children.Clear();
        CalendarHost.Visibility = Visibility.Collapsed; PageScroll.Visibility = Visibility.Visible;
        MessagesHost.Visibility = Visibility.Collapsed; ScreenHeader.Visibility = Visibility.Visible;
        ReaderHost.Visibility = Visibility.Collapsed; Tabs.Visibility = Visibility.Visible;
        PageScroll.ScrollToTop(); UpdateNavigation();
        if (api != null && api.CanWrite) SetNotice(null);
        switch (target)
        {
            case "home":
                await Home(version);
                break;
            case "upcoming":
                PageTitle.Text = "Upcoming";
                Upcoming();
                break;
            case "calendar":
                await Calendar(version);
                break;
            case "notifications": await Notifications(version); break;
            case "messages":
                threadCursor = 0; PageTitle.Text = "Messages";
                MessagesHost.Visibility = Visibility.Visible; PageScroll.Visibility = Visibility.Collapsed; ScreenHeader.Visibility = Visibility.Collapsed;
                MessageHeaderActions.Children.Clear();
                var compose = IconButton("compose", "New message", Compose); compose.IsEnabled = api?.CanWrite == true;
                if (!compose.IsEnabled) compose.ToolTip = App.Demo ? "Unavailable in the demo" : "Sign in with OAuth to send messages";
                MessageHeaderActions.Children.Add(compose);
                if (MessageBody.Children.Count == 0) Text(MessageBody, "Choose a conversation", muted: true);
                await Threads(version); break;
            case "saved": await Saved(); break;
            case "course": await Course(version); break;
        }
    }
    private Task OpenCourse(JsonElement item) { course = item; courseTab = selectedCourseTabs.GetValueOrDefault(item.Id("CourseId"), "Plans"); folder = null; folders.Clear(); return Navigate("course"); }
    private async Task Course(int version)
    {
        var id = course.Id("CourseId"); PageTitle.Text = course.Text("FriendlyName", course.Text("Title"));
        foreach (var tab in CourseSections)
        {
            var button = AddButton(Tabs, tab, async () => { courseTab = tab; selectedCourseTabs[id] = tab; folder = null; folders.Clear(); await Navigate("course"); });
            button.Style = (Style)FindResource("TabButton"); button.Content = Icons.Label(Icons.Tab(tab), tab);
            if (tab == courseTab) button.SetResourceReference(BackgroundProperty, "Selection");
        }
        HeaderActions.Children.Add(IconButton("open", "Open on the website", () => Website(course)));
        if (courseTab == "Calendar") { await CourseCalendar(id); return; }
        if (courseTab == "Tasks")
        {
            var items = tasks.Where(x => x.Id("LocationId") == id).ToList();
            foreach (var task in items) TaskRow(Body, task);
            if (items.Count == 0) Text(Body, "No tasks", muted: true); return;
        }
        string key; string path; string? envelope = null; bool nested = false;
        switch (courseTab)
        {
            case "Materials":
                key = $"materials-{id}-{folder}";
                path = folder == null ? $"/restapi/personal/courses/{id}/resources/v1" : $"/restapi/personal/courses/{id}/folders/{folder}/resources/v1";
                envelope = "Resources";
                if (folders.Count > 0) AddButton(Body, "Back", async () => { folder = folders.Pop(); await Navigate("course"); }); break;
            case "Plans": key = $"plans-{id}"; path = $"/restapi/personal/course/{id}/plans/all/v1"; break;
            case "Participants": key = $"people-{id}"; path = $"/restapi/personal/courses/{id}/participants/v3"; nested = true; break;
            case "Grades":
                await Assessment(id); return;
            default: key = $"updates-{id}"; path = $"/restapi/personal/courses/{id}/bulletins/v1"; break;
        }
        var itemsList = await Collection(key, path, envelope, nested);
        if (generation != version) return;
        if (courseTab == "Plans") { Plans(itemsList); return; }
        foreach (var item in itemsList)
        {
            switch (courseTab)
            {
                case "Materials": MaterialRow(Body, item); break;
                case "Plans": Row(Body, item.Text("title", "Plan"), Json.DisplayDate(item.Date("start")), () => Plan(item)); break;
                case "Participants": Row(Body, item.Text("FullName", "Person"), item.Text("Role"), null); break;
                default: Row(Body, Truncate(Json.Plain(item.Text("Text")), 160), item.Field("PublishedBy").Text("FullName") + " · " + Json.DisplayDate(item.Date("PublishedDate")), () => Bulletin(item)); break;
            }
        }
        if (itemsList.Count == 0) Text(Body, "No items", muted: true);
    }
    private void TaskRow(Panel panel, JsonElement task) => TaskLine(panel, task);
    private async Task OpenTask(JsonElement task)
    {
        if (!new[] { "Assignment", "LearningToolElement" }.Contains(task.Text("ElementType"), StringComparer.OrdinalIgnoreCase)) { await Page(task); return; }
        var id = task.Id("ElementId"); if (id == 0) { await Website(task); return; }
        var value = await Document($"assignment-{id}", $"/restapi/personal/assignments/{id}/v1");
        var reader = OpenReader(value.Text("Title", task.Text("Title", "Task"))); Text(reader, Json.Plain(value.Text("Text")));
        Text(reader, Json.DisplayDate(value.Date("Deadline")), muted: true);
        if (value.Id("AnswerId") > 0 && account!.PersonId > 0)
        {
            AddButton(reader, "View answer", async () =>
            {
                var answer = await Document($"answer-{id}", $"/restapi/personal/assignments/{id}/answers/persons/{account.PersonId}/v1");
                Heading(reader, "Your answer"); Text(reader, Json.Plain(answer.Text("Text"))); Text(reader, Json.DisplayDate(answer.Date("Submitted")), muted: true);
            });
        }
        if (value.Flag("CanSubmitOrEditAnswer") == true)
            AddButton(reader, "Submit answer", () => Submit(id), primary: true, write: true);
        AddButton(reader, "Mark completed", async () =>
        {
            await RequireApi().Write(HttpMethod.Post, $"/restapi/personal/assignments/{id}/tasks/status/v1", new { PersonIds = new[] { account!.PersonId }, TaskStatus = "Completed" });
            await Refresh();
        }, write: true);
        AddButton(reader, "Website", () => Website(task));
    }
    private async Task Submit(long id)
    {
        var dialog = new TextDialog("Submit answer", "Answer text and optional file", "Submit", true, true) { Owner = this };
        if (dialog.ShowDialog() != true) return;
        var files = new List<JsonElement>(); var client = RequireApi();
        foreach (var file in dialog.Files) files.Add(await client.Upload("/restapi/personal/fileupload/temp/v1", file));
        await client.Write(HttpMethod.Post, $"/restapi/personal/assignments/{id}/answers/v1", new { Text = dialog.Value, Files = files });
        Text(ReaderBody, "Answer submitted");
    }
    private void MaterialRow(Panel panel, JsonElement material)
    {
        MaterialLine(panel, material);
    }
    private async Task Page(JsonElement material)
    {
        var id = material.Id("ElementId");
        var value = await Document($"page-{id}", $"/restapi/personal/pages/{id}/v1");
        var reader = OpenReader(value.Text("title", material.Text("Title", "Page")));
        if (value.Field("contentBlocks").ValueKind == JsonValueKind.Array)
            foreach (var block in value.Field("contentBlocks").Array().OrderBy(x => x.Id("order")))
            {
                if (block.Text("title") is { Length: > 0 } title) Heading(reader, title);
                Text(reader, Json.Plain(block.Text("processedText", block.Text("rawText"))));
                if (block.Field("files").ValueKind == JsonValueKind.Array)
                    foreach (var file in block.Field("files").Array()) AddButton(reader, file.Text("name", "Open file"), () => Website(file));
            }
        AddButton(reader, "Website", () => Website(material));
    }
    private Task Plan(JsonElement plan)
    {
        var reader = OpenReader(plan.Text("title", "Plan")); PlanContent(reader, plan); return Task.CompletedTask;
    }
    private async Task Bulletin(JsonElement bulletin)
    {
        var id = bulletin.Id("LightBulletinId"); OpenDetail("Update"); Text(Detail, Json.Plain(bulletin.Text("Text")));
        Text(Detail, bulletin.Field("PublishedBy").Text("FullName") + " · " + Json.DisplayDate(bulletin.Date("PublishedDate")), muted: true);
        if (bulletin.Id("ResourcesCount") > 0)
            foreach (var item in await Collection($"bulletin-files-{id}", $"/restapi/personal/courses/bulletins/{id}/elements/v1")) MaterialRow(Detail, item);
        if (bulletin.Flag("AllowComments") == true)
        {
            Heading(Detail, "Comments");
            foreach (var comment in await Collection($"comments-{id}", $"/restapi/personal/lightbulletins/{id}/comments/v1"))
            {
                Text(Detail, comment.Field("Author").Text("FullName"), muted: true); Text(Detail, Json.Plain(comment.Text("CommentText")));
                var commentId = comment.Id("Id");
                if (comment.Flag("AllowEditComment") == true) AddButton(Detail, "Edit", async () =>
                {
                    var edit = new TextDialog("Edit comment", "Comment", "Save", true, initial: comment.Text("CommentText")) { Owner = this };
                    if (edit.ShowDialog() == true) { await RequireApi().Write(HttpMethod.Put, $"/restapi/personal/lightbulletins/comments/{commentId}/v2", new { Comment = edit.Value }); await Bulletin(bulletin); }
                }, write: true);
                if (comment.Flag("AllowDeleteComment") == true) AddButton(Detail, "Delete", async () =>
                {
                    if (Confirm("Delete this comment?")) { await RequireApi().Write(HttpMethod.Delete, $"/restapi/personal/lightbulletins/comments/{commentId}/v1"); await Bulletin(bulletin); }
                }, write: true);
            }
            var input = Input(Detail, "Comment", multiline: true);
            AddButton(Detail, "Post comment", async () =>
            {
                if (string.IsNullOrWhiteSpace(input.Text)) return;
                await RequireApi().Write(HttpMethod.Post, $"/restapi/personal/lightbulletins/{id}/comments/v2", new { Comment = input.Text }); await Bulletin(bulletin);
            }, write: true);
        }
    }
    private async Task Assessment(long id)
    {
        var record = await Document($"assessment-{id}", $"/restapi/personal/course/{id}/assessmentrecord/assessmentrecordelements/v1");
        // These shapes vary by role. Keep unsupported fields visible on the website.
        var columns = record.Field("AssessmentRecordItems");
        var results = await Collection($"grades-{id}", $"/restapi/personal/course/{id}/assessmentrecord/assessmentrecordpersonitems/v1", nested: true);
        var mine = results.FirstOrDefault(x => x.Id("PersonId") == account!.PersonId).Field("PersonAssessments");
        var myResults = mine.ValueKind == JsonValueKind.Array ? mine.Array() : [];
        if (columns.ValueKind == JsonValueKind.Array)
            foreach (var column in columns.Array())
            {
                var result = myResults.FirstOrDefault(x => x.Id("GradeBookItemId") == column.Id("GradeBookItemId"));
                var score = result.Field("OverwrittenScore"); if (score.ValueKind != JsonValueKind.Number) score = result.Field("Score");
                var display = result.Flag("IsExempt") == true ? "Exempt" : result.Flag("AssessmentVisible") == false ? "Unavailable" : score.ValueKind == JsonValueKind.Number ? score.GetDouble().ToString(System.Globalization.CultureInfo.CurrentCulture) : "Unavailable";
                Row(Body, column.Text("Title", "Assessment"), display, () => Website(course));
            }
        else Text(Body, "Assessment details are available on the website.", muted: true);
        AddButton(Body, "Website", () => Website(course));
    }
    private async Task Notifications(int version)
    {
        PageTitle.Text = "Notifications";
        var list = await Collection("notifications", "/restapi/personal/notifications/v2");
        if (generation != version) return;
        foreach (var item in list)
        {
            Row(Body, Truncate(Json.Plain(item.Text("Text")), 160), Json.DisplayDate(item.Date("PublishedDate")) + (item.Flag("IsRead") == false ? " · Unread" : ""), () =>
            {
                OpenDetail("Notification"); Text(Detail, Json.Plain(item.Text("Text")));
                AddButton(Detail, "Mark read", async () =>
                {
                    await RequireApi().Write(HttpMethod.Put, "/restapi/personal/notifications/v2", new[] { new { NotificationId = item.Id("NotificationId"), IsRead = true } }); await Navigate("notifications");
                }, write: true);
                AddButton(Detail, "Website", () => Website(item)); return Task.CompletedTask;
            });
        }
        if (list.Count == 0) Text(Body, "No notifications", muted: true);
    }
    private async Task Threads(int version)
    {
        var data = await Document("threads-" + threadCursor, "/restapi/personal/instantmessages/messagethreads/v4?pageSize=20" + (threadCursor > 0 ? "&fromSortIndex=" + threadCursor : ""));
        if (generation != version) return;
        var list = data.Field("Threads").Field("EntityArray").Array();
        foreach (var item in list)
        {
            var name = item.Text("Name");
            if (name.Length == 0 && item.Field("Participants").ValueKind == JsonValueKind.Array)
                name = string.Join(", ", item.Field("Participants").Array().Select(x => x.Text("FullName")));
            ConversationRow(item, string.IsNullOrEmpty(name) ? "Conversation" : name);
        }
        if (data.Flag("HasMore") == true && list.Count > 0)
            AddButton(Body, "Load more", async () => { threadCursor = list[^1].Id("SortIndex"); await Threads(version); });
        if (list.Count == 0) Text(Body, "No messages", muted: true);
    }
    private async Task Thread(JsonElement thread)
    {
        var id = thread.Id("InstantMessageThreadId"); OpenDetail(thread.Text("Name", "Conversation"));
        var messagePanel = new StackPanel(); Detail.Children.Add(messagePanel);
        await ThreadMessages(messagePanel, id, null);
        var input = Input(Detail, "Message", multiline: true);
        AddButton(Detail, "Send", async () =>
        {
            if (string.IsNullOrWhiteSpace(input.Text)) return;
            await RequireApi().Write(HttpMethod.Post, "/restapi/personal/instantmessages/v2", new { Text = input.Text, InstantMessageThreadId = id });
            input.Clear(); await Thread(thread);
        }, primary: true, write: true);
    }
    private async Task ThreadMessages(Panel panel, long id, long? before)
    {
        var data = await Document($"messages-{id}-{before}", $"/restapi/personal/instantmessages/messagethreads/{id}/messages/v3?pageSize=50" + (before == null ? "" : "&fromId=" + before));
        var messages = data.Field("Messages").Field("EntityArray").Array();
        if (data.Flag("HasMore") == true && messages.Count > 0)
        {
            Button? older = null;
            older = AddButton(panel, "Show older", async () => { older!.Visibility = Visibility.Collapsed; var history = new StackPanel(); panel.Children.Insert(0, history); await ThreadMessages(history, id, messages.Min(x => x.Id("MessageId"))); });
        }
        foreach (var message in messages.OrderBy(x => x.Id("MessageId")))
        {
            var content = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
            var header = new DockPanel();
            if (message.Date("Created") is { } created) { var date = Label(created.ToLocalTime().ToString("g"), 11, true); DockPanel.SetDock(date, Dock.Right); header.Children.Add(date); }
            var author = Label(message.Text("CreatedByName"), 13); author.FontWeight = FontWeights.SemiBold; header.Children.Add(author); content.Children.Add(header);
            var body = Text(content, message.Flag("IsDeleted") == true ? "Message deleted" : Json.Plain(message.Text("Text"))); body.Margin = new Thickness(0,4,0,0);
            if (message.Text("AttachmentUrl").Length > 0)
                AddButton(content, message.Text("AttachmentName", "Open attachment"), () => Website(JsonSerializer.SerializeToElement(new { Url = message.Text("AttachmentUrl") })));
            var messageId = message.Id("MessageId");
            var menu = new ContextMenu();
            var star = new MenuItem { Header = message.Flag("IsStarred") == true ? "Unstar" : "Star", IsEnabled = api?.CanWrite == true };
            star.Click += async (_, _) => await Run(async () => { await RequireApi().Write(HttpMethod.Put, $"/restapi/personal/instantmessages/togglemessagestar/{messageId}/v1"); }); menu.Items.Add(star);
            if (message.Flag("CanDelete") == true)
            {
                var delete = new MenuItem { Header = "Delete", IsEnabled = api?.CanWrite == true };
                delete.Click += async (_, _) => await Run(async () => { if (Confirm("Delete this message?")) { await RequireApi().Write(HttpMethod.Delete, $"/restapi/personal/instantmessages/{messageId}/v1"); body.Text = "Message deleted"; } }); menu.Items.Add(delete);
            }
            content.ContextMenu = menu; panel.Children.Add(content);
        }
    }
    private Task Compose()
    {
        OpenDetail("New message"); var search = Input(Detail, "Recipient name"); var recipients = new ListBox { MaxHeight = 180 };
        AddButton(Detail, "Find recipients", async () =>
        {
            var value = await RequireApi().Get("/restapi/personal/instantmessages/recipients/search/v1?searchText=" + Uri.EscapeDataString(search.Text));
            recipients.Items.Clear(); foreach (var person in value.Array())
                if (person.Text("UserName").Length > 0 && person.Flag("CanReceive") != false)
                    recipients.Items.Add(new ListBoxItem { Content = person.Text("Label", person.Text("ShortLabel", "Person")), Tag = person });
        });
        Detail.Children.Add(recipients); var body = Input(Detail, "Message", multiline: true); string? attachment = null;
        var attachmentLabel = Text(Detail, "", muted: true);
        AddButton(Detail, "Attach file", () =>
        {
            var picker = new OpenFileDialog(); if (picker.ShowDialog(this) == true) { attachment = picker.FileName; attachmentLabel.Text = Path.GetFileName(attachment); } return Task.CompletedTask;
        });
        AddButton(Detail, "Send", async () =>
        {
            if (recipients.SelectedItem is not ListBoxItem selected || selected.Tag is not JsonElement person || string.IsNullOrWhiteSpace(body.Text))
            { SetNotice("Choose a recipient and enter a message."); return; }
            var personId = person.Id("Id"); if (personId == 0) { SetNotice("Choose a person as recipient."); return; }
            var ids = new List<string>();
            if (attachment != null)
            {
                var uploaded = await RequireApi().Upload("/restapi/personal/instantmessages/attachment/v1", attachment);
                foreach (var file in uploaded.Array())
                { var fileId = file.Text("m_Item1", file.Text("Item1")); if (fileId.Length == 0) throw new ApiException(Failure.Schema); ids.Add(fileId); }
            }
            await RequireApi().Write(HttpMethod.Post, "/restapi/personal/instantmessages/v2", new { Text = body.Text, ToPersonIds = new[] { personId }, FileIds = ids });
            MessageBody.Children.Clear(); ConversationTitle.Text = ""; await Navigate("messages");
        }, primary: true, write: true);
        return Task.CompletedTask;
    }
    private async Task SaveMaterial(JsonElement material)
    {
        if (store == null || account == null) return;
        var materialCourse = material.Id("CourseId") > 0 ? material.Id("CourseId") : course.Id("CourseId");
        var key = $"{materialCourse}-{material.Text("ElementType")}-{material.Id("ElementId")}";
        var existing = (await store.Files()).FirstOrDefault(x => x.Key == key);
        if (existing != null) { await OpenSaved(existing); return; }
        if (App.Demo) { await SaveDemoFile(key, material.Text("Title")); return; }
        var browser = NewBrowser(account.Site, Path.Combine(App.Root, "web", account.Site.Key));
        browser.Show(); await browser.Initialize();
        try { var saved = await browser.SaveMaterial(RequireApi(), store, material, key); await OpenSaved(saved); }
        finally { browser.Shutdown(); }
    }
    private async Task Saved()
    {
        PageTitle.Text = "Saved";
        if (store == null) return;
        var files = await store.Files();
        foreach (var file in files)
            Row(Body, file.Name, Json.DisplayDate(file.SavedAt), async () =>
            {
                OpenDetail(file.Name); AddButton(Detail, "Open", () => OpenSaved(file), primary: true);
                AddButton(Detail, "Show in folder", () =>
                { Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select,", store.FilePath(file) }, UseShellExecute = false }); return Task.CompletedTask; });
                AddButton(Detail, "Remove", async () => { if (Confirm("Remove this saved file?")) { var entry = viewerEntries.FirstOrDefault(x => x.Key == file.Key); if (entry != null) CloseViewerTab(entry); await store.RemoveFile(file); CloseViewer(); await Navigate("saved"); } });
                await Task.CompletedTask;
            });
        if (files.Count == 0) Text(Body, "No saved materials", muted: true);
    }
    private async Task OpenSaved(SavedFile file)
    {
        if (store == null) return;
        var path = store.FilePath(file);
        if (new[] { ".pdf", ".txt", ".md", ".csv", ".json", ".png", ".jpg", ".jpeg", ".gif", ".webp" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
        { await OpenFileTab(file); }
        else if (new[] { ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".odt", ".ods", ".odp", ".rtf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
        { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        else
        {
            OpenDetail(file.Name);
            Text(Detail, "This file is saved. Open its folder to choose an application.", muted: true);
            AddButton(Detail, "Show in folder", () =>
            { Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select,", path }, UseShellExecute = false }); return Task.CompletedTask; });
        }
    }
    private async Task Website(JsonElement item)
    {
        if (App.Demo) { SetNotice("Website actions are unavailable in the demo."); return; }
        if (account == null) return;
        var raw = item.Text("Url", item.Text("ContentUrl"));
        Uri target = account.Site.BaseUrl;
        if (raw.Length > 0 && Uri.TryCreate(account.Site.BaseUrl, raw, out var resolved) && resolved.Scheme == "https") target = resolved;
        else if (item.Id("ElementId") > 0) target = new(account.Site.BaseUrl, "/LearningToolElement/ViewLearningToolElement.aspx?LearningToolElementId=" + item.Id("ElementId"));
        else if (item.Id("CourseId") > 0) target = new(account.Site.BaseUrl, "/Course.aspx?CourseID=" + item.Id("CourseId"));
        var browser = NewBrowser(account.Site, Path.Combine(App.Root, "web", account.Site.Key));
        browser.Show(); await browser.Initialize();
        if (api?.CanWrite == true && target.Host == account.Site.BaseUrl.Host) target = await api.Sso(target);
        browser.Navigate(target);
    }
    private BrowserWindow NewBrowser(Site? site, string profile)
    {
        var browser = new BrowserWindow(site, profile) { Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner }; browsers.Add(browser); browser.AfterClosed = () => browsers.Remove(browser); return browser;
    }
    private ApiClient RequireApi() => api ?? throw new ApiException(Failure.SignedOut);
    private async void HomeClick(object sender, RoutedEventArgs e) => await Run(() => Navigate("home"));
    private async void SectionClick(object sender, RoutedEventArgs e) => await Run(() => Navigate((string)((Button)sender).Tag));
    private async void RefreshClick(object sender, RoutedEventArgs e) => await Run(Refresh);
    private void AccountClick(object sender, RoutedEventArgs e) => ShowAccountMenu();
    private void CloseDetailClick(object sender, RoutedEventArgs e) => CloseViewer();
    private void OpenDetail(string title)
    {
        DetailTitle.Text = title; Detail.Children.Clear();
        if (section == "messages") { ConversationTitle.Text = title; return; }
        viewerEntries.RemoveAll(x => x.Key == "_detail"); var entry = new ViewerEntry("_detail", title, DetailScroll); viewerEntries.Add(entry); ShowViewer(entry);
        var heading = Text(Detail, title, 18); heading.FontWeight = FontWeights.SemiBold;
    }
    private void SearchClick(object sender, RoutedEventArgs e) => Search();
    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.K && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { e.Handled = true; Search(); }
        else if (e.Key == Key.F5) { e.Handled = true; _ = Run(Refresh); }
        else if (e.Key == Key.S && Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { e.Handled = true; ToggleSidebarClick(this, new RoutedEventArgs()); }
        else if (e.Key == Key.Escape) { e.Handled = true; if (notificationsPopup?.IsOpen == true) notificationsPopup.IsOpen = false; else if (PaletteOverlay.Visibility == Visibility.Visible) ClosePalette(); else CloseViewer(); }
    }
    private void Search()
    {
        OpenPalette();
    }
    private static string Truncate(string text, int count) => text.Length > count ? text[..count] + "…" : text;
    private static bool Confirm(string text) => MessageBox.Show(text, "Laer", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK;
    private void SetNotice(string? text) { Notice.Text = text ?? ""; WelcomeError.Text = text ?? ""; Notice.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible; }
    private static string Error(Exception ex) => ex is ApiException api ? api.Message : ex is OperationCanceledException ? "The action was cancelled." : ex is TimeoutException ? "The action timed out. Check the website before trying again." : "The action failed. Saved content has been kept.";
    private async Task Run(Func<Task> action)
    {
        if (working) return;
        working = true;
        using var spinnerDelay = new CancellationTokenSource();
        _ = ShowSpinnerLater(spinnerDelay.Token);
        try { await action(); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { SetNotice(Error(ex)); }
        finally { spinnerDelay.Cancel(); working = false; Busy.Visibility = Visibility.Collapsed; }
    }
    private async Task ShowSpinnerLater(CancellationToken token)
    { try { await Task.Delay(180, token); Busy.Visibility = Visibility.Visible; } catch (OperationCanceledException) { } }
    private static TextBlock Text(Panel panel, string text, double size = 13, bool muted = false)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = FontWeights.Normal, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12), LineHeight = size * 1.45 };
        if (muted) block.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); panel.Children.Add(block); return block;
    }
    private static void Heading(Panel panel, string title)
    { var block = Text(panel, title, 15); block.FontWeight = FontWeights.SemiBold; block.Margin = new Thickness(0, 16, 0, 12); }
    private static TextBox Input(Panel panel, string label, bool multiline = false)
    {
        Text(panel, label, 12, true); var box = new TextBox { AcceptsReturn = multiline, TextWrapping = TextWrapping.Wrap, MinHeight = multiline ? 110 : 32, Margin = new Thickness(0, 0, 0, 12), VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        System.Windows.Automation.AutomationProperties.SetName(box, label); panel.Children.Add(box); return box;
    }
    private Button AddButton(Panel panel, string label, Func<Task> action, bool primary = false, bool write = false)
    {
        var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 4, 4), IsEnabled = !write || api?.CanWrite == true };
        if (write && api?.CanWrite != true) button.ToolTip = App.Demo ? "Unavailable in the demo" : "Sign in with OAuth to use this action";
        if (primary) button.Style = (Style)FindResource("Primary");
        button.Click += async (_, _) =>
        {
            if (working) return;
            button.IsEnabled = false;
            try { await Run(action); }
            finally { button.IsEnabled = !write || api?.CanWrite == true; }
        };
        panel.Children.Add(button); return button;
    }
    private void Row(Panel panel, string title, string subtitle, Func<Task>? action)
    {
        var content = new StackPanel();
        var titleBlock = Text(content, title); titleBlock.Margin = new Thickness(0); titleBlock.FontWeight = FontWeights.Medium;
        if (subtitle.Length > 0) { var sub = Text(content, subtitle, 12, true); sub.Margin = new Thickness(0, 4, 0, 0); }
        DividedRow(panel, content, action, title);
    }
}
