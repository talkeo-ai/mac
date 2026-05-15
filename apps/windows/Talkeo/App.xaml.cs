using System;
using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Talkeo.Selection;
using Talkeo.Tray;
using Talkeo.UI;

namespace Talkeo;

public partial class App : Application
{
    private MouseHook? _mouseHook;
    private SelectionReader? _selectionReader;
    private TooltipWindow? _tooltip;
    private TrayIconService? _tray;
    private DispatcherQueue? _uiQueue;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _uiQueue = DispatcherQueue.GetForCurrentThread();
        _selectionReader = new SelectionReader();
        _tooltip = new TooltipWindow();
        _tray = new TrayIconService(OnTrayExitRequested);
        _tray.Install();

        _mouseHook = new MouseHook(OnGlobalMouseUp);
        _mouseHook.Start();

        Debug.WriteLine("[Talkeo] launched");
    }

    private void OnGlobalMouseUp(int screenX, int screenY)
    {
        _uiQueue?.TryEnqueue(() =>
        {
            try
            {
                var text = _selectionReader?.ReadSelectedText();
                if (string.IsNullOrWhiteSpace(text)) return;
                _tooltip?.Show(text!, screenX, screenY);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Talkeo] selection read failed: {ex.Message}");
            }
        });
    }

    private void OnTrayExitRequested()
    {
        _mouseHook?.Stop();
        _tray?.Dispose();
        _tooltip?.Close();
        Exit();
    }
}
