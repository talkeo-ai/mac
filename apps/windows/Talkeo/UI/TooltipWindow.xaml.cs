using System;
using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Talkeo.Interop;
using WinRT.Interop;

namespace Talkeo.UI;

public sealed partial class TooltipWindow : Window
{
    private const int DefaultWidth = 280;
    private const int DefaultHeight = 96;

    private readonly AppWindow _appWindow;
    private string _selectedText = string.Empty;

    public TooltipWindow()
    {
        InitializeComponent();

        var hWnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hWnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);

        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.SetBorderAndTitleBar(false, false);
        }
        Title = "Talkeo";
        _appWindow.Hide();
    }

    public void Show(string text, int screenX, int screenY)
    {
        _selectedText = text;
        SelectedTextBlock.Text = text.Length > 200 ? text[..200] + "…" : text;

        var (x, y, w, h) = ComputePlacement(screenX, screenY);
        _appWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, w, h));
        _appWindow.Show();
        Activate();
    }

    private static (int x, int y, int w, int h) ComputePlacement(int cursorX, int cursorY)
    {
        var point = new NativeMethods.POINT { X = cursorX, Y = cursorY };
        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        uint dpiX = 96, dpiY = 96;
        if (monitor != IntPtr.Zero)
        {
            try { NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out dpiX, out dpiY); }
            catch { /* fall back to 96 DPI */ }
        }
        double scaleX = dpiX / 96.0;
        double scaleY = dpiY / 96.0;
        int w = (int)(DefaultWidth * scaleX);
        int h = (int)(DefaultHeight * scaleY);
        // Slight offset so the tooltip doesn't cover the cursor.
        int x = cursorX + 12;
        int y = cursorY + 12;
        return (x, y, w, h);
    }

    private void OnTranslateClick(object sender, RoutedEventArgs e)
    {
        Debug.WriteLine($"[Talkeo] Translate clicked: {_selectedText}");
    }

    private void OnImproveClick(object sender, RoutedEventArgs e)
    {
        Debug.WriteLine($"[Talkeo] Improve clicked: {_selectedText}");
    }

    private void OnDefineClick(object sender, RoutedEventArgs e)
    {
        Debug.WriteLine($"[Talkeo] Define clicked: {_selectedText}");
    }

    private void OnPronounceClick(object sender, RoutedEventArgs e)
    {
        Debug.WriteLine($"[Talkeo] Pronounce clicked: {_selectedText}");
    }
}
