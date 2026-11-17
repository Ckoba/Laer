using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Laer.Windows.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Laer.Windows;

public partial class MainWindow
{
    private async Task OpenFileTab(SavedFile file)
    {
        if(store==null)return;
        var existing=viewerEntries.FirstOrDefault(x=>x.Key==file.Key);
        if(existing!=null){ShowViewer(existing);return;}
        var path=store.FilePath(file);var extension=Path.GetExtension(path).ToLowerInvariant();FrameworkElement content;
        if(extension==".pdf")
        {
            var browser=new WebView2();content=browser;
            var entry=new ViewerEntry(file.Key,file.Name,content,file);viewerEntries.Add(entry);ViewerContents.Children.Add(content);ShowViewer(entry);
            try
            {
                var environment=await CoreWebView2Environment.CreateAsync(null,Path.Combine(App.Root,"preview"));
                await browser.EnsureCoreWebView2Async(environment);var core=browser.CoreWebView2;
                core.Settings.AreDevToolsEnabled=false;core.Settings.AreHostObjectsAllowed=false;core.Settings.IsWebMessageEnabled=false;
                core.PermissionRequested+=(_,e)=>e.State=CoreWebView2PermissionState.Deny;
                core.NewWindowRequested+=(_,e)=>e.Handled=true;
                core.NavigationStarting+=(_,e)=>
                {
                    if(!Uri.TryCreate(e.Uri,UriKind.Absolute,out var url) || !(url.Scheme=="about" || url.Scheme=="file" && string.Equals(url.LocalPath,path,StringComparison.OrdinalIgnoreCase)))e.Cancel=true;
                };
                browser.DefaultBackgroundColor=((SolidColorBrush)FindResource("ViewerPanel")).Color is var color ? System.Drawing.Color.FromArgb(color.A,color.R,color.G,color.B) : System.Drawing.Color.White;
                core.Navigate(new Uri(path).AbsoluteUri);
            }
            catch { CloseViewerTab(entry); throw; }
            return;
        }
        if(new[]{".png",".jpg",".jpeg",".gif",".webp"}.Contains(extension))
        {
            var bitmap=new BitmapImage();bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;bitmap.UriSource=new Uri(path);bitmap.EndInit();bitmap.Freeze();
            content=new ScrollViewer{Content=new Image{Source=bitmap,Stretch=Stretch.Uniform,Margin=new Thickness(16)},VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        }
        else content=new TextBox{Text=await File.ReadAllTextAsync(path),IsReadOnly=true,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,BorderThickness=new Thickness(0),Padding=new Thickness(24),FontFamily=new FontFamily("Consolas"),FontSize=12,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        var tab=new ViewerEntry(file.Key,file.Name,content,file);viewerEntries.Add(tab);ViewerContents.Children.Add(content);ShowViewer(tab);
    }
}
