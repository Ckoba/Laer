using System.Text;
using System.Text.Json;
using Laer.Windows.Core;

namespace Laer.Windows;

public partial class MainWindow
{
    private async Task StartDemo()
    {
        ResetViewer();
        App.SetDemo(true); api?.Dispose(); api = null;
        account = new(new Site("example", "Example institution", new Uri("https://example.itslearning.com"), 1), 1001, "Example student");
        store = new(App.Root, "synthetic-demo"); cached.Clear();
        void Seed(string key, string json) => cached[key] = Json.Parse(json);
        Seed("courses", """
            [{"CourseId":101,"Title":"Mathematics","FriendlyName":"Mathematics","CourseCode":"MATH 101"},
             {"CourseId":102,"Title":"Design and technology","FriendlyName":"Design and technology","CourseCode":"DES 201"},
             {"CourseId":103,"Title":"Literature","FriendlyName":"Literature","CourseCode":"LIT 101"}]
            """);
        cached["tasks"] = JsonSerializer.SerializeToElement(new[]
        {
            new { TaskId=301, Title="Problem set: functions", ElementId=501, ElementType="Assignment", LocationId=101, LocationTitle="Mathematics", Status="NotStarted", Deadline=DateTimeOffset.Now.AddDays(2) },
            new { TaskId=302, Title="Design journal", ElementId=502, ElementType="Assignment", LocationId=102, LocationTitle="Design and technology", Status="InProgress", Deadline=DateTimeOffset.Now.AddDays(4) }
        });
        cached["calendar"] = JsonSerializer.SerializeToElement(new[]
        {
            new { EventId=401, EventTitle="Functions workshop", Description="Bring your notes and problem set.", LocationTitle="Mathematics", FromDate=DateTimeOffset.Now.AddDays(1), ToDate=DateTimeOffset.Now.AddDays(1).AddHours(1) },
            new { EventId=402, EventTitle="Studio review", Description="Review the first round of prototypes.", LocationTitle="Design and technology", FromDate=DateTimeOffset.Now.AddDays(2), ToDate=DateTimeOffset.Now.AddDays(2).AddHours(2) }
        });
        foreach (var id in new[] { 101, 102, 103 })
        {
            Seed($"materials-{id}-", """
                [{"ElementId":701,"ElementType":"Folder","Title":"Week 1"},
                 {"ElementId":702,"ElementType":"LearningToolElement","Title":"Lecture notes.pdf"},
                 {"ElementId":703,"ElementType":"Page","Title":"Getting started"}]
                """);
            Seed($"materials-{id}-701", """[{"ElementId":704,"ElementType":"LearningToolElement","Title":"Workshop guide.pdf"}]""");
            Seed($"plans-{id}", """
                [{"id":601,"title":"Week 1: foundations","displayDescription":"<p>Review the introductory material before the workshop.</p>","elements":[{"id":702,"title":"Lecture notes.pdf","isResource":true}]}]
                """);
            Seed($"updates-{id}", """
                [{"LightBulletinId":801,"Text":"<p>The workshop notes are ready in Materials.</p>","PublishedBy":{"FullName":"Example teacher"},"AllowComments":true,"ResourcesCount":0}]
                """);
            Seed($"people-{id}", """[{"PersonId":2001,"FullName":"Example teacher","Role":"Teacher"},{"PersonId":1001,"FullName":"Example student","Role":"Student"}]""");
            Seed($"assessment-{id}", """{"AssessmentRecordItems":[{"GradeBookItemId":1,"Title":"First reflection"},{"GradeBookItemId":2,"Title":"Workshop participation"}]}""");
            Seed($"grades-{id}", """[{"PersonId":1001,"PersonAssessments":[{"GradeBookItemId":1,"Score":8,"AssessmentVisible":true},{"GradeBookItemId":2,"Score":9,"AssessmentVisible":true}]}]""");
            var titles = id switch { 101 => ("Functions and graphs", "Working with equations"), 102 => ("From sketch to prototype", "Materials and making"), _ => ("Reading closely", "Voice and perspective") };
            cached[$"plans-{id}"] = JsonSerializer.SerializeToElement(new[] {
                new { id=id*10+1, title=titles.Item1, displayDescription="<p>Read the lecture notes before the workshop. Bring one question to discuss.</p>", start=DateTimeOffset.Now.AddDays(id-101+1).Date.AddHours(9), stop=DateTimeOffset.Now.AddDays(id-101+1).Date.AddHours(11), courseId=id, elements=new[]{new{id=702,title="Lecture notes.pdf",isResource=true},new{id=704,title="Workshop guide.pdf",isResource=true}} },
                new { id=id*10+2, title=titles.Item2, displayDescription="<p>Exercises and discussion.</p>", start=DateTimeOffset.Now.AddDays(8).Date.AddHours(9), stop=DateTimeOffset.Now.AddDays(8).Date.AddHours(11), courseId=id, elements=new[]{new{id=702,title="Lecture notes.pdf",isResource=true}} }
            });
            cached[$"course-calendar-{id}"] = cached["calendar"];
        }
        Seed("comments-801", """[{"Id":901,"Author":{"FullName":"Example student"},"CommentText":"Thank you for the notes.","AllowEditComment":false,"AllowDeleteComment":false}]""");
        Seed("page-703", """{"elementId":703,"title":"Getting started","contentBlocks":[{"contentBlockId":1,"title":"Before the workshop","processedText":"<p>Read the lecture notes and bring one question.</p>","order":1}]}""");
        foreach (var id in new[] { 501, 502 }) Seed($"assignment-{id}", """{"ElementId":501,"Title":"Your task","Text":"<p>Complete the exercises and explain your approach.</p>","CanSubmitOrEditAnswer":true,"AnswerId":0}""");
        Seed("notifications", """[{"NotificationId":1101,"Text":"New workshop notes are available.","IsRead":false}]""");
        Seed("threads-0", """{"Threads":{"EntityArray":[{"InstantMessageThreadId":1201,"Name":"Workshop group","LastMessage":{"MessageId":1301,"Text":"See you at the workshop."},"LastReadInstantMessageId":1300,"SortIndex":1}]},"HasMore":false}""");
        Seed("messages-1201-", """{"Messages":{"EntityArray":[{"MessageId":1301,"CreatedByName":"Example teacher","Text":"See you at the workshop.","CanDelete":false}]},"HasMore":false}""");
        await LoadAccount();
    }
    private async Task SaveDemoFile(string key, string title)
    {
        if (store == null) return;
        // A valid one-page PDF generated locally; no account or external download is needed.
        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length 58 >>\nstream\nBT /F1 20 Tf 72 700 Td (Laer - example lecture notes) Tj ET\nendstream"
        };
        var pdf = new StringBuilder("%PDF-1.4\n"); var offsets = new List<int> { 0 };
        for (var i = 0; i < objects.Length; i++) { offsets.Add(pdf.Length); pdf.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n"); }
        var xref = pdf.Length; pdf.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets.Skip(1)) pdf.Append($"{offset:0000000000} 00000 n \n");
        pdf.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        var path = Path.Combine(store.Root, "demo.pdf"); await File.WriteAllTextAsync(path, pdf.ToString(), Encoding.ASCII);
        var saved = await store.CommitFile(path, key, title.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? title : title + ".pdf", "application/pdf");
        File.Delete(path); await OpenSaved(saved);
    }
}
