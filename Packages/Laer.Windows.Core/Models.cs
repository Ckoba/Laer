using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Laer.Windows.Core;

public sealed record Site(string ShortName, string Title, Uri BaseUrl, int CustomerId)
{
    public static bool IsInstitution(Uri url) => url.Scheme == "https" && url.IsDefaultPort &&
        string.IsNullOrEmpty(url.UserInfo) && url.Host.EndsWith(".itslearning.com", StringComparison.OrdinalIgnoreCase);
    public string Key => Hash(BaseUrl.GetLeftPart(UriPartial.Authority));
    public string AccountKey(int personId) => Hash($"{BaseUrl.GetLeftPart(UriPartial.Authority)}:{personId}");
    public static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}

public sealed record Tokens(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt);
public sealed record Account(Site Site, int PersonId, string? FullName);
public sealed record PageResult(IReadOnlyList<JsonElement> Items, bool IsComplete);
public sealed record Snapshot(DateTimeOffset SavedAt, bool IsComplete, JsonElement Data);
public sealed record SavedFile(string Key, string Name, string DiskName, string? ContentType, DateTimeOffset SavedAt);

public enum Failure { SignedOut, Forbidden, NotFound, Throttled, Server, Schema, Offline, Refused, Incomplete }
public sealed class ApiException(Failure failure) : Exception(failure switch
{
    Failure.SignedOut => "Sign in again. Saved content is still available.",
    Failure.Forbidden => "Your account cannot access this item.",
    Failure.NotFound => "This item is unavailable.",
    Failure.Throttled => "Too many requests. Try again later.",
    Failure.Server => "itslearning is unavailable. Try again later.",
    Failure.Offline => "Cannot connect. Saved content is still available.",
    Failure.Refused => "itslearning refused the change. Check the website before trying again.",
    Failure.Incomplete => "The listing is incomplete. Saved content has been kept.",
    _ => "The response has an unexpected format. Saved content has been kept."
})
{
    public Failure Failure { get; } = failure;
}

public static class Json
{
    public static JsonElement Parse(string value) { using var doc = JsonDocument.Parse(value); return doc.RootElement.Clone(); }
    public static JsonElement Field(this JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object) return default;
        foreach (var prop in value.EnumerateObject())
            if (prop.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) return prop.Value;
        return default;
    }
    public static string Text(this JsonElement value, string name, string fallback = "") =>
        value.Field(name) is var field && field.ValueKind == JsonValueKind.String ? field.GetString() ?? fallback : fallback;
    public static long Id(this JsonElement value, string name) =>
        value.Field(name) is var field && field.ValueKind == JsonValueKind.Number && field.TryGetInt64(out var id) ? id : 0;
    public static bool? Flag(this JsonElement value, string name) => value.Field(name).ValueKind switch
    { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
    public static List<JsonElement> Array(this JsonElement value) => value.ValueKind == JsonValueKind.Array
        ? value.EnumerateArray().Select(x => x.Clone()).ToList() : throw new ApiException(Failure.Schema);
    public static DateTimeOffset? Date(this JsonElement value, string name) => ParseDate(value.Text(name));
    public static DateTimeOffset? ParseDate(string raw)
    {
        var match = Regex.Match(raw, @"^/Date\((-?\d+)(?:[+-]\d{4})?\)/$");
        if (match.Success && long.TryParse(match.Groups[1].Value, out var ms))
        { try { return DateTimeOffset.FromUnixTimeMilliseconds(ms); } catch (ArgumentOutOfRangeException) { return null; } }
        return DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;
    }
    public static string Plain(string text)
    {
        text = Regex.Replace(text, @"<(script|style)\b[^>]*>[\s\S]*?</\1>", "", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<(br|/p|/div|/li)[^>]*>", "\n", RegexOptions.IgnoreCase);
        return WebUtility.HtmlDecode(Regex.Replace(text, "<[^>]+>", "")).Trim();
    }
    public static string DisplayDate(DateTimeOffset? date) => date?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) ?? "Date unavailable";
}
