using System.Security.Cryptography;
using System.Text.Json;

namespace Laer.Windows.Core;

public static class OAuth
{
    // Same public client as LaerCore/API/OAuth.swift. See docs/limitations.md before public release.
    public const string ClientId = "10ae9d30-1853-48ff-81cb-47b58a325685";
    public const string RedirectUri = "itsl-itslearning://login";
    public static string NewState() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
    public static Uri Authorize(Site site, string state) => new(site.BaseUrl,
        "/oauth2/authorize.aspx?" + Query(new Dictionary<string, string>
        { ["client_id"] = ClientId, ["state"] = state, ["response_type"] = "code", ["scope"] = "SCOPE", ["redirect_uri"] = RedirectUri }));
    public static string? ReadCode(Uri redirect, string expectedState)
    {
        if (redirect.Scheme != "itsl-itslearning" || redirect.Host != "login" || redirect.AbsolutePath is not ("" or "/")) return null;
        var query = ParseQuery(redirect.Query);
        if (!query.TryGetValue("state", out var state) || state != expectedState) return null;
        return query.TryGetValue("code", out var code) && !string.IsNullOrWhiteSpace(code) ? code : null;
    }
    public static string Query(IEnumerable<KeyValuePair<string, string>> fields) => string.Join("&", fields.Select(x =>
        $"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(x.Value)}"));
    public static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>();
        foreach (var pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            var key = Uri.UnescapeDataString(parts[0].Replace('+', ' '));
            if (!result.TryAdd(key, parts.Length == 2 ? Uri.UnescapeDataString(parts[1].Replace('+', ' ')) : ""))
                return []; // Duplicate state/code is ambiguous.
        }
        return result;
    }
    public static Task<Tokens> Exchange(HttpClient http, Site site, string code, CancellationToken ct = default) =>
        Post(http, site, new() { ["grant_type"] = "authorization_code", ["code"] = code, ["client_id"] = ClientId, ["redirect_uri"] = RedirectUri }, ct);
    public static Task<Tokens> Refresh(HttpClient http, Site site, string refresh, CancellationToken ct = default) =>
        Post(http, site, new() { ["grant_type"] = "refresh_token", ["refresh_token"] = refresh, ["client_id"] = ClientId }, ct);
    private static async Task<Tokens> Post(HttpClient http, Site site, Dictionary<string, string> fields, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(site.BaseUrl, "/restapi/oauth2/token"));
        request.Headers.Accept.ParseAdd("application/json");
        request.Content = new FormUrlEncodedContent(fields);
        using var response = await http.SendAsync(request, ct);
        if ((int)response.StatusCode == 400) throw new ApiException(Failure.SignedOut);
        var value = await ApiClient.ReadJson(response, ct);
        var access = value.Text("access_token"); var refresh = value.Text("refresh_token");
        if (string.IsNullOrEmpty(access) || string.IsNullOrEmpty(refresh)) throw new ApiException(Failure.Schema);
        var seconds = value.Id("expires_in");
        return new(access, refresh, DateTimeOffset.UtcNow.AddSeconds(seconds > 0 ? seconds : 3600));
    }
}
