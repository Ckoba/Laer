using System.Text.Json;
using System.Text.Json.Nodes;

namespace Laer.Windows.Core;

public sealed class LocalStore
{
    public string Root { get; }
    public string FilesRoot => Path.Combine(Root, "files");
    private readonly SemaphoreSlim fileGate = new(1, 1);
    public LocalStore(string appRoot, string accountKey)
    {
        Root = Path.Combine(appRoot, "accounts", Site.Hash(accountKey));
        Directory.CreateDirectory(FilesRoot);
    }
    private string SnapshotPath(string key) => Path.Combine(Root, Site.Hash(key) + ".json");
    public async Task<Snapshot?> Load(string key)
    {
        try { return JsonSerializer.Deserialize<Snapshot>(await File.ReadAllTextAsync(SnapshotPath(key))); }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }
    public Task Save(string key, JsonElement data, bool complete = true) =>
        Atomic(SnapshotPath(key), JsonSerializer.SerializeToUtf8Bytes(new Snapshot(DateTimeOffset.UtcNow, complete, CacheSafe(data))));
    public static JsonElement CacheSafe(JsonElement data)
    {
        var node = JsonNode.Parse(data.GetRawText());
        Scrub(node);
        return JsonSerializer.SerializeToElement(node);
    }
    private static void Scrub(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            foreach (var key in obj.Select(p => p.Key).ToArray())
            {
                if (key.Contains("token", StringComparison.OrdinalIgnoreCase) || key.Contains("cookie", StringComparison.OrdinalIgnoreCase) ||
                    key.Contains("signed", StringComparison.OrdinalIgnoreCase)) { obj.Remove(key); continue; }
                if (obj[key] is JsonValue value && value.TryGetValue<string>(out var text))
                {
                    if (Uri.TryCreate(text, UriKind.Absolute, out var url) && url.Scheme is "http" or "https" && !string.IsNullOrEmpty(url.Query))
                    { obj.Remove(key); continue; }
                    // Native views already render plain text. Do not save signed links hidden in HTML attributes.
                    if (text.Contains('<')) text = Json.Plain(text);
                    text = System.Text.RegularExpressions.Regex.Replace(text, @"https?://[^\s<>""']+\?[^\s<>""']+", "[Link available online]");
                    obj[key] = text;
                }
                Scrub(obj[key]);
            }
        }
        else if (node is JsonArray array) foreach (var item in array) Scrub(item);
    }
    public async Task<List<SavedFile>> Files()
    {
        try
        {
            var files = JsonSerializer.Deserialize<List<SavedFile>>(await File.ReadAllTextAsync(Path.Combine(Root, "files.json"))) ?? [];
            return files.Where(x => x.DiskName == Path.GetFileName(x.DiskName) && File.Exists(Path.Combine(FilesRoot, x.DiskName))).ToList();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return []; }
    }
    public async Task<SavedFile> CommitFile(string staged, string key, string name, string? contentType)
    {
        await ValidateDocument(staged, contentType);
        await fileGate.WaitAsync();
        try
        {
            name = SafeName(name);
            var entry = new SavedFile(key, name, Site.Hash(key) + "-" + Guid.NewGuid().ToString("N") + Path.GetExtension(name), contentType, DateTimeOffset.UtcNow);
            var files = await Files(); var previous = files.FirstOrDefault(x => x.Key == key);
            var target = Path.Combine(FilesRoot, entry.DiskName);
            File.Copy(staged, target, false);
            files.RemoveAll(x => x.Key == key); files.Add(entry);
            try { await Atomic(Path.Combine(Root, "files.json"), JsonSerializer.SerializeToUtf8Bytes(files)); }
            catch { File.Delete(target); throw; }
            // A replaced file remains on disk until an explicit Remove, so open viewers stay valid.
            return entry;
        }
        finally { fileGate.Release(); }
    }
    public async Task RemoveFile(SavedFile file)
    {
        await fileGate.WaitAsync();
        try
        {
            var files = await Files(); files.RemoveAll(x => x.Key == file.Key);
            await Atomic(Path.Combine(Root, "files.json"), JsonSerializer.SerializeToUtf8Bytes(files));
            foreach (var path in Directory.EnumerateFiles(FilesRoot, Site.Hash(file.Key) + "-*")) File.Delete(path);
        }
        finally { fileGate.Release(); }
    }
    public string FilePath(SavedFile file)
    {
        if (file.DiskName != Path.GetFileName(file.DiskName)) throw new IOException("Invalid saved file.");
        return Path.Combine(FilesRoot, file.DiskName);
    }
    public static string SafeName(string name)
    {
        name = name.Replace('\\', '/').Split('/').LastOrDefault() ?? "Material";
        var invalid = Path.GetInvalidFileNameChars().Concat("<>:\"/\\|?*".ToCharArray()).ToHashSet();
        name = new string(name.Select(c => invalid.Contains(c) || char.IsControl(c) ? '_' : c).ToArray()).Trim(' ', '.');
        if (name.Length > 150) name = name[..140] + Path.GetExtension(name)[..Math.Min(Path.GetExtension(name).Length, 10)];
        var stem = name.Split('.')[0];
        if (new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(stem, StringComparer.OrdinalIgnoreCase)) name = "_" + name;
        return string.IsNullOrWhiteSpace(name) ? "Material" : name;
    }
    public static async Task ValidateDocument(string path, string? contentType)
    {
        if (new FileInfo(path).Length == 0) throw new ApiException(Failure.Schema);
        if (contentType?.Contains("html", StringComparison.OrdinalIgnoreCase) == true || contentType?.Contains("json", StringComparison.OrdinalIgnoreCase) == true)
            throw new ApiException(Failure.SignedOut);
        using var stream = File.OpenRead(path);
        var buffer = new byte[1024]; var count = await stream.ReadAsync(buffer);
        var start = System.Text.Encoding.UTF8.GetString(buffer, 0, count).TrimStart('\uFEFF', ' ', '\r', '\n', '\t');
        if (start.StartsWith("<!doctype html", StringComparison.OrdinalIgnoreCase) || start.StartsWith("<html", StringComparison.OrdinalIgnoreCase))
            throw new ApiException(Failure.SignedOut);
    }
    public static async Task Atomic(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { await File.WriteAllBytesAsync(temp, data); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
