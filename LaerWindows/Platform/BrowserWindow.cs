using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Laer.Windows.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Laer.Windows;

internal sealed class BrowserWindow : Window
{
    internal WebView2 Browser { get; } = new();
    private readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12) };
    private readonly Site? site;
    private readonly string profile;
    private TaskCompletionSource<Tokens?>? signIn;
    private string? state;
    private bool fallback;
    private bool checking;
    private bool allowClose;
    internal bool IsWebsiteSession { get; private set; }
    internal Action? AfterClosed;
    private TaskCompletionSource<SavedFile>? saving;
    private LocalStore? store;
    private string? resourceKey;
    private string? resourceName;
    private Uri? resolvedFile;
    private bool committing;

    internal BrowserWindow(Site? site, string profile)
    {
        this.site = site; this.profile = profile;
        Title = "Laer"; Width = 1040; Height = 760; MinWidth = 560; MinHeight = 400;
        var dock = new DockPanel();
        var bar = new DockPanel(); DockPanel.SetDock(bar, Dock.Top);
        bar.SetResourceReference(BackgroundProperty, "Chrome");
        var back = new Button { Content = "Back", Margin = new Thickness(6) };
        back.Click += (_, _) => { if (Browser.CoreWebView2?.CanGoBack == true) Browser.GoBack(); };
        bar.Children.Add(back);
        var useSite = new Button { Content = "Use website session", Margin = new Thickness(6), Visibility = site == null ? Visibility.Collapsed : Visibility.Visible };
        useSite.Click += async (_, _) => await Run(async () => { fallback = true; state = null; Browser.Source = site!.BaseUrl; await Task.CompletedTask; });
        DockPanel.SetDock(useSite, Dock.Right); bar.Children.Add(useSite); bar.Children.Add(notice);
        dock.Children.Add(bar); dock.Children.Add(Browser); Content = dock;
        Closing += (_, e) =>
        {
            if (signIn != null) { signIn.TrySetCanceled(); signIn = null; }
            if (IsWebsiteSession && !allowClose) { e.Cancel = true; Hide(); }
            saving?.TrySetCanceled();
        };
        Closed += (_, _) => { Browser.Dispose(); AfterClosed?.Invoke(); };
    }
    internal async Task Initialize()
    {
        var environment = await CoreWebView2Environment.CreateAsync(null, profile);
        await Browser.EnsureCoreWebView2Async(environment);
        var core = Browser.CoreWebView2;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var url) && url.Scheme == "https") core.Navigate(url.AbsoluteUri);
        };
        core.NavigationStarting += (_, e) =>
        {
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var url)) { e.Cancel = true; return; }
            if (saving != null && !saving.Task.IsCompleted && Site.IsInstitution(url))
            {
                var query = OAuth.ParseQuery(url.Query);
                if (query.TryGetValue("FileDownloadUrl", out var direct) && Uri.TryCreate(url, direct, out var file) && Site.IsInstitution(file) && file != url)
                {
                    e.Cancel = true; resolvedFile = file;
                    Dispatcher.BeginInvoke(() => core.Navigate(file.AbsoluteUri)); return;
                }
            }
            if (url.Scheme == "itsl-itslearning")
            {
                e.Cancel = true;
                _ = Run(async () =>
                {
                    var code = state == null ? null : OAuth.ReadCode(url, state);
                    state = null;
                    if (code == null) { notice.Text = "Sign-in could not be verified. Try again."; return; }
                    using var http = ApiClient.PublicHttp();
                    var tokens = await OAuth.Exchange(http, site!, code);
                    signIn?.TrySetResult(tokens); signIn = null; Hide();
                });
                return;
            }
            if (url.Scheme is not ("https" or "about") && !(site == null && url.Scheme == "file")) e.Cancel = true;
        };
        core.NavigationCompleted += (_, e) => _ = Run(async () =>
        {
            if (!e.IsSuccess) { notice.Text = "The page could not load. Check your connection."; return; }
            if (fallback && signIn != null && !checking && IsOnSite)
            {
                checking = true;
                try
                {
                    var data = await Read("/restapi/personal/courses/v4?PageIndex=0&PageSize=1", CancellationToken.None);
                    _ = data.Field("EntityArray").Array();
                    IsWebsiteSession = true; signIn.TrySetResult(null); signIn = null; Hide();
                }
                catch (ApiException) { /* Normal while the user is still on the login page. */ }
                finally { checking = false; }
            }
            if (saving != null && !saving.Task.IsCompleted && Browser.Source is { } current && Site.IsInstitution(current))
            {
                var found = await core.ExecuteScriptAsync("""
                    (() => {
                      const direct = new URL(location.href).searchParams.get('FileDownloadUrl');
                      if (direct) return new URL(direct, location.href).href;
                      for (const a of document.querySelectorAll('a[href]'))
                        if (/download/i.test(a.href) && !/PdfViewer/i.test(a.href)) return a.href;
                      return null;
                    })()
                    """);
                var text = JsonSerializer.Deserialize<string?>(found);
                if (Uri.TryCreate(text, UriKind.Absolute, out var file) && Site.IsInstitution(file) && resolvedFile != file)
                { resolvedFile = file; core.Navigate(file.AbsoluteUri); }
            }
        });
        core.WebResourceResponseReceived += async (_, e) =>
        {
            if (saving == null || saving.Task.IsCompleted || resolvedFile == null || committing ||
                e.Request.Uri != resolvedFile.AbsoluteUri || store == null) return;
            var type = e.Response.Headers.Contains("Content-Type") ? e.Response.Headers.GetHeader("Content-Type") : "";
            // A partial range or a download handled by DownloadStarting is not a complete document body.
            if (e.Response.StatusCode != 200 || type.Contains("html", StringComparison.OrdinalIgnoreCase) ||
                e.Response.Headers.Contains("Content-Disposition") && e.Response.Headers.GetHeader("Content-Disposition").StartsWith("attachment", StringComparison.OrdinalIgnoreCase)) return;
            committing = true;
            var staged = Path.Combine(store.Root, Guid.NewGuid().ToString("N") + ".download");
            try
            {
                using var body = await e.Response.GetContentAsync();
                if (body == null) throw new ApiException(Failure.Schema);
                await using (var file = File.Create(staged)) await body.CopyToAsync(file);
                var name = resourceName ?? "Material";
                if (!name.Contains('.') && type.Contains("pdf", StringComparison.OrdinalIgnoreCase)) name += ".pdf";
                saving.TrySetResult(await store.CommitFile(staged, resourceKey!, name, type));
            }
            catch (Exception ex) { saving.TrySetException(ex); }
            finally { if (File.Exists(staged)) File.Delete(staged); }
        };
        core.DownloadStarting += (_, e) =>
        {
            if (saving == null || saving.Task.IsCompleted || store == null) { e.Cancel = true; notice.Text = "Use Save from a material to keep a file."; return; }
            if (!Uri.TryCreate(e.DownloadOperation.Uri, UriKind.Absolute, out var source) || !Site.IsInstitution(source))
            { e.Cancel = true; saving.TrySetException(new ApiException(Failure.Forbidden)); return; }
            if (committing) { e.Cancel = true; return; }
            committing = true;
            var staged = Path.Combine(store.Root, Guid.NewGuid().ToString("N") + ".download");
            e.ResultFilePath = staged; e.Handled = true;
            var operation = e.DownloadOperation;
            operation.StateChanged += async (_, _) =>
            {
                if (operation.State == CoreWebView2DownloadState.InProgress) return;
                try
                {
                    if (operation.State == CoreWebView2DownloadState.Interrupted) throw new ApiException(Failure.Offline);
                    var name = Path.GetFileName(new Uri(operation.Uri).LocalPath);
                    var disposition = operation.ContentDisposition;
                    if (System.Net.Http.Headers.ContentDispositionHeaderValue.TryParse(disposition, out var header))
                        name = header.FileNameStar ?? header.FileName?.Trim('"') ?? name;
                    if (string.IsNullOrWhiteSpace(name) || !name.Contains('.')) name = resourceName ?? "Material";
                    var saved = await store.CommitFile(staged, resourceKey!, name, operation.MimeType);
                    saving.TrySetResult(saved);
                }
                catch (Exception ex) { saving.TrySetException(ex); }
                finally { if (File.Exists(staged)) File.Delete(staged); }
            };
        };
    }
    private bool IsOnSite => site != null && Uri.TryCreate(Browser.Source?.AbsoluteUri, UriKind.Absolute, out var url) &&
        url.Scheme == "https" && url.Host == site.BaseUrl.Host;
    internal Task<Tokens?> SignIn()
    {
        state = OAuth.NewState(); fallback = false;
        signIn = new(TaskCreationOptions.RunContinuationsAsynchronously);
        notice.Text = "Sign in with your institution. Laer never sees your password.";
        Browser.Source = OAuth.Authorize(site!, state);
        return signIn.Task;
    }
    internal async Task<JsonElement> Read(string path, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!IsOnSite || !path.StartsWith("/restapi/personal/", StringComparison.Ordinal) || path.Contains('\\') || path.Contains("..")) throw new ApiException(Failure.SignedOut);
        var encoded = JsonSerializer.Serialize(path);
        // Await the promise without a web-message bridge or access to browser cookies.
        var evaluated = await Browser.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new
        {
            expression = $$"""
                (async () => {
                  const r = await fetch({{encoded}}, { credentials: 'same-origin', redirect: 'error', headers: { Accept: 'application/json' } });
                  return JSON.stringify({ status: r.status, type: r.headers.get('content-type'), body: await r.text() });
                })()
                """,
            awaitPromise = true, returnByValue = true
        }));
        ct.ThrowIfCancellationRequested();
        var result = Json.Parse(evaluated).Field("result").Text("value");
        if (string.IsNullOrEmpty(result)) throw new ApiException(Failure.SignedOut);
        var response = Json.Parse(result);
        using var message = new HttpResponseMessage((System.Net.HttpStatusCode)response.Id("status"));
        message.Content = new StringContent(response.Text("body"));
        if (System.Net.Http.Headers.MediaTypeHeaderValue.TryParse(response.Text("type"), out var type)) message.Content.Headers.ContentType = type;
        return await ApiClient.ReadJson(message, ct);
    }
    internal async Task<SavedFile> SaveMaterial(ApiClient api, LocalStore local, JsonElement material, string key)
    {
        store = local; resourceKey = key; resourceName = material.Text("Title", "Material"); resolvedFile = null; committing = false;
        saving = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var uri = new Uri(site!.BaseUrl, "/LearningToolElement/ViewLearningToolElement.aspx?LearningToolElementId=" + material.Id("ElementId"));
        Browser.Source = api.CanWrite ? await api.Sso(uri) : uri;
        notice.Text = "Saving material. Some tools only open on the website.";
        return await saving.Task.WaitAsync(TimeSpan.FromSeconds(60));
    }
    internal void Navigate(Uri url) { notice.Text = ""; Browser.Source = url; Show(); Activate(); }
    internal async Task Clear()
    {
        if (Browser.CoreWebView2 != null) await Browser.CoreWebView2.Profile.ClearBrowsingDataAsync();
        IsWebsiteSession = false;
    }
    internal void Shutdown() { allowClose = true; Close(); }
    private async Task Run(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        { notice.Text = ex is ApiException api ? api.Message : "This page could not be opened. Try again."; }
    }
}
