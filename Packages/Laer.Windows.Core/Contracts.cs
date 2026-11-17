using System.Text.Json;

namespace Laer.Windows.Core;

// Match the Swift model's required identity fields before replacing a last-good snapshot.
public static class Contracts
{
    public static void ValidateCollection(string key, IReadOnlyList<JsonElement> items)
    {
        var id = key switch
        {
            "courses" => "CourseId", "tasks" => "TaskId", "calendar" => "EventId", "notifications" => "NotificationId",
            _ when key.StartsWith("materials-") || key.StartsWith("bulletin-files-") => "ElementId",
            _ when key.StartsWith("plans-") => "id", _ when key.StartsWith("people-") || key.StartsWith("grades-") => "PersonId",
            _ when key.StartsWith("updates-") => "LightBulletinId", _ when key.StartsWith("comments-") => "Id", _ => null
        };
        foreach (var item in items)
        {
            if (item.ValueKind != JsonValueKind.Object || id != null && item.Id(id) <= 0) throw new ApiException(Failure.Schema);
            if (key is "courses" or "tasks" && item.Field("Title").ValueKind != JsonValueKind.String) throw new ApiException(Failure.Schema);
            if (key.StartsWith("materials-") && (item.Field("ElementType").ValueKind != JsonValueKind.String || item.Field("Title").ValueKind != JsonValueKind.String)) throw new ApiException(Failure.Schema);
        }
    }
    public static void ValidateDocument(string key, JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new ApiException(Failure.Schema);
        if (key.StartsWith("assignment-") && value.Id("ElementId") <= 0 ||
            key.StartsWith("page-") && value.Id("elementId") <= 0 ||
            key.StartsWith("answer-") && value.Id("AnswerId") <= 0) throw new ApiException(Failure.Schema);
        if (key.StartsWith("threads-")) ValidateEnvelope(value.Field("Threads"), "InstantMessageThreadId");
        if (key.StartsWith("messages-")) ValidateEnvelope(value.Field("Messages"), "MessageId");
    }
    private static void ValidateEnvelope(JsonElement envelope, string id)
    {
        foreach (var item in envelope.Field("EntityArray").Array()) if (item.Id(id) <= 0) throw new ApiException(Failure.Schema);
    }
}
