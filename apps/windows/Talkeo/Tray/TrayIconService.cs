using System;
using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;

namespace Talkeo.Tray;

/// <summary>
/// Installs a system-tray icon with a single "Exit" command. Lives for the
/// lifetime of the app; calling <see cref="Dispose"/> removes the icon.
/// </summary>
internal sealed class TrayIconService : IDisposable
{
    private readonly Action _onExit;
    private TaskbarIcon? _icon;

    public TrayIconService(Action onExit)
    {
        _onExit = onExit;
    }

    public void Install()
    {
        if (_icon != null) return;

        var exit = new MenuFlyoutItem { Text = "Exit Talkeo" };
        exit.Click += (_, _) => _onExit();

        var menu = new MenuFlyout();
        menu.Items.Add(exit);

        _icon = new TaskbarIcon
        {
            ToolTipText = "Talkeo",
            ContextFlyout = menu,
        };
        _icon.ForceCreate();
    }

    public void Dispose()
    {
        _icon?.Dispose();
        _icon = null;
    }
}
