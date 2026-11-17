using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Laer.Windows.Core;

public sealed class ApiClient : IDisposable
{
    private readonly HttpClient http;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly Func<Tokens, Task>? persist;
    private Tokens tokens;
    private readonly Func<string, CancellationToken, Task<JsonElement>>? websiteRead;
    public bool CanWrite => websiteRead == null;
    public Site Site { get; }
    public ApiClient(Site site, Tokens tokens, Func<Tokens, Task>? persist = null, HttpMessageHandler? handler = null)
    {
        if (!Site.IsInstitution(site.BaseUrl)) throw new ArgumentException("Invalid institution.");
        Site = site; this.tokens = tokens; this.persist = persist;
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(45) };
    }
    public static HttpClient PublicHttp() => new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(30) };
    public ApiClient(Site site, Func<string, CancellationToken, Task<JsonElement>> websiteRead)
        : this(site, new Tokens("", "", DateTimeOffset.MaxValue)) { this.websiteRead = websiteRead; }
    public static async Task<Site> Lookup(string shortName, CancellationToken ct = default)
    {
        shortName = shortName.Trim();
        if (shortName.Length is < 1 or > 100) throw new ApiException(Failure.NotFound);
        using var http = PublicHttp();
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://www.itslearning.com/restapi/sites/shortnames/" + Uri.EscapeDataString(shortName) + "/v1");
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await http.SendAsync(request, ct);
        var data = await ReadJson(response, ct);
        if (!Uri.TryCreate(data.Text("BaseUrl"), UriKind.Absolute, out var origin) || !Site.IsInstitution(origin)) throw new ApiException(Failure.Schema);
        return new(data.Text("ShortName", shortName), data.Text("Title", shortName), new(origin.GetLeftPart(UriPartial.Authority)), checked((int)data.Id("CustomerId")));
    }
    public async Task<JsonElement> Get(string path, CancellationToken ct = default)
    {
        if (websiteRead != null) return await websiteRead(path, ct);
        // GETs may recover one expired access token. Account-changing requests are never replayed.
        var usedToken = await AccessToken(ct);
        using var first = await Send(HttpMethod.Get, path, null, usedToken, ct);
        if (first.StatusCode != HttpStatusCode.Unauthorized) return await ReadJson(first, ct);
        await Renew(usedToken, ct);
        using var second = await Send(HttpMethod.Get, path, null, await AccessToken(ct), ct);
        return await ReadJson(second, ct);
    }
    public async Task<JsonElement> Write(HttpMethod method, string path, object? body = null, CancellationToken ct = default)
    {
        if (!CanWrite) throw new ApiException(Failure.Forbidden);
        var access = await AccessToken(ct);
        using var content = body == null ? null : new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var response = await Send(method, path, content, access, ct);
        ValidateStatus(response);
        var type = response.Content.Headers.ContentType?.MediaType ?? "";
        if (type.Contains("html", StringComparison.OrdinalIgnoreCase)) throw new ApiException(Failure.SignedOut);
        var bytes = await response.Content.ReadAsByteArrayAsync(ct);
        if (bytes.Length == 0) return Json.Parse("{}");
        if (!type.Contains("json", StringComparison.OrdinalIgnoreCase)) throw new ApiException(Failure.Schema);
        try { using var doc = JsonDocument.Parse(bytes); return doc.RootElement.Clone(); }
        catch (JsonException) { throw new ApiException(Failure.Schema); }
    }
    public async Task<JsonElement> Upload(string path, string file, CancellationToken ct = default)
    {
        if (!CanWrite) throw new ApiException(Failure.Forbidden);
        var access = await AccessToken(ct);
        using var content = new MultipartFormDataContent();
        using var stream = File.OpenRead(file);
        var part = new StreamContent(stream); part.Headers.ContentType = new("application/octet-stream");
        content.Add(part, "file", Path.GetFileName(file).Replace('"', '_').Replace('\r', '_').Replace('\n', '_'));
        using var response = await Send(HttpMethod.Post, path, content, access, ct);
        return await ReadJson(response, ct);
    }
    private async Task<HttpResponseMessage> Send(HttpMethod method, string path, HttpContent? body, string access, CancellationToken ct)
    {
        if (!path.StartsWith("/restapi/personal/", StringComparison.Ordinal) || path.Contains('\\') || path.StartsWith("//")) throw new ArgumentException("Invalid API path.");
        var uri = new Uri(Site.BaseUrl, path);
        if (uri.GetLeftPart(UriPartial.Authority) != Site.BaseUrl.GetLeftPart(UriPartial.Authority)) throw new ArgumentException("Invalid API origin.");
        using var request = new HttpRequestMessage(method, uri) { Content = body };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Authorization = new("Bearer", access);
        try { return await http.SendAsync(request, ct); }
        catch (HttpRequestException) { throw new ApiException(Failure.Offline); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new ApiException(Failure.Offline); }
    }
    private async Task<string> AccessToken(CancellationToken ct)
    {
        if (tokens.ExpiresAt < DateTimeOffset.UtcNow.AddSeconds(30)) await Renew(tokens.AccessToken, ct);
        return tokens.AccessToken;
    }
    private async Task Renew(string previous, CancellationToken ct)
    {
        await refreshGate.WaitAsync(ct);
        try
        {
            if (tokens.AccessToken != previous) return;
            tokens = await OAuth.Refresh(http, Site, tokens.RefreshToken, ct);
            if (persist != null) await persist(tokens);
        }
        finally { refreshGate.Release(); }
    }
    public async Task<PageResult> All(string path, string? envelope = null, bool nestedPaging = false, CancellationToken ct = default)
    {
        var result = new List<JsonElement>();
        for (var index = 0; index < 50; index++)
        {
            var prefix = nestedPaging ? "paging." : "";
            var data = await Get(path + (path.Contains('?') ? "&" : "?") + $"{prefix}PageIndex={index}&{prefix}PageSize=100", ct);
            if (envelope != null) data = data.Field(envelope);
            var items = data.Field("EntityArray").Array();
            result.AddRange(items);
            var total = data.Field("Total"); var size = data.Id("PageSize");
            if (total.ValueKind == JsonValueKind.Number && total.TryGetInt32(out var n))
            {
                if (n < 0) throw new ApiException(Failure.Schema);
                if (result.Count >= n) return new(result, true);
                if (items.Count == 0) return new(result, false);
            }
            else if (items.Count == 0 || items.Count < (size > 0 ? size : 100)) return new(result, true);
        }
        return new(result, false);
    }
    public async Task<Uri> Sso(Uri target, CancellationToken ct = default)
    {
        if (target.Scheme != "https" || target.Host != Site.BaseUrl.Host) throw new ArgumentException("Invalid site link.");
        var value = await Get("/restapi/personal/sso/url/v1?url=" + Uri.EscapeDataString(target.AbsoluteUri), ct);
        if (!Uri.TryCreate(value.Text("Url"), UriKind.Absolute, out var signed) || !Site.IsInstitution(signed)) throw new ApiException(Failure.Schema);
        return signed;
    }
    public static void ValidateStatus(HttpResponseMessage response)
    {
        var status = (int)response.StatusCode;
        if (status is >= 200 and < 300) return;
        throw new ApiException(status switch
        {
            >= 300 and < 400 or 401 => Failure.SignedOut, 403 => Failure.Forbidden,
            404 => Failure.NotFound, 429 => Failure.Throttled, >= 500 => Failure.Server,
            400 or 409 or 422 => Failure.Refused, _ => Failure.Schema
        });
    }
    public static async Task<JsonElement> ReadJson(HttpResponseMessage response, CancellationToken ct = default)
    {
        ValidateStatus(response);
        var type = response.Content.Headers.ContentType?.MediaType ?? "";
        if (type.Contains("html", StringComparison.OrdinalIgnoreCase)) throw new ApiException(Failure.SignedOut);
        if (!type.Contains("json", StringComparison.OrdinalIgnoreCase)) throw new ApiException(Failure.Schema);
        try
        {
            using var doc = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            return doc.RootElement.Clone();
        }
        catch (JsonException) { throw new ApiException(Failure.Schema); }
    }
    public void Dispose() { http.Dispose(); refreshGate.Dispose(); }
}
