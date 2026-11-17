using System.Globalization;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Laer.Windows.Core;

namespace Laer.Windows;

public partial class MainWindow
{
    private DateTime calendarWeek = StartOfWeek(DateTime.Today);
    private static DateTime StartOfWeek(DateTime value)
    { var first = CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek; return value.Date.AddDays(-((7 + (int)value.DayOfWeek - (int)first) % 7)); }
    private static string DayTitle(DateTime date) => date.ToString("dddd", CultureInfo.CurrentCulture) + ", " + date.ToString("m", CultureInfo.CurrentCulture);
    private static string ShortDate(DateTimeOffset? date) => date is { Year: < 9000 } value ? value.LocalDateTime.Date == DateTime.Today ? value.ToLocalTime().ToString("t") : value.ToLocalTime().ToString("ddd", CultureInfo.CurrentCulture) + " " + value.ToLocalTime().ToString("m", CultureInfo.CurrentCulture) : "No deadline";
    private static string StatusText(string status) => status.ToLowerInvariant() switch { "completed" or "done" => "Done", "inprogress" or "started" => "In progress", "submitted" or "handedin" => "Submitted", _=>"" };
    private string CourseName(JsonElement item) => courses.FirstOrDefault(x => x.Id("CourseId") == item.Id("LocationId")).Text("FriendlyName", item.Text("LocationTitle"));
    private static TextBlock Label(string text, double size = 13, bool muted = false)
    {
        var label = new TextBlock { Text = text, FontSize = size, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        if (muted) label.SetResourceReference(TextBlock.ForegroundProperty,"Muted"); return label;
    }
    private StackPanel HomeSection(string title, string? target = null)
    {
        var sectionPanel = new StackPanel { Margin = new Thickness(0,0,0,32) };
        var header = new DockPanel { Margin = new Thickness(8,0,8,4) };
        if (target != null)
        {
            var all = new Button { Content = "Show all", FontSize = 12, Padding = new Thickness(0), MinHeight = 24 };
            all.SetResourceReference(ForegroundProperty,"Muted"); System.Windows.Automation.AutomationProperties.SetName(all,"Show all in " + target);
            all.Click += async (_, _) => await Run(() => Navigate(target)); DockPanel.SetDock(all,Dock.Right); header.Children.Add(all);
        }
        var heading = Label(title,15); heading.FontWeight = FontWeights.SemiBold; header.Children.Add(heading); sectionPanel.Children.Add(header); Body.Children.Add(sectionPanel); return sectionPanel;
    }
    private async Task Home(int version)
    {
        PageTitle.Text = DayTitle(DateTime.Today);
        var plans = new Dictionary<long, IReadOnlyList<JsonElement>>();
        async Task LoadPlans(JsonElement item)
        {
            var id = item.Id("CourseId");
            try { plans[id] = await Collection($"plans-{id}", $"/restapi/personal/course/{id}/plans/all/v1"); }
            catch (ApiException) { }
        }
        await Task.WhenAll(courses.Take(16).Select(LoadPlans));
        IReadOnlyList<JsonElement>? events = null; JsonElement threads = default;
        try { events = await Collection("calendar", "/restapi/personal/calendar/events/v1?fromDate=" + Uri.EscapeDataString(DateTime.Today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ",CultureInfo.InvariantCulture))); } catch (ApiException) { }
        try { threads = await Document("threads-0", "/restapi/personal/instantmessages/messagethreads/v4?pageSize=10"); } catch (ApiException) { }
        if (generation != version) return;
        var lectures = HomeSection("Next lectures");
        var cards = new WrapPanel { Margin = new Thickness(0,4,0,0) }; lectures.Children.Add(cards);
        foreach (var item in courses)
        {
            if (!plans.TryGetValue(item.Id("CourseId"), out var list)) continue;
            var next = NextPlan(list); if (next.ValueKind == JsonValueKind.Undefined) continue;
            var content = new StackPanel(); content.Children.Add(Icons.Label("course",item.Text("FriendlyName",item.Text("Title")),12));
            var title = Label(next.Text("title", "Untitled plan"),15); title.FontWeight = FontWeights.SemiBold; title.Margin = new Thickness(0,6,0,16); content.Children.Add(title);
            var meta = new StackPanel { Orientation = Orientation.Horizontal };
            if (next.Date("start") != null) meta.Children.Add(Icons.Label("clock",ShortDate(next.Date("start")),11));
            if (next.Field("elements").ValueKind == JsonValueKind.Array)
            { var count = Icons.Label("file",next.Field("elements").GetArrayLength().ToString(CultureInfo.CurrentCulture),11); count.Margin = new Thickness(12,0,0,0); meta.Children.Add(count); }
            content.Children.Add(meta);
            var card = new Button { Content = content, Style = (Style)FindResource("LectureCard"), Width = 220, MinHeight = 120, Padding = new Thickness(16), Margin = new Thickness(0,0,12,12), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            System.Windows.Automation.AutomationProperties.SetName(card,item.Text("FriendlyName",item.Text("Title"))+": "+next.Text("title","Untitled plan"));
            card.SetResourceReference(BackgroundProperty,"Raised");
            card.Click += async (_, _) => await Run(async () => { selectedCourseTabs[item.Id("CourseId")] = "Plans"; await OpenCourse(item); }); cards.Children.Add(card);
        }
        if (cards.Children.Count == 0) Text(lectures, plans.Count < courses.Count ? "Lectures unavailable" : courses.Count == 0 ? "No active courses" : "No upcoming lectures", muted:true);
        var today = HomeSection("Today", "calendar");
        var todays = events?.Where(x => x.Date("FromDate")?.LocalDateTime.Date == DateTime.Today).OrderBy(x => x.Date("FromDate")).ToList();
        if (todays == null) Text(today,"Calendar unavailable",muted:true);
        else if (todays.Count == 0) Text(today,"Nothing on the calendar today",muted:true);
        else foreach (var item in todays) HomeLine(today, item.Date("FromDate")?.ToLocalTime().ToString("t") ?? "",item.Text("EventTitle","Untitled event"),item.Text("LocationTitle"),() => Navigate("calendar"));
        var due = HomeSection("Next 7 days", "upcoming");
        var upcoming = tasks.Where(x => x.Text("Status") is not ("Completed" or "Done") && x.Date("Deadline") is { } deadline && deadline.LocalDateTime < DateTime.Today.AddDays(8)).OrderBy(x=>x.Date("Deadline")).Take(8).ToList();
        if (upcoming.Count == 0) Text(due,"Nothing due in the next 7 days",muted:true);
        foreach (var task in upcoming) HomeLine(due,ShortDate(task.Date("Deadline")),task.Text("Title"),CourseName(task),() => OpenTask(task),task.Date("Deadline") < DateTimeOffset.Now);
        var unread = HomeSection("Unread messages", "messages");
        var threadItems = threads.Field("Threads").Field("EntityArray");
        if (threadItems.ValueKind != JsonValueKind.Array) Text(unread,"Messages unavailable",muted:true);
        else
        {
            var items = threadItems.Array().Where(x => x.Field("LastMessage").Id("MessageId") > x.Id("LastReadInstantMessageId")).Take(5).ToList();
            if (items.Count == 0) Text(unread,"No unread messages",muted:true);
            foreach (var item in items) HomeLine(unread,item.Field("LastMessage").Date("Created") is {} created ? ShortDate(created) : "",item.Text("Name","Conversation"),Json.Plain(item.Field("LastMessage").Text("Text")),()=>Navigate("messages"));
        }
    }
    private void HomeLine(Panel panel,string leading,string title,string detail,Func<Task> action,bool danger=false)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(148) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        var left = Label(leading,12,true); if(danger) left.SetResourceReference(TextBlock.ForegroundProperty,"Danger"); left.VerticalAlignment=VerticalAlignment.Top; grid.Children.Add(left);
        var content = new StackPanel { Margin = new Thickness(12,0,0,0) }; content.Children.Add(Label(title)); if(detail.Length>0) { var sub=Label(detail,11,true);sub.Margin=new Thickness(0,2,0,0);content.Children.Add(sub); }
        Grid.SetColumn(content,1);grid.Children.Add(content); DividedRow(panel,grid,action,title);
    }
    private void Upcoming()
    {
        var active = tasks.Where(x=>x.Text("Status") is not ("Completed" or "Done")).OrderBy(x=>x.Date("Deadline") ?? DateTimeOffset.MaxValue).ToList();
        var groups = new (string Name, Func<JsonElement,bool> Match)[]
        {
            ("Overdue",x=>x.Date("Deadline") is {} d && d < DateTimeOffset.Now),
            ("Today",x=>x.Date("Deadline") is {} d && d >= DateTimeOffset.Now && d.LocalDateTime.Date == DateTime.Today),
            ("Next 7 days",x=>x.Date("Deadline") is {} d && d.LocalDateTime.Date > DateTime.Today && d.LocalDateTime.Date <= DateTime.Today.AddDays(7)),
            ("Later",x=>x.Date("Deadline") is {} d && d.LocalDateTime.Date > DateTime.Today.AddDays(7) && d.Year<9000)
        };
        foreach(var group in groups)
        {
            var items=active.Where(group.Match).ToList(); if(items.Count==0)continue;
            SectionLabel(Body,group.Name); foreach(var task in items)TaskLine(Body,task);
        }
        var undated=active.Where(x=>x.Date("Deadline")==null || x.Date("Deadline")?.Year>=9000).ToList();
        if(undated.Count>0)Disclosure(Body,"No deadline",undated.Count.ToString(CultureInfo.CurrentCulture),children=>{foreach(var task in undated)TaskLine(children,task);});
        if(active.Count==0)Text(Body,"No upcoming tasks",muted:true);
    }
    private void TaskLine(Panel panel,JsonElement task)
    {
        var grid=new DockPanel();var right=new StackPanel { HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(12,0,0,0) };
        var deadline=task.Date("Deadline"); if(deadline is { Year:<9000 }) {var date=Label(ShortDate(deadline),12);if(deadline<DateTimeOffset.Now)date.SetResourceReference(TextBlock.ForegroundProperty,"Danger");right.Children.Add(date);}
        var status=StatusText(task.Text("Status"));if(status.Length>0)right.Children.Add(Label(status,11,true));DockPanel.SetDock(right,Dock.Right);grid.Children.Add(right);
        var text=new StackPanel();text.Children.Add(Label(task.Text("Title","Task")));var sub=Label(CourseName(task),11,true);sub.Margin=new Thickness(0,2,0,0);text.Children.Add(sub);grid.Children.Add(text);
        DividedRow(panel,grid,()=>OpenTask(task),task.Text("Title","Task"));
    }
    private static JsonElement NextPlan(IReadOnlyList<JsonElement> list) => list.Where(x=>x.Date("start") is {} start && (x.Date("stop") ?? start.AddHours(2)) >= DateTimeOffset.Now).OrderBy(x=>x.Date("start")).FirstOrDefault();
    private void Plans(IReadOnlyList<JsonElement> list)
    {
        var next=NextPlan(list);
        if(next.ValueKind!=JsonValueKind.Undefined)
        {
            var content=new StackPanel(); var meta=Icons.Label("clock","Next lecture    "+ShortDate(next.Date("start")),12);content.Children.Add(meta);
            var title=Label(next.Text("title","Untitled plan"),18);title.FontWeight=FontWeights.SemiBold;title.Margin=new Thickness(0,4,0,12);content.Children.Add(title);PlanContent(content,next);
            var card=new Border{CornerRadius=new CornerRadius(14),Padding=new Thickness(16),Margin=new Thickness(0,0,0,16),Child=content};card.SetResourceReference(Border.BackgroundProperty,"Raised");Body.Children.Add(card);
        }
        var later=list.Where(x=>x.Date("start")>next.Date("start") && x.Id("id")!=next.Id("id")).OrderBy(x=>x.Date("start")).ToList();
        if(later.Count>0){SectionLabel(Body,"Later");foreach(var plan in later)PlanDisclosure(Body,plan);}
        var undated=list.Where(x=>x.Date("start")==null).ToList();
        if(undated.Count>0){SectionLabel(Body,"Without dates");foreach(var plan in undated)PlanDisclosure(Body,plan);}
        var previous=list.Where(x=>x.Date("start")!=null && x.Id("id")!=next.Id("id") && !later.Any(y=>y.Id("id")==x.Id("id"))).OrderByDescending(x=>x.Date("start")).ToList();
        if(previous.Count>0)Disclosure(Body,"Previous lectures",previous.Count.ToString(CultureInfo.CurrentCulture),children=>{foreach(var plan in previous)PlanDisclosure(children,plan);});
        if(list.Count==0)Text(Body,"No plans",muted:true);
    }
    private void PlanDisclosure(Panel panel,JsonElement plan)=>Disclosure(panel,plan.Text("title","Untitled plan"),ShortDate(plan.Date("start")),children=>PlanContent(children,plan));
    private void PlanContent(Panel panel,JsonElement plan)
    {
        if(plan.Text("displayDescription").Length>0)Text(panel,Json.Plain(plan.Text("displayDescription")));
        if(plan.Field("elements").ValueKind!=JsonValueKind.Array)return;
        foreach(var item in plan.Field("elements").Array())MaterialLine(panel,JsonSerializer.SerializeToElement(new{ElementId=item.Id("id"),ElementType=item.Flag("isFolder")==true?"Folder":"LearningToolElement",Title=item.Text("title"),CourseId=plan.Id("courseId")>0?plan.Id("courseId"):course.Id("CourseId"),Url=item.Text("url")}),false);
    }
    private void MaterialLine(Panel panel,JsonElement material,bool divide=true)
    {
        var type=material.Text("ElementType");var grid=new DockPanel();var title=material.Text("Title","Material");
        var trailing=Icons.Make(type.Equals("Folder",StringComparison.OrdinalIgnoreCase)||type=="Page"?"chevron":"save",14);DockPanel.SetDock(trailing,Dock.Right);grid.Children.Add(trailing);
        grid.Children.Add(Icons.Label(type=="Folder"?"folder":"file",title));
        async Task Open()
        {
            if(type.Equals("Folder",StringComparison.OrdinalIgnoreCase)){folders.Push(folder);folder=material.Id("ElementId");await Navigate("course");}
            else if(type=="Page")await Page(material);
            else if(type=="Assignment")await OpenTask(material);
            else await SaveMaterial(material);
        }
        if(divide)DividedRow(panel,grid,Open,title);else{var row=new Button{Content=grid,Style=(Style)FindResource("ContentRow"),Padding=new Thickness(8,6,8,6)};row.Click+=async(_,_)=>await Run(Open);System.Windows.Automation.AutomationProperties.SetName(row,title);panel.Children.Add(row);}
    }
    private static void SectionLabel(Panel panel,string title)
    {var label=Label(title,12,true);label.Margin=new Thickness(8,panel.Children.Count==0?0:24,8,4);panel.Children.Add(label);}
    private void Disclosure(Panel panel,string title,string trailing,Action<StackPanel> populate)
    {
        var container=new StackPanel();var grid=new DockPanel();
        var meta=Label(trailing,11,true);meta.Margin=new Thickness(12,0,0,0);DockPanel.SetDock(meta,Dock.Right);grid.Children.Add(meta);
        var label=new StackPanel{Orientation=Orientation.Horizontal};label.Children.Add(Label(title));var chevron=Icons.Make("chevron",10);chevron.Margin=new Thickness(6,0,0,0);label.Children.Add(chevron);grid.Children.Add(label);
        var children=new StackPanel{Margin=new Thickness(16,0,0,8),Visibility=Visibility.Collapsed};
        var button=new Button{Content=grid,Style=(Style)FindResource("ContentRow")};System.Windows.Automation.AutomationProperties.SetName(button,title);
        button.Click+=(_,_)=>{var open=children.Visibility!=Visibility.Visible;if(open && children.Children.Count==0)populate(children);children.Visibility=open?Visibility.Visible:Visibility.Collapsed;chevron.RenderTransformOrigin=new Point(.5,.5);chevron.RenderTransform=new RotateTransform(open?90:0);};
        container.Children.Add(button);container.Children.Add(children);var border=new Border{Child=container,BorderThickness=new Thickness(0,0,0,1)};border.SetResourceReference(Border.BorderBrushProperty,"Line");panel.Children.Add(border);
    }
    private void DividedRow(Panel panel,FrameworkElement content,Func<Task>? action,string title)
    {
        var grid=new Grid();var line=new Border{Height=1,VerticalAlignment=VerticalAlignment.Bottom,Margin=new Thickness(8,0,8,0)};line.SetResourceReference(Border.BackgroundProperty,"Line");grid.Children.Add(line);
        if(action==null){content.Margin=new Thickness(8,12,8,12);grid.Children.Add(content);}
        else{var button=new Button{Content=content,Style=(Style)FindResource("ContentRow")};System.Windows.Automation.AutomationProperties.SetName(button,title);button.MouseEnter+=(_,_)=>line.Visibility=Visibility.Hidden;button.MouseLeave+=(_,_)=>line.Visibility=Visibility.Visible;button.Click+=async(_,_)=>await Run(action);grid.Children.Add(button);}
        panel.Children.Add(grid);
    }
    private async Task CourseCalendar(long id)
    {
        var from=DateTime.Today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ",CultureInfo.InvariantCulture);var to=DateTime.Today.AddDays(90).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ",CultureInfo.InvariantCulture);
        var items=await Collection($"course-calendar-{id}",$"/restapi/personal/courses/{id}/calendarevents/v1?fromDate={Uri.EscapeDataString(from)}&toDate={Uri.EscapeDataString(to)}");
        foreach(var group in items.Where(x=>x.Date("FromDate")!=null).GroupBy(x=>x.Date("FromDate")!.Value.LocalDateTime.Date).OrderBy(x=>x.Key))
        {SectionLabel(Body,DayTitle(group.Key));foreach(var item in group.OrderBy(x=>x.Date("FromDate")))HomeLine(Body,item.Date("FromDate")?.ToLocalTime().ToString("t")??"",item.Text("EventTitle"),Json.Plain(item.Text("Description")),()=>{OpenDetail(item.Text("EventTitle"));Text(Detail,Json.Plain(item.Text("Description")));return Task.CompletedTask;});}
        if(items.Count==0)Text(Body,"No events in this period",muted:true);
    }
    private async Task Calendar(int version)
    {
        PageTitle.Text=calendarWeek.ToString("m",CultureInfo.CurrentCulture)+" – "+calendarWeek.AddDays(6).ToString("m",CultureInfo.CurrentCulture);
        HeaderActions.Children.Add(IconButton("back","Previous week",async()=>{calendarWeek=calendarWeek.AddDays(-7);await Navigate("calendar");}));
        AddButton(HeaderActions,"This week",async()=>{calendarWeek=StartOfWeek(DateTime.Today);await Navigate("calendar");});
        HeaderActions.Children.Add(IconButton("chevron","Next week",async()=>{calendarWeek=calendarWeek.AddDays(7);await Navigate("calendar");}));
        var from=calendarWeek.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ",CultureInfo.InvariantCulture);
        var items=await Collection("calendar","/restapi/personal/calendar/events/v1?fromDate="+Uri.EscapeDataString(from));if(generation!=version)return;
        DrawWeek(items);
    }
    private void DrawWeek(IReadOnlyList<JsonElement> events)
    {
        PageScroll.Visibility=Visibility.Collapsed;CalendarHost.Visibility=Visibility.Visible;CalendarHost.Children.Clear();
        var scroll=new ScrollViewer{VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto};CalendarHost.Children.Add(scroll);
        var grid=new Grid{MinWidth=700};grid.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(48)});for(var i=0;i<7;i++)grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.RowDefinitions.Add(new RowDefinition{Height=new GridLength(56)});for(var hour=7;hour<=20;hour++)grid.RowDefinitions.Add(new RowDefinition{Height=new GridLength(56)});
        for(var day=0;day<7;day++)
        {
            var date=calendarWeek.AddDays(day);var header=new StackPanel{Margin=new Thickness(8,0,0,0)};header.Children.Add(Label(date.ToString("ddd",CultureInfo.CurrentCulture),11,true));var number=Label(date.Day.ToString(CultureInfo.CurrentCulture),18);number.FontWeight=FontWeights.SemiBold;header.Children.Add(number);
            if(date==DateTime.Today){var today=new Border{CornerRadius=new CornerRadius(8),Padding=new Thickness(6,4,6,4),Child=header,HorizontalAlignment=HorizontalAlignment.Left};today.SetResourceReference(Border.BackgroundProperty,"Selection");Grid.SetColumn(today,day+1);grid.Children.Add(today);}else{Grid.SetColumn(header,day+1);grid.Children.Add(header);}
            for(var row=1;row<=14;row++){var cell=new Border{BorderThickness=new Thickness(1,1,0,0)};cell.SetResourceReference(Border.BorderBrushProperty,"Line");Grid.SetColumn(cell,day+1);Grid.SetRow(cell,row);grid.Children.Add(cell);}
            var canvas=new Canvas{ClipToBounds=true};Grid.SetColumn(canvas,day+1);Grid.SetRow(canvas,1);Grid.SetRowSpan(canvas,14);grid.Children.Add(canvas);
            var dayEvents=events.Where(x=>x.Date("FromDate")?.LocalDateTime.Date==date).OrderBy(x=>x.Date("FromDate")).ToList();
            foreach(var item in dayEvents)
            {
                var start=item.Date("FromDate")!.Value.LocalDateTime;var end=item.Date("ToDate")?.LocalDateTime??start.AddHours(1);var top=Math.Max(0,(start.TimeOfDay.TotalHours-7)*56);var height=Math.Max(36,Math.Min((end-start).TotalHours*56,14*56-top));if(top>=14*56)continue;
                var content=new StackPanel();content.Children.Add(Label(start.ToString("t"),11,true));content.Children.Add(Label(item.Text("EventTitle","Event"),12));if(height>64)content.Children.Add(Label(item.Text("LocationTitle"),11,true));
                var button=new Button{Content=content,Padding=new Thickness(8),Height=height,HorizontalContentAlignment=HorizontalAlignment.Stretch,VerticalContentAlignment=VerticalAlignment.Top,ToolTip=item.Text("EventTitle")};button.SetResourceReference(BackgroundProperty,"Raised");Canvas.SetTop(button,top);Canvas.SetLeft(button,4);canvas.SizeChanged+=(_,_)=>button.Width=Math.Max(0,canvas.ActualWidth-8);button.Click+=(_,_)=>{OpenDetail(item.Text("EventTitle"));Text(Detail,Json.Plain(item.Text("Description")));};canvas.Children.Add(button);
            }
        }
        for(var row=1;row<=14;row++){var time=Label(DateTime.Today.AddHours(row+6).ToString("t"),11,true);time.Margin=new Thickness(4,0,4,0);time.VerticalAlignment=VerticalAlignment.Top;Grid.SetRow(time,row);grid.Children.Add(time);}scroll.Content=grid;
    }
}
